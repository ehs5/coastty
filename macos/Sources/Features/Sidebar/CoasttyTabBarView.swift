import SwiftUI

/// coastty's own tab bar (issue #12, coastty repo): sits above the
/// terminal content pane only (to the right of the sidebar, never
/// spanning it), replacing Ghostty's native `NSWindowTabGroup` title-bar
/// tab strip. Reproduces the visual reference's structure — tab sizing,
/// spacing, truncation, the per-tab `⌘N` shortcut badge, active/inactive
/// distinction — with colors drawn from the live theme (`CoasttyPalette`)
/// rather than the reference's own hardcoded screenshot colors.
///
/// Round 2 (see `prototypes/native-tabs-reference-2.png` in the coastty
/// repo, added on top of the first reference): tabs grow/shrink together
/// to fill the bar's full width instead of leaving dead space after the
/// last one, use rounded (pill) shapes instead of a hard trailing
/// divider, and each tab lays out in three zones — leading status-icon
/// slot, centered title, trailing `⌘N` badge — instead of packing the
/// title and badge together as one left-aligned block.
struct CoasttyTabBarView: View {
    @ObservedObject var model: CoasttyTabBarModel
    @ObservedObject var ghostty: Ghostty.App

    static let height: CGFloat = 35

    /// Extra breathing room below the tab row, before the terminal content
    /// starts — drawn as part of *this* view's own `backgroundColor` fill
    /// (see `body`) so it stays theme/opacity-aware under any
    /// transparency/blur config, rather than a bare AppKit gap with
    /// nothing painting behind it.
    private static let contentGap: CGFloat = 5

    /// What `CoasttyTerminalPaneView` should size this view's own AppKit
    /// container to - `height` alone would clip `contentGap` off the
    /// bottom of what's actually drawn.
    static let totalHeight: CGFloat = height + contentGap

    /// A tab never shrinks below this even if the bar can't fit every
    /// open tab at this width — beyond that point the row scrolls
    /// horizontally instead, matching native macOS tab-bar behavior.
    private static let minTabWidth: CGFloat = 90
    private static let newTabButtonWidth: CGFloat = 34

    /// The spacing/padding the tab row itself adds around and between tabs
    /// (see the `HStack(spacing:)`/`.padding(.horizontal:)` below) — must be
    /// subtracted when sizing tabs, and the small gap reserved between the
    /// last tab and the new-tab button — issue #12 (coastty repo), Round 3.
    private static let interTabSpacing: CGFloat = 2
    private static let tabRowHorizontalPadding: CGFloat = 2
    private static let newTabButtonGap: CGFloat = 3

    /// The gap between the new-tab button and the window's trailing edge —
    /// the terminal content itself stays flush against the window's right
    /// edge (see `CoasttyTerminalPaneView`'s constraints); only this
    /// chrome control gets breathing room off the edge.
    private static let trailingMargin: CGFloat = 6

    private var palette: CoasttyPalette { CoasttyPalette(ghostty.config) }

    @State private var dragState = CoasttyDragReorderState<UUID>()
    /// Each tab's own on-screen frame, keyed by id, reported live by `CoasttyRowFramePreferenceKey`.
    @State private var rowFrames: [UUID: CGRect] = [:]
    /// `rowFrames` frozen at the instant a drag begins, so the drag's math compares against the bar's real pre-drag layout.
    @State private var dragStartFrames: [UUID: CGRect] = [:]

    /// Named so each tab's `GeometryReader` frame and its drag gesture are both measured relative to the tab row, not the whole window.
    fileprivate static let coordinateSpaceName = "coasttyTabsList"

    /// The bar's own plain background — the tinted "long line" treatment
    /// lives in `CoasttyTabRowBackground` now, sized/positioned to wrap
    /// only the tab row itself, not the whole bar (which would otherwise
    /// wrongly include the "+" button and its margins).
    private var backgroundColor: Color {
        palette.backgroundSidebar.opacity(ghostty.config.backgroundOpacity)
    }

    /// The row-wide "long line" background is now exactly the same size
    /// as an individual tab — no taller, no extra padding/border around
    /// it — per issue #12 (coastty repo).
    private static let tabRowBackgroundOverhang: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
        GeometryReader { geometry in
            let availableForTabs = max(
                0,
                geometry.size.width - Self.newTabButtonWidth - Self.newTabButtonGap - Self.trailingMargin
            )
            let tabWidth = Self.tabWidth(forCount: model.tabs.count, available: availableForTabs)

            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.interTabSpacing) {
                        ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                            CoasttyTabItemView(
                                tab: tab,
                                isActive: tab.id == model.activeTabID,
                                isDragging: tab.id == dragState.draggingID,
                                palette: palette,
                                onClose: { model.onClose?(tab.id) },
                                onCloseOthers: { model.onCloseOthers?(tab.id) },
                                onCloseToRight: { model.onCloseToRight?(tab.id) },
                                onRename: { model.onRename?(tab.id) },
                                onDragChanged: { translationX in
                                    handleTabDragChanged(tab: tab, translationX: translationX)
                                },
                                onDragEnded: {
                                    handleTabDragEnded(tab: tab)
                                }
                            )
                            .frame(width: tabWidth)
                            .background(
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: CoasttyRowFramePreferenceKey<UUID>.self,
                                        value: [tab.id: geometry.frame(in: .named(Self.coordinateSpaceName))]
                                    )
                                }
                            )
                            .offset(x: dragOffsetX(forTabAt: index, tabID: tab.id, targetIndex: targetIndex))
                            .zIndex(tab.id == dragState.draggingID ? 1 : 0)
                            .coasttyReorderRowAnimation(
                                isDragging: tab.id == dragState.draggingID,
                                translation: dragState.translation
                            )
                        }
                    }
                    .padding(.horizontal, Self.tabRowHorizontalPadding)
                }
                // Pinned to exactly the space not claimed by the new-tab
                // button (plus its gap), so the tabs above always fill the
                // bar's full width without overflowing it.
                .frame(width: availableForTabs)
                // Without this, the row's own reorder drag and the bar's
                // horizontal scroll can both respond to the same
                // mouse-down-and-move, drifting the tab's measured frame
                // away from the pointer as the drag goes on.
                .scrollDisabled(dragState.draggingID != nil)
                .coordinateSpace(name: Self.coordinateSpaceName)
                .onPreferenceChange(CoasttyRowFramePreferenceKey<UUID>.self) { rowFrames = $0 }
                // The "long line" tinted background behind the tab row -
                // matching the tabs' own shape, narrowed by
                // `tabRowHorizontalPadding` on each side so its edges line
                // up with the first/last tab's own rounded corners exactly
                // (the tabs themselves sit inset by that same padding).
                .background(alignment: .center) {
                    CoasttyMetrics.controlShape
                        .fill(palette.backgroundTabResting.opacity(ghostty.config.backgroundOpacity))
                        .frame(
                            width: max(0, availableForTabs - Self.tabRowHorizontalPadding * 2),
                            height: CoasttyTabBarView.height - 6 + Self.tabRowBackgroundOverhang
                        )
                }

                Spacer(minLength: Self.newTabButtonGap)
                    .frame(width: Self.newTabButtonGap)

                CoasttyNewTabButton(palette: palette) { model.onNew?() }
                    .frame(width: Self.newTabButtonWidth)

                Spacer(minLength: Self.trailingMargin)
                    .frame(width: Self.trailingMargin)
            }
            .frame(width: geometry.size.width, height: Self.height)
        }
        .frame(height: Self.height)

            // The extra breathing room below the tab row (see `contentGap`).
            Color.clear
                .frame(height: Self.contentGap)
        }
        .background(backgroundColor)
    }

    /// Distributes `available` width evenly across `count` tabs — as tabs
    /// are added they shrink together to keep filling the bar, matching
    /// native macOS tab-bar sizing, down to `minTabWidth`; beyond that the
    /// row scrolls instead of shrinking further.
    ///
    /// Reserves the row's own inter-tab spacing and horizontal padding
    /// (`interTabSpacing`/`tabRowHorizontalPadding`) before dividing, so
    /// `count * tabWidth` plus that overhead lands exactly on `available`
    /// instead of overflowing it.
    private static func tabWidth(forCount count: Int, available: CGFloat) -> CGFloat {
        guard count > 0 else { return available }
        let overhead = tabRowHorizontalPadding * 2 + interTabSpacing * CGFloat(count - 1)
        let usable = max(0, available - overhead)
        return max(usable / CGFloat(count), minTabWidth)
    }

    /// The dragged tab's index before the drag moved anything.
    private var dragOriginalIndex: Int? {
        guard let draggingID = dragState.draggingID else { return nil }
        return model.tabs.firstIndex { $0.id == draggingID }
    }

    /// The slot the dragged tab currently belongs in, from how many other tabs' frozen midpoints now sit to its left.
    private var targetIndex: Int? {
        guard let draggingID = dragState.draggingID, let originalFrame = dragStartFrames[draggingID] else { return nil }
        let pointerX = originalFrame.midX + dragState.translation

        var index = 0
        for tab in model.tabs where tab.id != draggingID {
            guard let frame = dragStartFrames[tab.id] else { continue }
            if pointerX > frame.midX { index += 1 }
        }
        return min(index, model.tabs.count - 1)
    }

    /// The tab being dragged tracks the cursor directly, bounded to the bar's own extent; every other tab between its original and current slot shifts by one slot-width to make room.
    private func dragOffsetX(forTabAt index: Int, tabID: UUID, targetIndex: Int?) -> CGFloat {
        guard let draggingID = dragState.draggingID,
              let originalIndex = dragOriginalIndex,
              let slotSize = dragStartFrames[draggingID].map({ $0.width + Self.interTabSpacing })
        else { return 0 }

        if tabID == draggingID {
            return dragState.clampedTranslation(originalIndex: originalIndex, count: model.tabs.count, slotSize: slotSize)
        }
        guard let targetIndex else { return 0 }
        return CoasttyDragReorderState<UUID>.siblingOffset(forIndexAt: index, originalIndex: originalIndex, targetIndex: targetIndex, slotSize: slotSize)
    }

    /// Selects `tab` the moment its drag starts, then tracks the live translation.
    private func handleTabDragChanged(tab: CoasttyTabBarModel.Tab, translationX: CGFloat) {
        dragState.changed(id: tab.id, translation: translationX) {
            dragStartFrames = rowFrames
            model.onSelect?(tab.id)
        }
    }

    /// Commits the reorder via `model.onMove` if the drag actually moved `tab` to a new slot.
    private func handleTabDragEnded(tab: CoasttyTabBarModel.Tab) {
        // Read from live state here rather than passed in by the caller: the
        // closure invoking this was built at the last render, which can
        // predate the final mouse event.
        let finalIndex = targetIndex
        defer {
            dragState.reset()
            dragStartFrames = [:]
        }
        guard let originalIndex = model.tabs.firstIndex(where: { $0.id == tab.id }),
              let finalIndex, finalIndex != originalIndex
        else { return }
        model.onMove?(originalIndex, finalIndex)
    }
}

private struct CoasttyTabItemView: View {
    let tab: CoasttyTabBarModel.Tab
    let isActive: Bool
    let isDragging: Bool
    let palette: CoasttyPalette
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseToRight: () -> Void
    let onRename: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    /// The leading (status icon) and trailing (badge/close) zones are kept
    /// the same width so the center title zone reads as truly centered,
    /// not just left-aligned-after-the-icon.
    private static let edgeZoneWidth: CGFloat = 24

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                CoasttyStatusIconView(status: tab.status, palette: palette)
            }
            .frame(width: Self.edgeZoneWidth, alignment: .center)

            Text(tab.title)
                .font(.system(size: CoasttyMetrics.titleFontSize))
                .foregroundColor(isActive ? palette.textPrimary : palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack {
                if isHovering {
                    CoasttyCloseButton(palette: palette, action: onClose)
                        .coasttyFadeDuringDrag(isDragging)
                } else if let shortcutLabel = tab.shortcutLabel {
                    Text(shortcutLabel)
                        .font(.system(size: 10))
                        .foregroundColor(palette.textTertiary)
                }
            }
            .frame(width: Self.edgeZoneWidth, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: CoasttyTabBarView.height - 6)
        .background(
            CoasttyMetrics.controlShape
                .fill(isActive ? palette.backgroundSelected : (isHovering ? palette.backgroundHover : palette.backgroundTabResting))
        )
        .contentShape(CoasttyMetrics.controlShape)
        .onHover { isHovering = $0 }
        .coasttyDragToReorder(
            axis: .horizontal,
            coordinateSpace: .named(CoasttyTabBarView.coordinateSpaceName),
            onChanged: onDragChanged,
            onEnded: onDragEnded
        )
        // Mirrors Ghostty's own native tab context menu (see
        // TerminalWindow.configureTabContextMenuIfNeeded/
        // appendTabModifierSection) for coastty's own SwiftUI tab bar,
        // which doesn't get AppKit's native tab menu for free since
        // native tabbing is disabled. "Move Tab to New Window" and the
        // tab-color palette aren't ported - the former has no coastty-tab
        // equivalent yet, and the latter is tied to AppKit's per-window
        // tabColor, which doesn't map onto coastty's own multi-tab model.
        .contextMenu {
            Button("Close Tab", action: onClose)
            Button("Close Other Tabs", action: onCloseOthers)
            Button("Close Tabs to the Right", action: onCloseToRight)
            Divider()
            Button("Rename Tab...", action: onRename)
        }
    }
}

private struct CoasttyNewTabButton: View {
    let palette: CoasttyPalette
    let action: () -> Void

    // Round 3 (issue #12, coastty repo): the reference screenshot's + button
    // has a real resting-state background, darker than the bar's own
    // background, and a larger tap target than the previous 20pt/transparent
    // button — it used to only show a background on hover.
    //
    // Matches an individual tab's own height exactly (not a separately
    // chosen number) so the button reads as the same size as the tabs
    // next to it.
    private static let diameter: CGFloat = CoasttyTabBarView.height - 6

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(palette.textSecondary)
                .frame(width: Self.diameter, height: Self.diameter)
                .background(Circle().fill(isHovering ? palette.backgroundNewTabButtonHover : palette.backgroundNewTabButton))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
