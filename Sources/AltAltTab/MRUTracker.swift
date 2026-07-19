import AppKit
import Foundation

/// Tracks most-recently-used *windows* across switching sessions, independent
/// of the current session's snapshot (`SwitcherController.model.windows`).
///
/// The module is `MainActor`-isolated by default, so this class is on the
/// main actor without annotation.
final class MRUTracker {
    /// Most-recently-used window ids, front = most recent.
    private var mru: [CGWindowID] = []

    private let ownPid: pid_t = ProcessInfo.processInfo.processIdentifier

    /// Per-window focus observer. Catches focus changes *within* an app (clicking
    /// between two windows of the same app), which the app-activation notification
    /// below never fires for. Retained here for its lifetime.
    private var focusObserver: FocusObserver?

    init() {
        // Per-window focus tracking (AX). Kept alongside the app-activation
        // observer below — that one still covers app-level switches that don't
        // emit a per-app focused-window-changed event.
        let observer = FocusObserver { [weak self] wid in
            self?.noteFocused(wid)
        }
        observer.start()
        self.focusObserver = observer

        // Observe app activations to keep the MRU list fresh even outside of
        // switcher sessions (e.g. Dock clicks, Spotlight). `.main` queue means
        // the block runs on the main thread, making `assumeIsolated` sound.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Extract the Sendable pid_t here, in the nonisolated closure
            // where the (non-Sendable) Notification is delivered, so only the
            // pid crosses into the isolated closure below.
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            // `.main` queue means this runs on the main thread → assumeIsolated is sound.
            MainActor.assumeIsolated {
                guard let self, let pid, pid != self.ownPid else { return }
                if let windowID = WindowEnumerator.focusedWindowID(pid: pid) {
                    self.noteFocused(windowID)
                }
            }
        }
    }

    /// Orders `windows` MRU-first: windows found in `mru` come first (in mru
    /// order), then the rest in their given (z-order) order. Prunes ids from
    /// `mru` that no longer exist among the passed windows. Seeds `mru` from
    /// the given z-order on the very first call (empty mru), since front-to-back
    /// order is a valid recency approximation.
    func order(_ windows: [WindowInfo]) -> [WindowInfo] {
        if mru.isEmpty {
            mru = windows.map(\.windowID)
            return windows
        }

        var byID: [CGWindowID: WindowInfo] = [:]
        for window in windows {
            byID[window.windowID] = window
        }

        var ordered: [WindowInfo] = []
        var seen: Set<CGWindowID> = []

        // MRU-known windows first, in mru order; drop dead ids while we're at it.
        var prunedMRU: [CGWindowID] = []
        for id in mru {
            guard let window = byID[id] else { continue }
            prunedMRU.append(id)
            ordered.append(window)
            seen.insert(id)
        }
        mru = prunedMRU

        // Then the rest, in their given z-order.
        for window in windows where !seen.contains(window.windowID) {
            ordered.append(window)
        }

        return ordered
    }

    /// Moves (or inserts) `windowID` to the front of the MRU list.
    func noteFocused(_ windowID: CGWindowID) {
        mru.removeAll { $0 == windowID }
        mru.insert(windowID, at: 0)
    }
}
