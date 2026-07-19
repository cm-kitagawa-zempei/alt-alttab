import AppKit
import SwiftUI

/// Non-activating overlay panel that hosts `SwitcherView`. Never becomes key —
/// the `KeyboardHook` event tap drives all keyboard input, so the panel must
/// stay out of the key-window chain entirely.
///
/// The module is `MainActor`-isolated by default, so this class is on the
/// main actor without annotation.
final class SwitcherPanel {
    private let model: SwitcherModel
    private unowned let controller: SwitcherController

    private var _panel: NSPanel?

    init(model: SwitcherModel, controller: SwitcherController) {
        self.model = model
        self.controller = controller
    }

    // MARK: Lazy panel construction

    private func makePanel() -> NSPanel {
        let hostingView = NSHostingView(rootView: SwitcherView(model: model, controller: controller))
        // The panel frame is computed arithmetically from SwitcherLayout in
        // show(); the hosting view must never fight that by imposing SwiftUI's
        // ideal size (the full strip width) on the window.
        hostingView.sizingOptions = []

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = hostingView

        return panel
    }

    private var panel: NSPanel {
        if let existing = _panel { return existing }
        let created = makePanel()
        _panel = created
        return created
    }

    // MARK: Show / hide

    func show() {
        let targetScreen = screenContainingMouse()

        // Compute the frame arithmetically from the shared layout constants —
        // no dependence on the hosting view's fittingSize (which reports the
        // FULL strip width and defeated the clamp; see SwitcherLayout). Sizing
        // before ordering front avoids any zero-size flash. The width is
        // clamped to 90% of the target screen's visible width; when content is
        // wider, the SwiftUI ScrollView clips and scrolls inside this frame.
        let count = model.windows.count
        let visibleWidth = targetScreen?.visibleFrame.width ?? .greatestFiniteMagnitude
        let size = NSSize(
            width: SwitcherLayout.panelWidth(count: count, visibleScreenWidth: visibleWidth),
            height: SwitcherLayout.panelHeight
        )

        var frame = NSRect(origin: .zero, size: size)
        if let targetScreen {
            let visible = targetScreen.visibleFrame
            let originX = visible.midX - size.width / 2
            // Slightly above center.
            let originY = visible.midY - size.height / 2 + visible.height * 0.08
            frame.origin = NSPoint(x: originX, y: originY)
        }

        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()

        // Now that the panel is visible (layout exists), tell the view to
        // jump-scroll the initial selection into view.
        model.revealRevision += 1

        // Anchor for reveal-hover suppression (see SwitcherController.select):
        // set on EVERY show — both the initial reveal and the W/H/Q re-show —
        // because each is a moment where a stationary cursor can receive a
        // synthetic hover from the freshly laid-out strip.
        model.revealMouseLocation = NSEvent.mouseLocation
    }

    func hide() {
        _panel?.orderOut(nil)
    }

    // MARK: Helpers

    private func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    }
}
