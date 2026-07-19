import AppKit
import ApplicationServices
import CoreGraphics

/// Watches every regular app for AX "focused window changed" events and reports
/// the newly focused window's `CGWindowID`. This is what lets the MRU list learn
/// about focus changes *within* a single app (clicking between two windows of the
/// same app), which app-activation notifications never fire for.
///
/// The module is `MainActor`-isolated by default (Package.swift
/// `.defaultIsolation(MainActor.self)`), so this class lives on the main actor
/// without annotation. Each per-app `AXObserver`'s run-loop source is installed on
/// the main run loop, so its C callback fires on the main thread and can hop back
/// into the actor via `MainActor.assumeIsolated` — the same proven pattern as
/// `KeyboardHook`.
final class FocusObserver {
    /// Delivered on the main actor with the CGWindowID of the newly focused window.
    private let onFocusChange: (CGWindowID) -> Void

    private let ownPid: pid_t = ProcessInfo.processInfo.processIdentifier

    /// Per-app messaging timeout — matches `WindowEnumerator` so a hung app can't
    /// stall observer setup.
    private static let messagingTimeout: Float = 0.15

    /// One live subscription per app. We keep the `AXObserver` (its run-loop source
    /// is retrieved from it again at teardown) and the app element used to add the
    /// notification (needed to remove it).
    private struct Subscription {
        let observer: AXObserver
        let appElement: AXUIElement
    }
    private var subscriptions: [pid_t: Subscription] = [:]

    init(onFocusChange: @escaping (CGWindowID) -> Void) {
        self.onFocusChange = onFocusChange
    }

    // MARK: Lifecycle

    func start() {
        // Subscribe to every already-running regular app.
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != ownPid {
            addObserver(pid: app.processIdentifier, allowRetry: true)
        }

        // Track apps that launch/terminate while we run. `.main` queue means the
        // block runs on the main thread → `assumeIsolated` is sound. We extract the
        // Sendable `pid_t` in the nonisolated delivery closure, before the hop.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            let isRegular = app?.activationPolicy == .regular
            MainActor.assumeIsolated {
                guard let self, let pid, isRegular, pid != self.ownPid else { return }
                self.addObserver(pid: pid, allowRetry: true)
            }
        }
        center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid else { return }
                self.removeObserver(pid: pid)
            }
        }
    }

    /// Called from the C callback (via `assumeIsolated`) with an already-resolved,
    /// Sendable window id.
    func deliver(_ windowID: CGWindowID) {
        onFocusChange(windowID)
    }

    // MARK: Subscription management

    /// Creates and installs an `AXObserver` for `pid`. On first-attempt failure
    /// (a freshly launched app may not yet be AX-ready) and when `allowRetry` is
    /// set, schedules one retry ~1s later. Never crashes; logs once per app on
    /// giving up.
    private func addObserver(pid: pid_t, allowRetry: Bool) {
        guard subscriptions[pid] == nil else { return }   // already subscribed

        var observer: AXObserver?
        let createErr = AXObserverCreate(pid, focusObserverCallback, &observer)
        guard createErr == .success, let observer else {
            logToStderr("FocusObserver: AXObserverCreate failed (\(createErr.rawValue)) for pid=\(pid)")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)

        // `passUnretained(self)`: `self` is owned by `MRUTracker` for the app's
        // lifetime, so it outlives every observer. The callback recovers it from
        // this refcon exactly like `KeyboardHook`'s `userInfo`.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let addErr = AXObserverAddNotification(
            observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon
        )
        guard addErr == .success else {
            if allowRetry {
                // Freshly launched app not AX-ready yet: retry exactly once. The
                // timer is on the main run loop → assumeIsolated is sound; we drop
                // the timer parameter to avoid a non-Sendable capture.
                Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.addObserver(pid: pid, allowRetry: false)
                    }
                }
            } else {
                logToStderr("FocusObserver: AXObserverAddNotification failed (\(addErr.rawValue)) for pid=\(pid)")
            }
            return
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode
        )
        subscriptions[pid] = Subscription(observer: observer, appElement: appElement)
    }

    /// Tears down the subscription for `pid`, if any. Balanced against
    /// `addObserver`: remove the notification, invalidate the run-loop source, and
    /// drop the strong references so ARC releases the observer.
    private func removeObserver(pid: pid_t) {
        guard let sub = subscriptions.removeValue(forKey: pid) else { return }
        AXObserverRemoveNotification(
            sub.observer, sub.appElement, kAXFocusedWindowChangedNotification as CFString
        )
        // Invalidate (not RemoveSource): it removes the source from every loop/mode
        // unconditionally and can't mode-mismatch the way RemoveSource can.
        CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(sub.observer))
    }
}

// MARK: - C callback (file-scope, non-capturing, nonisolated)

/// The `AXObserverCallback`. Must be a plain C function (no captures), hence
/// `nonisolated` and file-scope. Recovers the `FocusObserver` from `refcon`.
///
/// No `nonisolated(unsafe)` binding is needed here: `windowID(of:)` is
/// `nonisolated` and runs in this (nonisolated) body, so the only value crossing
/// into the `assumeIsolated` closure is the Sendable `CGWindowID`. Capturing
/// `instance` into that closure mirrors `keyboardHookCallback`'s capture of `hook`.
private nonisolated func focusObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let instance = Unmanaged<FocusObserver>.fromOpaque(refcon).takeUnretainedValue()

    // `element` IS the newly focused window element. Resolve it to a CGWindowID
    // here; only that Sendable value crosses the isolation boundary below.
    guard let wid = windowID(of: element) else { return }

    // The observer's run-loop source lives on the main run loop, so this callback
    // fires on the main thread → assumeIsolated is sound.
    MainActor.assumeIsolated {
        instance.deliver(wid)
    }
}
