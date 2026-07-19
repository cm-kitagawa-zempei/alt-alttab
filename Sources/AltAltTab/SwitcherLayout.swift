import CoreGraphics

/// Layout constants shared by `SwitcherView` (SwiftUI layout) and
/// `SwitcherPanel` (arithmetic panel sizing). Keeping them in one place is what
/// lets the panel compute its frame without asking SwiftUI — and guarantees the
/// two layers can never drift apart.
enum SwitcherLayout {
    /// Thumbnail area inside a cell.
    static let thumbnailWidth: CGFloat = 220
    static let thumbnailHeight: CGFloat = 140

    /// Fixed height reserved for the one-line caption title under the thumbnail.
    static let titleHeight: CGFloat = 16

    /// VStack spacing between thumbnail area and title inside a cell.
    static let cellInnerSpacing: CGFloat = 6

    /// Padding around a cell's content (inside the selection background).
    static let cellPadding: CGFloat = 10

    /// HStack spacing between cells.
    static let cellSpacing: CGFloat = 12

    /// Padding around the whole cell strip (inside the material background).
    static let stripPadding: CGFloat = 16

    /// The panel never exceeds this fraction of the target screen's visible width.
    static let maxScreenWidthFraction: CGFloat = 0.9

    /// Full outer size of one cell.
    static var cellWidth: CGFloat { thumbnailWidth + 2 * cellPadding }
    static var cellHeight: CGFloat {
        thumbnailHeight + cellInnerSpacing + titleHeight + 2 * cellPadding
    }

    /// Total content width of the strip for `count` cells (cells + inter-cell
    /// spacing + strip padding).
    static func contentWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 2 * stripPadding }
        return CGFloat(count) * cellWidth
            + CGFloat(count - 1) * cellSpacing
            + 2 * stripPadding
    }

    /// Panel height is content height: one row of cells plus strip padding.
    static var panelHeight: CGFloat { cellHeight + 2 * stripPadding }

    /// Panel width for `count` cells on a screen of the given visible width.
    static func panelWidth(count: Int, visibleScreenWidth: CGFloat) -> CGFloat {
        min(contentWidth(count: count), visibleScreenWidth * maxScreenWidthFraction)
    }
}
