import CoreGraphics
import Testing
@testable import AltAltTab

/// Covers the pure arithmetic in `SwitcherLayout`. Values below are derived
/// by hand from the constants declared there (`thumbnailWidth`/`Height`,
/// `titleHeight`, `cellInnerSpacing`, `cellPadding`, `cellSpacing`,
/// `stripPadding`) so a future change to those constants will need a
/// deliberate update here too, not just a silent pass.
struct SwitcherLayoutTests {
    // cellWidth = thumbnailWidth(220) + 2 * cellPadding(10) = 240
    // cellHeight = thumbnailHeight(140) + cellInnerSpacing(6) + titleHeight(16) + 2 * cellPadding(10) = 182

    @Test("contentWidth for zero cells is just the strip padding")
    func contentWidthZeroCells() {
        #expect(SwitcherLayout.contentWidth(count: 0) == 2 * SwitcherLayout.stripPadding)
    }

    @Test("contentWidth for one cell: one cellWidth plus strip padding, no inter-cell spacing")
    func contentWidthOneCell() {
        let expected = SwitcherLayout.cellWidth + 2 * SwitcherLayout.stripPadding
        #expect(SwitcherLayout.contentWidth(count: 1) == expected)
    }

    @Test("contentWidth for n cells composes cellWidth, (n-1) spacings, and strip padding")
    func contentWidthNCells() {
        let n = 5
        let expected = CGFloat(n) * SwitcherLayout.cellWidth
            + CGFloat(n - 1) * SwitcherLayout.cellSpacing
            + 2 * SwitcherLayout.stripPadding
        #expect(SwitcherLayout.contentWidth(count: n) == expected)
    }

    @Test("panelWidth returns contentWidth unclamped when the screen is wide enough")
    func panelWidthUnclamped() {
        let count = 3
        let screenWidth: CGFloat = 3000
        let expected = SwitcherLayout.contentWidth(count: count)
        #expect(expected < screenWidth * SwitcherLayout.maxScreenWidthFraction)
        #expect(SwitcherLayout.panelWidth(count: count, visibleScreenWidth: screenWidth) == expected)
    }

    @Test("panelWidth clamps to 0.9x screen width when content would overflow")
    func panelWidthClamped() {
        let count = 10
        let screenWidth: CGFloat = 200
        let clamp = screenWidth * SwitcherLayout.maxScreenWidthFraction
        #expect(SwitcherLayout.contentWidth(count: count) > clamp)
        #expect(SwitcherLayout.panelWidth(count: count, visibleScreenWidth: screenWidth) == clamp)
    }

    @Test("cellHeight composes thumbnail height, inner spacing, title height, and padding")
    func cellHeightComposition() {
        let expected = SwitcherLayout.thumbnailHeight
            + SwitcherLayout.cellInnerSpacing
            + SwitcherLayout.titleHeight
            + 2 * SwitcherLayout.cellPadding
        #expect(SwitcherLayout.cellHeight == expected)
    }

    @Test("panelHeight is cellHeight plus strip padding on both sides")
    func panelHeightComposition() {
        let expected = SwitcherLayout.cellHeight + 2 * SwitcherLayout.stripPadding
        #expect(SwitcherLayout.panelHeight == expected)
    }
}
