import AppKit
import Foundation
import Observation

/// Observable state backing the switcher overlay's SwiftUI view.
@Observable final class SwitcherModel {
    var windows: [WindowInfo] = []
    var selectionIndex: Int = 0
    /// Bumped by `SwitcherPanel.show()` right after the panel becomes visible.
    /// The view observes it to jump-scroll the initial selection into view
    /// (`onChange(of: selectionIndex)` cannot cover the session's *initial*
    /// selection — no change event fires for it).
    var revealRevision: Int = 0
    /// Mouse location captured by `SwitcherPanel.show()` at the moment the
    /// panel appears. While non-nil, `select(index:)` ignores hover events
    /// whose cursor hasn't moved away from this anchor — SwiftUI fires a
    /// synthetic `.onHover` for whichever cell sits under the STATIONARY
    /// cursor on reveal, which would silently steal the initial selection.
    var revealMouseLocation: CGPoint? = nil
}

/// Milestone-2 `SwitcherDriving` implementation: switches between *windows*
/// (replaces M1's per-application `M1AppSwitcher`). Drives an `NSPanel`
/// overlay (`SwitcherPanel`) showing the current MRU-ordered window list.
///
/// The module is `MainActor`-isolated by default, so this class is on the
/// main actor without annotation.
final class SwitcherController: SwitcherDriving {
    let model = SwitcherModel()
    private let mru = MRUTracker()
    private let thumbnails = ThumbnailService()
    private lazy var panel = SwitcherPanel(model: model, controller: self)

    private var _sessionActive = false
    var sessionActive: Bool { _sessionActive }

    /// Bumped on every `beginSession`; lets a delayed `panel.show()` verify it
    /// is still scheduled for the session it was scheduled for before firing.
    private var sessionGeneration = 0

    init() {}

    // MARK: SwitcherDriving

    func beginSession(reverse: Bool) {
        // Read settings fresh every session — no caching, so changes made in the
        // settings window apply to the very next Cmd+Tab.
        let settings = AppSettings.shared
        let candidates = WindowEnumerator.enumerateWindows().filter { window in
            if window.isMinimized && !settings.showMinimizedWindows { return false }
            if window.isAppHidden && !settings.showHiddenAppWindows { return false }
            return true
        }
        let ordered = mru.order(candidates)
        guard !ordered.isEmpty else {
            logToStderr("SwitcherController: begin with no windows; staying inactive")
            return
        }

        _sessionActive = true
        sessionGeneration += 1
        model.windows = ordered
        // Index 0 is the current window, index 1 the previous one — a quick
        // Cmd+Tab toggle lands on the previous window.
        model.selectionIndex = ordered.count > 1 ? (reverse ? ordered.count - 1 : 1) : 0
        thumbnails.refreshShareableContent()
        thumbnails.populateThumbnails(model: model)

        // Delay showing the overlay: a quick Cmd+Tab tap (release before this
        // fires) should commit with no visual flash, like the system switcher.
        // Holding Cmd shows the panel after a short grace period.
        let generationAtSchedule = sessionGeneration
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            if _sessionActive && generationAtSchedule == sessionGeneration {
                panel.show()
            }
        }

        logToStderr("SwitcherController: begin reverse=\(reverse) count=\(ordered.count) selection=\(model.selectionIndex)")
    }

    func advance(by delta: Int) {
        guard _sessionActive else { return }
        let count = model.windows.count
        guard count > 0 else { return }
        // Wrap correctly for negative deltas too.
        model.selectionIndex = ((model.selectionIndex + delta) % count + count) % count
        logToStderr("SwitcherController: advance by \(delta) -> selection=\(model.selectionIndex)")
    }

    func commit() {
        guard _sessionActive else { return }
        _sessionActive = false
        // Hide before focusing to avoid the panel flashing over the raised window.
        panel.hide()

        guard model.selectionIndex >= 0, model.selectionIndex < model.windows.count else {
            logToStderr("SwitcherController: commit with no valid selection")
            return
        }
        let selected = model.windows[model.selectionIndex]
        WindowFocuser.focus(selected)
        mru.noteFocused(selected.windowID)
        logToStderr("SwitcherController: commit focus windowID=\(selected.windowID) title=\(selected.title)")
    }

    func cancel() {
        guard _sessionActive else { return }
        _sessionActive = false
        panel.hide()
        logToStderr("SwitcherController: cancel")
    }

    // MARK: Mid-session actions (Cmd still held; session stays active)

    /// W: close the currently selected window, then drop just that one entry
    /// from the strip.
    func closeSelectedWindow() {
        guard let selected = currentSelection() else { return }
        WindowActions.close(selected)
        logToStderr("SwitcherController: close window title=\(selected.title) app=\(selected.appName)")
        model.windows.remove(at: model.selectionIndex)
        finishAction()
    }

    /// H: hide the selected window's application, then drop every window of that
    /// app from the strip.
    func hideSelectedApp() {
        guard let selected = currentSelection() else { return }
        WindowActions.hide(selected)
        logToStderr("SwitcherController: hide app=\(selected.appName) pid=\(selected.pid)")
        model.windows.removeAll { $0.pid == selected.pid }
        finishAction()
    }

    /// Q: quit the selected window's application, then drop every window of that
    /// app from the strip.
    func quitSelectedApp() {
        guard let selected = currentSelection() else { return }
        WindowActions.quit(selected)
        logToStderr("SwitcherController: quit app=\(selected.appName) pid=\(selected.pid)")
        model.windows.removeAll { $0.pid == selected.pid }
        finishAction()
    }

    /// The current selection, or nil if the session is inactive or the index is
    /// out of range. Read the `WindowInfo` before any mutation of `model.windows`.
    private func currentSelection() -> WindowInfo? {
        guard _sessionActive,
              model.selectionIndex >= 0,
              model.selectionIndex < model.windows.count else { return nil }
        return model.windows[model.selectionIndex]
    }

    /// After removing entries: end the session if the strip is now empty,
    /// otherwise clamp the selection and re-show the panel so its frame tracks
    /// the new window count. Keeping the same index makes the selection slide
    /// onto whatever entry took the removed one's place.
    private func finishAction() {
        if model.windows.isEmpty {
            // Mirror cancel(): no window left to focus, so just tear down.
            _sessionActive = false
            panel.hide()
            logToStderr("SwitcherController: strip empty after action; ending session")
            return
        }
        if model.selectionIndex >= model.windows.count {
            model.selectionIndex = model.windows.count - 1
        }
        // Re-show is idempotent: it recomputes the panel frame from the new
        // count. Showing slightly early during the 100ms delay window is fine —
        // the delayed show's own generation/active guards prevent an orphan.
        panel.show()
    }

    // MARK: UI-driven entry points

    /// Called when the pointer hovers a cell. Reveal-hover suppression: right
    /// after the panel appears, SwiftUI delivers a hover for the cell under the
    /// stationary cursor; until the cursor actually moves away from the anchor
    /// recorded at reveal, such hovers are ignored so they cannot steal the
    /// initial selection.
    func select(index: Int) {
        guard _sessionActive, index >= 0, index < model.windows.count else { return }
        if let anchor = model.revealMouseLocation {
            let now = NSEvent.mouseLocation
            // Cursor hasn't really moved → synthetic reveal-hover, ignore.
            guard abs(now.x - anchor.x) > 4 || abs(now.y - anchor.y) > 4 else { return }
            // Real movement → hover behaves normally from here on.
            model.revealMouseLocation = nil
        }
        model.selectionIndex = index
    }

    /// Called when a cell is clicked.
    func commitSelection(index: Int) {
        guard _sessionActive, index >= 0, index < model.windows.count else { return }
        model.selectionIndex = index
        commit()
    }
}
