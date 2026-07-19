import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - Logging

/// Tiny, greppable stderr logger. Deliberately `nonisolated` so it can be
/// called from the C event-tap callback context as well as from the main actor.
nonisolated func logToStderr(_ message: String) {
    FileHandle.standardError.write(Data(("[AltAltTab] " + message + "\n").utf8))
}

// MARK: - Public contract

/// The thing the keyboard hook drives. In M1 this is `M1AppSwitcher`; in M2 it
/// becomes the per-window switcher. The hook never inspects UI state — it only
/// sends these commands, so the "quick-switch" guarantee holds regardless of
/// whether any window/overlay has appeared yet.
protocol SwitcherDriving: AnyObject {
    var sessionActive: Bool { get }
    func beginSession(reverse: Bool)
    func advance(by delta: Int)   // +1 forward, -1 backward, wrapping is the delegate's job
    func commit()
    func cancel()
    /// Mid-session actions on the current selection. The session stays active
    /// after each (Cmd is still held), so several can run in a row.
    func closeSelectedWindow()
    func hideSelectedApp()
    func quitSelectedApp()
}

// MARK: - Keycodes

private enum KeyCode {
    static let tab: Int64 = 48
    static let escape: Int64 = 53
    static let left: Int64 = 123
    static let right: Int64 = 124
    static let w: Int64 = 13    // close selected window
    static let h: Int64 = 4     // hide selected app
    static let q: Int64 = 12    // quit selected app
}

// MARK: - KeyboardHook

/// System-wide CGEventTap that intercepts Cmd+Tab *before* the macOS app
/// switcher sees it, and swallows the relevant keys for the duration of a
/// switching session.
///
/// The whole module is `MainActor`-isolated by default (see Package.swift
/// `.defaultIsolation(MainActor.self)`), so this class is on the main actor
/// without annotation. The C callback, which cannot capture and must be a
/// plain C function, is a file-scope `nonisolated func` that hops back into
/// this instance via `MainActor.assumeIsolated` — sound because the run-loop
/// source lives on the main run loop, so the callback fires on the main thread.
final class KeyboardHook {
    private let delegate: any SwitcherDriving

    // Strong references keep the tap alive.
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?

    // State machine.
    private var previousFlagsHadCommand = false
    /// Keycodes we swallowed on the way *down*. We must also swallow their
    /// matching keyUp — even if the session ended between down and up — so that
    /// background apps never receive an orphan keyUp.
    private var pendingKeyUps: Set<Int64> = []

    init(delegate: any SwitcherDriving) {
        self.delegate = delegate
    }

    /// True iff the tap exists and CoreGraphics reports it enabled.
    var isTapActive: Bool {
        guard let machPort else { return false }
        return CGEvent.tapIsEnabled(tap: machPort)
    }

    // MARK: Lifecycle

    func start() {
        if createTap() { return }
        // Either Accessibility isn't granted yet, or tap creation failed
        // (e.g. right after a rebuild, before the user re-grants). Poll until
        // it succeeds so we recover without relaunching.
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        logToStderr("KeyboardHook: tap not yet available; polling every 1s (grant Accessibility if prompted)")
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop → fires on the main thread, so
            // assumeIsolated is sound. We ignore the timer parameter and use
            // self.retryTimer instead, avoiding a non-Sendable capture.
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.createTap() {
                    self.retryTimer?.invalidate()
                    self.retryTimer = nil
                }
            }
        }
    }

    /// Attempts to build and enable the tap. Returns true on success.
    private func createTap() -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardHookCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logToStderr("KeyboardHook: CGEvent.tapCreate returned nil (will retry)")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        self.machPort = port
        self.runLoopSource = source
        logToStderr("KeyboardHook: event tap created and enabled")
        return true
    }

    /// Called from the callback when the system reports the tap disabled.
    func reEnableTap() {
        guard let machPort else { return }
        logToStderr("KeyboardHook: tap was disabled by system; re-enabling")
        CGEvent.tapEnable(tap: machPort, enable: true)
    }

    // MARK: State machine

    /// Decides the fate of one event. Returns `nil` to swallow, or
    /// `Unmanaged.passUnretained(event)` to pass it through unchanged.
    /// Runs on the main actor (invoked under `assumeIsolated`).
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        switch type {
        case .flagsChanged:
            // NEVER swallow modifier changes — the OS needs modifier
            // consistency. Only observe them: commit exactly on the
            // Cmd-set → Cmd-clear transition while a session is active. Shift /
            // CapsLock / Fn / Option churn does not touch the command bit, so
            // it cannot trigger a commit.
            let hasCommand = event.flags.contains(.maskCommand)
            if delegate.sessionActive, previousFlagsHadCommand, !hasCommand {
                logToStderr("session commit (Cmd released)")
                delegate.commit()
            }
            previousFlagsHadCommand = hasCommand   // update regardless of session state
            return pass

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let cmdHeld = event.flags.contains(.maskCommand)
            let shiftHeld = event.flags.contains(.maskShift)

            if delegate.sessionActive {
                switch keyCode {
                case KeyCode.tab:
                    // Autorepeat keyDowns are handled identically — each counts
                    // as an additional advance (no autorepeat filtering).
                    logToStderr("session advance (Tab, shift=\(shiftHeld))")
                    delegate.advance(by: shiftHeld ? -1 : 1)
                case KeyCode.escape:
                    logToStderr("session cancel (Escape)")
                    delegate.cancel()
                case KeyCode.left:
                    logToStderr("session advance (Left)")
                    delegate.advance(by: -1)
                case KeyCode.right:
                    logToStderr("session advance (Right)")
                    delegate.advance(by: 1)
                case KeyCode.w, KeyCode.h, KeyCode.q:
                    // Close/hide/quit act only on the initial press. Ignoring
                    // autorepeat is essential: a held Q must not quit app after
                    // app. We still fall through to swallow the event (and its
                    // keyUp) so it never leaks — in particular this is what stops
                    // Cmd+Q from quitting the frontmost app.
                    let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) == 1
                    if !isAutorepeat {
                        switch keyCode {
                        case KeyCode.w:
                            logToStderr("session close window (W)")
                            delegate.closeSelectedWindow()
                        case KeyCode.h:
                            logToStderr("session hide app (H)")
                            delegate.hideSelectedApp()
                        default:
                            logToStderr("session quit app (Q)")
                            delegate.quitSelectedApp()
                        }
                    }
                default:
                    // Any other key mid-session: swallow and ignore, so nothing
                    // leaks into the frontmost app.
                    break
                }
                pendingKeyUps.insert(keyCode)
                return nil   // swallow every keyDown while a session is active
            } else {
                // No session: the only trigger is Cmd+Tab (Cmd must be in the
                // flags). Plain Tab, Ctrl+Tab, Opt+Tab pass through. Cmd+Shift+Tab
                // as the first press starts a reverse session.
                if keyCode == KeyCode.tab, cmdHeld {
                    logToStderr("session begin (reverse=\(shiftHeld))")
                    delegate.beginSession(reverse: shiftHeld)
                    pendingKeyUps.insert(keyCode)
                    return nil   // swallow
                }
                return pass
            }

        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if delegate.sessionActive {
                // Swallow every keyUp during a session; drop it from the pending
                // set since it's now accounted for.
                pendingKeyUps.remove(keyCode)
                return nil
            }
            // Session already ended: still swallow the matching keyUp of any key
            // we swallowed on the way down, so background apps never see an
            // orphan keyUp (e.g. the Tab keyUp that trails a commit/cancel).
            if pendingKeyUps.contains(keyCode) {
                pendingKeyUps.remove(keyCode)
                return nil
            }
            return pass

        default:
            return pass
        }
    }
}

// MARK: - C callback (file-scope, non-capturing, nonisolated)

/// The `CGEventTapCallBack`. Must be a plain C function (no captures), hence
/// `nonisolated` and file-scope. Recovers `self` from `userInfo`.
private nonisolated func keyboardHookCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // FIRST, before any state-machine dispatch: the system delivers tap
    // disable/re-enable as the `type` parameter (not as an error). Handle it
    // and pass the event through unmodified.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo {
            let hook = Unmanaged<KeyboardHook>.fromOpaque(userInfo).takeUnretainedValue()
            MainActor.assumeIsolated { hook.reEnableTap() }
        }
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let hook = Unmanaged<KeyboardHook>.fromOpaque(userInfo).takeUnretainedValue()

    // The source lives on the main run loop, so we are on the main thread here:
    // hop into the actor synchronously and return the decision. No async — the
    // swallow/pass verdict must be returned to CoreGraphics synchronously.
    //
    // nonisolated(unsafe) is sound: this callback provably runs on the main
    // thread (run-loop source on the main run loop), the closure executes
    // synchronously, and there is no concurrent access to these locals.
    nonisolated(unsafe) let ev = event
    nonisolated(unsafe) var result: Unmanaged<CGEvent>? = nil
    MainActor.assumeIsolated {
        result = hook.handle(type: type, event: ev)
    }
    return result
}
