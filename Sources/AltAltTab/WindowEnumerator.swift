import AppKit
import ApplicationServices
import CoreGraphics

/// Builds the list of switchable windows by walking every regular app's
/// accessibility tree and cross-referencing the CoreGraphics on-screen window
/// list for z-order. Each call is a fresh synchronous pass — AX elements go
/// stale and every switching session wants current state, so nothing is cached
/// across calls (M2). Target budget ~10–30 ms.
enum WindowEnumerator {

    /// Per-app messaging timeout. Kept short so a single hung app (spinning
    /// beachball) cannot stall the whole switcher; the default is measured in
    /// seconds. Applied to EVERY app element we create.
    private static let messagingTimeout: Float = 0.15

    /// Minimum window edge (points). Windows smaller than this on either axis are
    /// helper/proxy windows (tooltips, drag proxies, off-screen scratch windows)
    /// rather than something a user would switch to.
    private static let minWindowEdge: CGFloat = 40

    /// All switchable windows: on-screen windows first (front-to-back), then
    /// off-screen windows (minimized / hidden-app) in a stable tail.
    static func enumerateWindows() -> [WindowInfo] {
        // 1. CoreGraphics on-screen z-order. The array is front-to-back; we keep
        //    only layer-0 (normal) windows. Membership is used purely for ranking
        //    now — off-screen windows (rank == nil) sort into the tail (see below).
        let (zRank, _) = onScreenZOrder()

        let ownPid = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPid
        }

        var results: [WindowInfo] = []

        for app in apps {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            // CRITICAL: bound every message to this app so one unresponsive app
            // cannot freeze enumeration.
            _ = AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

            guard let axWindows = axElements(appElement, kAXWindowsAttribute) else { continue }

            let appName = app.localizedName ?? ""
            let bundleID = app.bundleIdentifier
            let appIcon = app.icon

            for axWindow in axWindows {
                // Must resolve to a CGWindowID; unresolvable elements are proxies
                // or already-gone windows.
                guard let wid = windowID(of: axWindow) else { continue }

                // M4: no on-screen filter. We keep minimized windows and windows
                // of hidden apps — the ones a user most wants to switch back to.
                // Off-screen windows have no z-rank and sort into the tail below.

                // Standard windows only — drop dialogs, palettes, sheets, popovers.
                let subrole: String? = axValue(axWindow, kAXSubroleAttribute)
                guard subrole == kAXStandardWindowSubrole else { continue }

                let title: String = axValue(axWindow, kAXTitleAttribute) ?? ""
                let isMinimized = axBool(axWindow, kAXMinimizedAttribute) ?? false

                let origin = axPoint(axWindow, kAXPositionAttribute) ?? .zero
                let size = axSize(axWindow, kAXSizeAttribute) ?? .zero
                // Drop tiny helper/proxy windows. Minimized windows still report
                // their restored size here, so this does not discard them.
                guard size.width >= minWindowEdge, size.height >= minWindowEdge else { continue }
                let frame = CGRect(origin: origin, size: size)

                results.append(WindowInfo(
                    windowID: wid,
                    pid: pid,
                    axWindow: axWindow,
                    appName: appName,
                    bundleID: bundleID,
                    title: title,
                    appIcon: appIcon,
                    isMinimized: isMinimized,
                    isAppHidden: app.isHidden,
                    frame: frame
                ))
            }
        }

        // 2. Sort by z-order (frontmost first). Windows with no rank sort last;
        //    the pairing with the original offset makes this a stable sort
        //    (Swift's `sorted` is not guaranteed stable on its own).
        return results.enumerated().sorted { lhs, rhs in
            let lRank = zRank[lhs.element.windowID] ?? Int.max
            let rRank = zRank[rhs.element.windowID] ?? Int.max
            if lRank != rRank { return lRank < rRank }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    /// The CGWindowID of the AX-focused window of the given app, if resolvable.
    static func focusedWindowID(pid: pid_t) -> CGWindowID? {
        let appElement = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        guard let focused = axElement(appElement, kAXFocusedWindowAttribute) else { return nil }
        return windowID(of: focused)
    }

    // MARK: - CoreGraphics z-order

    /// Returns `(rank, onScreenIDs)` from the on-screen window list, restricted
    /// to layer-0 (normal application) windows. `rank[wid]` is the front-to-back
    /// index (lower = more front); `onScreenIDs` is the membership set used as
    /// the on-screen filter.
    private static func onScreenZOrder() -> (rank: [CGWindowID: Int], onScreen: Set<CGWindowID>) {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return ([:], [])
        }

        var rank: [CGWindowID: Int] = [:]
        var onScreen: Set<CGWindowID> = []
        var index = 0

        for dict in list {
            // Only normal windows (layer 0); menus, the Dock, shadows, etc. sit
            // on other layers and must not participate in z-order or the filter.
            guard let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  let number = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value else {
                continue
            }
            let wid = CGWindowID(number)
            if rank[wid] == nil {
                rank[wid] = index
                onScreen.insert(wid)
                index += 1
            }
        }
        return (rank, onScreen)
    }
}
