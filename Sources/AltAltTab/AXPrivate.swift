import ApplicationServices
import CoreGraphics

// MARK: - The private-but-stable AX → CGWindowID bridge

/// The undocumented symbol AltTab / Rectangle / yabai all rely on to map an
/// accessibility window element to its `CGWindowID`. It has been stable across
/// macOS releases for a decade; there is no public equivalent.
///
/// `nonisolated` because it is a pure C ABI call with no shared state — it is
/// safe to invoke from anywhere, and keeping it off the actor avoids forcing
/// callers to hop.
@_silgen_name("_AXUIElementGetWindow")
nonisolated func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

/// Safe wrapper around `_AXUIElementGetWindow`: returns the window's
/// `CGWindowID`, or `nil` when the element cannot be resolved (e.g. a proxy
/// element, or the owning app died mid-query).
nonisolated func windowID(of element: AXUIElement) -> CGWindowID? {
    var wid = CGWindowID(0)
    guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { return nil }
    return wid
}

// MARK: - Small typed AX attribute getters

/// Copies a raw attribute value as a `CFTypeRef`, or `nil` on any AX error.
nonisolated func axCopyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value
}

/// Generic typed getter. Works for reference types that bridge cleanly from a
/// `CFTypeRef` (`String`, `[AXUIElement]`, `AXUIElement`, …). For `Bool` and
/// geometry, prefer the dedicated helpers below (CFBoolean / AXValue need
/// explicit unwrapping rather than an `as?` bridge).
nonisolated func axValue<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    axCopyValue(element, attribute) as? T
}

/// Reads a boolean attribute (e.g. `kAXMinimizedAttribute`). Explicitly unwraps
/// the CFBoolean rather than relying on `as? Bool`.
nonisolated func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    guard let value = axCopyValue(element, attribute) else { return nil }
    guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
    return CFBooleanGetValue((value as! CFBoolean))
}

/// Reads an `AXValue`-wrapped `CGPoint` (e.g. `kAXPositionAttribute`).
nonisolated func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    guard let value = axCopyValue(element, attribute),
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue((value as! AXValue), .cgPoint, &point) else { return nil }
    return point
}

/// Reads an `AXValue`-wrapped `CGSize` (e.g. `kAXSizeAttribute`).
nonisolated func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
    guard let value = axCopyValue(element, attribute),
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue((value as! AXValue), .cgSize, &size) else { return nil }
    return size
}

/// Reads a child-element array attribute (e.g. `kAXWindowsAttribute`).
nonisolated func axElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
    axCopyValue(element, attribute) as? [AXUIElement]
}

/// Reads a single child-element attribute (e.g. `kAXFocusedWindowAttribute`).
nonisolated func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = axCopyValue(element, attribute),
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
