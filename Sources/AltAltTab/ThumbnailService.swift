import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Fills `WindowInfo.thumbnail` with live window captures via ScreenCaptureKit.
///
/// The module is `MainActor`-isolated by default (Package.swift
/// `.defaultIsolation(MainActor.self)`), so this class and all its methods live
/// on the main actor without annotation. That is deliberate and load-bearing:
/// the SCK screenshot calls are `async` and *suspend* (the actual capture work
/// happens off-main inside SCK), so we get real ≤4-in-flight concurrency while
/// the non-`Sendable` `SCWindow`/`SCContentFilter`/`SCStreamConfiguration`
/// values never leave the main actor. No custom executor is needed.
///
/// **Hard no-op when Screen Recording is not granted**: no SCK calls, no
/// prompting, at most one quiet log line per session. The switcher stays fully
/// usable in icon+title mode.
final class ThumbnailService {

    /// Fresh-enough window images survive this long before being recaptured.
    private let ttl: TimeInterval = 2.0
    /// Max SCK screenshot captures in flight at once.
    private let maxConcurrent = 4
    /// Thumbnails are scaled DOWN (never up) to fit within this pixel box.
    private let maxPixelWidth: CGFloat = 600
    private let maxPixelHeight: CGFloat = 400

    /// Index built from the last `SCShareableContent` fetch. `SCWindow.windowID`
    /// is a `CGWindowID`, so this maps our window ids to their SCK handles.
    private var scWindowIndex: [CGWindowID: SCWindow] = [:]
    /// Image cache across sessions, with capture timestamps for TTL checks.
    private var imageCache: [CGWindowID: (image: CGImage, capturedAt: Date)] = [:]

    /// Bumped once per `populateThumbnails` call. A capture that lands only
    /// writes into the model if its generation is still current — belt-and-braces
    /// against a slow capture from a previous session touching a new list.
    private var generation = 0
    /// Guards the fire-and-forget shareable-content refresh against overlap.
    private var refreshInFlight = false
    /// Ensures the "permission denied" note is logged at most once per session.
    private var deniedLogged = false

    init() {
        // Warm the shareable-content cache off the critical path.
        refreshShareableContent()
    }

    // MARK: Public API

    /// Refresh the `SCShareableContent` cache in the background (fire-and-forget).
    /// Hard no-op when Screen Recording is denied.
    func refreshShareableContent() {
        guard Permissions.screenRecordingGranted else { return }
        guard !refreshInFlight else { return }
        refreshInFlight = true
        Task {
            defer { self.refreshInFlight = false }
            await self.fetchShareableContent()
        }
    }

    /// Stream thumbnails into the model's windows (fire-and-forget; returns
    /// immediately). Cached images are applied synchronously before returning so
    /// the panel shows something instantly; live captures follow.
    func populateThumbnails(model: SwitcherModel) {
        guard Permissions.screenRecordingGranted else {
            if !deniedLogged {
                deniedLogged = true
                logToStderr("ThumbnailService: screen recording not granted; thumbnails disabled (icon+title mode)")
            }
            return
        }

        generation += 1
        let gen = generation

        // 1. Apply any cached images immediately (even stale ones) — instant
        //    visual, a refresh capture follows below.
        for i in model.windows.indices {
            if let cached = imageCache[model.windows[i].windowID] {
                model.windows[i].thumbnail = cached.image
            }
        }

        // 2/3/4/5. The rest is async; return immediately.
        let order = captureOrder(count: model.windows.count, selected: model.selectionIndex)
        Task {
            await self.runCapturePass(model: model, order: order, generation: gen)
        }
    }

    // MARK: Capture pass

    private struct Candidate {
        let windowID: CGWindowID
        let size: CGSize
    }

    private func runCapturePass(model: SwitcherModel, order: [Int], generation gen: Int) async {
        let now = Date()

        // Build the capture list, in selection-outward order. Skip minimized
        // windows (SCK can't capture off-screen content) and windows already
        // fresh in the cache.
        var candidates: [Candidate] = []
        for idx in order {
            guard idx >= 0, idx < model.windows.count else { continue }
            let window = model.windows[idx]
            if window.isMinimized { continue }
            if let cached = imageCache[window.windowID], now.timeIntervalSince(cached.capturedAt) < ttl {
                continue
            }
            candidates.append(Candidate(windowID: window.windowID, size: window.frame.size))
        }

        guard !candidates.isEmpty else { return }

        // If any candidate has no SCWindow match (empty or stale shareable cache),
        // kick one refresh inline and match against the fresh result.
        if candidates.contains(where: { scWindowIndex[$0.windowID] == nil }) {
            await fetchShareableContent()
        }

        // Capture with bounded concurrency (≤ maxConcurrent in flight). Each
        // child task awaits a MainActor method, so the non-Sendable SCK values
        // stay on the main actor and only `Void` flows back through the group.
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            let initial = min(maxConcurrent, candidates.count)
            while next < initial {
                let candidate = candidates[next]
                group.addTask {
                    await self.captureAndStore(candidate: candidate, model: model, generation: gen)
                }
                next += 1
            }
            while await group.next() != nil {
                if next < candidates.count {
                    let candidate = candidates[next]
                    group.addTask {
                        await self.captureAndStore(candidate: candidate, model: model, generation: gen)
                    }
                    next += 1
                }
            }
        }
    }

    /// Capture one window and store the result. MainActor-isolated: the filter,
    /// config and `SCWindow` never cross isolation, and the returned `CGImage`
    /// is created and consumed entirely here.
    private func captureAndStore(candidate: Candidate, model: SwitcherModel, generation gen: Int) async {
        guard let scWindow = scWindowIndex[candidate.windowID] else { return }

        // Create the filter/config immediately before the call and never touch
        // them after the `await` — this keeps them in a disconnected region so
        // region isolation allows the transfer into the nonisolated SCK call.
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .nominal
        let (pixelWidth, pixelHeight) = fittedPixelSize(for: candidate.size)
        config.width = pixelWidth
        config.height = pixelHeight

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            // Always update the cache — useful even if this session ended.
            imageCache[candidate.windowID] = (image, Date())
            // Only write into the model if this is still the current session.
            guard gen == generation else { return }
            if let idx = model.windows.firstIndex(where: { $0.windowID == candidate.windowID }) {
                model.windows[idx].thumbnail = image
            }
        } catch {
            // Log once per window per pass at most; leave cached/nil in place.
            logToStderr("ThumbnailService: capture failed for windowID=\(candidate.windowID): \(error)")
        }
    }

    // MARK: Shareable content

    /// Fetch shareable content and rebuild the `[CGWindowID: SCWindow]` index.
    /// The 50–150 ms cost is only ever paid off the critical path (init, a
    /// background refresh, or inside an already-async capture pass).
    private func fetchShareableContent() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var index: [CGWindowID: SCWindow] = [:]
            for window in content.windows {
                index[window.windowID] = window
            }
            scWindowIndex = index
        } catch {
            logToStderr("ThumbnailService: shareable content fetch failed: \(error)")
        }
    }

    // MARK: Helpers

    /// Capture order fanning out from the selected index: selected, +1, -1,
    /// +2, -2, … so the visible/likely windows are captured first.
    private func captureOrder(count: Int, selected: Int) -> [Int] {
        guard count > 0 else { return [] }
        let start = min(max(selected, 0), count - 1)
        var order = [start]
        var offset = 1
        while order.count < count {
            let right = start + offset
            let left = start - offset
            if right < count { order.append(right) }
            if left >= 0 { order.append(left) }
            offset += 1
        }
        return order
    }

    /// Pixel dimensions for the capture: the window's point size scaled DOWN
    /// (never up) to fit within the max pixel box, preserving aspect ratio.
    private func fittedPixelSize(for size: CGSize) -> (Int, Int) {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let scale = min(maxPixelWidth / width, maxPixelHeight / height, 1.0)
        let pixelWidth = max(Int((width * scale).rounded()), 1)
        let pixelHeight = max(Int((height * scale).rounded()), 1)
        return (pixelWidth, pixelHeight)
    }
}
