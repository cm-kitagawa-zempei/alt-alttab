import SwiftUI

/// The switcher overlay's content view. Deliberately has NO keyboard handling
/// whatsoever — no `.onKeyPress`, no focus management — because the panel
/// hosting this view is never key; the `KeyboardHook` event tap drives
/// selection exclusively. Only hover/click interactions are wired here.
///
/// Sizing: the root is deliberately FLEXIBLE (no `.fixedSize()`), filling
/// whatever frame AppKit gives the hosting view. `SwitcherPanel` computes the
/// panel frame arithmetically from `SwitcherLayout`; when the strip's content
/// is wider than that frame, the ScrollView clips and scrolls.
struct SwitcherView: View {
    let model: SwitcherModel
    let controller: SwitcherController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SwitcherLayout.cellSpacing) {
                    ForEach(Array(model.windows.enumerated()), id: \.element.windowID) { index, window in
                        SwitcherCell(
                            window: window,
                            isSelected: index == model.selectionIndex
                        )
                        .id(window.windowID)
                        .onHover { isHovering in
                            // NOTE: reveal-hover suppression lives in
                            // controller.select(index:) — on panel reveal,
                            // SwiftUI fires onHover for the cell under the
                            // stationary cursor, and select() ignores it until
                            // the mouse actually moves. Do not "simplify" by
                            // setting model.selectionIndex directly here.
                            if isHovering {
                                controller.select(index: index)
                            }
                        }
                        .onTapGesture {
                            controller.commitSelection(index: index)
                        }
                    }
                }
                .padding(SwitcherLayout.stripPadding)
            }
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .onChange(of: model.selectionIndex) {
                // Keyboard navigation: keep the selection visible while cycling.
                scrollToSelection(proxy, animated: true)
            }
            .onChange(of: model.revealRevision) {
                // Panel just became visible: jump (no animation) so the initial
                // selection is on-screen even when the strip scrolls — e.g. a
                // reverse session starting at the far right, or a strip left
                // scrolled from the previous session.
                scrollToSelection(proxy, animated: false)
            }
        }
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy, animated: Bool) {
        guard model.selectionIndex >= 0, model.selectionIndex < model.windows.count else { return }
        let selectedID = model.windows[model.selectionIndex].windowID
        if animated {
            withAnimation {
                proxy.scrollTo(selectedID, anchor: .center)
            }
        } else {
            proxy.scrollTo(selectedID, anchor: .center)
        }
    }
}

private struct SwitcherCell: View {
    let window: WindowInfo
    let isSelected: Bool

    var body: some View {
        VStack(spacing: SwitcherLayout.cellInnerSpacing) {
            ZStack(alignment: .bottomTrailing) {
                thumbnailArea
                    .opacity(window.isMinimized && AppSettings.shared.dimMinimizedWindows ? 0.55 : 1)
                if window.thumbnail != nil, let appIcon = window.appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                        .offset(x: 4, y: 4)
                }
                if window.isMinimized {
                    Image(systemName: "arrow.down.right.square.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .offset(x: -4, y: 4)
                }
            }
            .frame(width: SwitcherLayout.thumbnailWidth, height: SwitcherLayout.thumbnailHeight)

            Text(window.displayTitle)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: SwitcherLayout.thumbnailWidth, height: SwitcherLayout.titleHeight)
                .foregroundStyle(.secondary)
        }
        .padding(SwitcherLayout.cellPadding)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.15 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(isSelected ? 0.5 : 0.08), lineWidth: isSelected ? 2 : 1)
        )
    }

    @ViewBuilder
    private var thumbnailArea: some View {
        if let cgImage = window.thumbnail {
            Image(decorative: cgImage, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let appIcon = window.appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }
}
