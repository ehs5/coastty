import SwiftUI
import AppKit

/// coastty's attention sidebar: "Spaces" on top, "Agents" pinned to
/// exactly the bottom half by default, with a real draggable divider
/// between them whose ratio persists. Reproduces variant C ("Native
/// List") of the visual reference (coastty's `prototype/sidebar-design`
/// branch) exactly, not a reinterpretation of it.
struct CoasttySidebarView: View {
    let model: CoasttySidebarModel

    /// Observed (not just read once) so the sidebar's colors live-update
    /// the moment the user's Ghostty config/theme reloads — issue #12
    /// (coastty repo): colors must come from the live configured theme.
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject private var ratioStore = CoasttySidebarSplitRatioStore.shared

    /// The width a sidebar opens at before the user has ever dragged one.
    /// Narrower than the visual reference's 260pt: the reference's sidebar
    /// was not resizable at all, so it had to be wide enough for the
    /// longest name anyone might use, whereas a resizable one only has to
    /// be wide enough for the common case.
    static let defaultWidth: CGFloat = 220

    /// The narrowest the user can drag the sidebar. Below roughly this,
    /// `CoasttyAgentRowView`'s `folder · tab name` line truncates to the
    /// point of being unreadable, so the sidebar stops being useful rather
    /// than merely being small.
    static let minimumWidth: CGFloat = 180

    /// The widest the user can drag the sidebar, as a fraction of the
    /// window's own content area. Against the window rather than the
    /// screen: in a window taking up half the display, half the *screen*
    /// is the entire window, which is not a bound at all.
    static let maximumWidthWindowFraction: CGFloat = 0.5

    /// The gap between the Spaces and Agents panels — also where the
    /// invisible drag handle for resizing their split lives.
    private static let sectionGap: CGFloat = 10

    private var palette: CoasttyPalette { CoasttyPalette(ghostty.config) }

    /// Called when the user clicks the Spaces section's "+ New" control.
    /// Defaults to a no-op so the two call sites that don't need it (tests,
    /// previews) don't have to supply one.
    var onNewSpace: () -> Void = {}

    /// Called with a Space's `id` when the user clicks its row to switch to
    /// it — issue #12 (coastty repo), Round 4. Defaults to a no-op for the
    /// same reason as `onNewSpace` above.
    var onSelectSpace: (UUID) -> Void = { _ in }

    /// Called with an Agents-section row's id when it is clicked, to bring
    /// that pane to the front. Defaults to a no-op for the same reason as
    /// `onNewSpace` above.
    var onSelectAgent: (UUID) -> Void = { _ in }

    /// Called with a Space's `id` when the user closes it, via either the
    /// row's own (×) control or its right-click menu's "Close" item.
    /// Defaults to a no-op for the same reason as `onNewSpace` above.
    var onCloseSpace: (UUID) -> Void = { _ in }

    /// Called with a Space's `id` when the user picks "Rename..." from its
    /// row's right-click menu. Defaults to a no-op for the same reason as
    /// `onNewSpace` above.
    var onRenameSpace: (UUID) -> Void = { _ in }

    /// Called with (fromIndex, toIndex) once a drag-to-reorder in the
    /// Spaces list ends with the dragged Space's index actually changed.
    /// Defaults to a no-op for the same reason as `onNewSpace` above.
    var onMoveSpace: (Int, Int) -> Void = { _, _ in }

    /// Backing the sidebar's outer canvas/margin area — the part visible
    /// only where it borders the real window/terminal background, not the
    /// rounded panel's own fill.
    ///
    /// This DOES apply `backgroundOpacity`, unlike the panel below:
    /// `TerminalWindow.preferredBackgroundColor` factors the focused
    /// surface's own live background/opacity into the *real* window
    /// background color it sets — a flat, always-opaque canvas here
    /// visibly mismatched against that whenever `background-opacity` is
    /// non-default, since the margin borders that real window background
    /// directly. The panel itself doesn't have this problem (it's a
    /// distinct, deliberately-opaque card, not bordering the window
    /// background at all) — see `panelBackgroundColor`.
    private var backgroundColor: Color {
        palette.backgroundSidebar.opacity(ghostty.config.backgroundOpacity)
    }

    /// The rounded panel's own fill — a faint step up from the plain
    /// canvas (see `CoasttyPalette.backgroundSidebarPanel`) so the panel
    /// reads as a raised card sitting inside the window rather than
    /// invisible padding, even though both colors are derived from the
    /// same configured theme. Applies `backgroundOpacity` like every
    /// other coastty surface does (the canvas above, the tab bar, the
    /// terminal pane's own gap), for the same reason.
    private var panelBackgroundColor: Color {
        palette.backgroundSidebarPanel.opacity(ghostty.config.backgroundOpacity)
    }

    /// Gap between the sidebar's outer edge and its two rounded panels —
    /// design/sidebar-rounded-sections (issue #12, coastty repo): keeps
    /// both panels off the window's edges so each reads as a distinct card
    /// floating inside the existing (untouched, opaque) titlebar chrome,
    /// rather than a flush, edge-to-edge region with an abrupt seam right
    /// under the titlebar.
    ///
    /// The top margin is intentionally small (not matching the side/bottom
    /// margins) — it's sized to line up the "SPACES" label's own top edge
    /// with the tab bar's tab row directly to its right, not to visually
    /// balance the panel's own inset on every side.
    private static let panelTopMargin: CGFloat = 3
    private static let panelBottomMargin: CGFloat = 10

    /// Not private, unlike the other two: the sidebar's canvas is the same
    /// color as the terminal background, so the panel's own trailing edge —
    /// this far in from the pane boundary — is the only edge the user can
    /// actually see. `CoasttySidebarResizeHandleView` centers on it for
    /// that reason.
    static let panelSideMargin: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let panelWidth = max(0, geometry.size.width - Self.panelSideMargin * 2)
            let panelsHeight = max(
                0,
                geometry.size.height - Self.panelTopMargin - Self.panelBottomMargin - Self.sectionGap
            )
            let agentsHeight = panelsHeight * ratioStore.agentsRatio
            let spacesHeight = panelsHeight - agentsHeight

            VStack(spacing: 0) {
                CoasttySpacesSection(
                    spaces: model.spaces,
                    activeSpaceID: model.activeSpaceID,
                    palette: palette,
                    rowGap: ghostty.config.spaceRowGap,
                    onSelectSpace: onSelectSpace,
                    onNewSpace: onNewSpace,
                    onCloseSpace: onCloseSpace,
                    onRenameSpace: onRenameSpace,
                    onMoveSpace: onMoveSpace
                )
                .frame(width: panelWidth, height: spacesHeight)
                .background(panelBackgroundColor)
                .clipShape(CoasttyMetrics.panelShape)

                CoasttySidebarDragHandle(totalHeight: panelsHeight, ratioStore: ratioStore)
                    .frame(width: panelWidth, height: Self.sectionGap)

                CoasttyAgentsSection(
                    rows: model.agentRows,
                    palette: palette,
                    rowGap: ghostty.config.spaceRowGap,
                    shortcutLabel: model.agentsShortcutLabel,
                    onSelectAgent: onSelectAgent
                )
                    .frame(width: panelWidth, height: agentsHeight)
                    .background(panelBackgroundColor)
                    .clipShape(CoasttyMetrics.panelShape)
            }
            .padding(.top, Self.panelTopMargin)
            .padding(.bottom, Self.panelBottomMargin)
            .padding(.horizontal, Self.panelSideMargin)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        // No width of its own: the sidebar is user-resizable, and the split
        // view item's pinned thickness is the single source of truth for
        // how wide it currently is. Declaring a width here too made the
        // two disagree for a frame at a time mid-drag, which showed up as
        // the sidebar's contents stretching while the edge was moving.
        .background(backgroundColor)
    }
}

// MARK: - Spaces section

/// One collapsed row per workspace: a single aggregated status icon plus
/// the workspace's name — never a nested tab list.
private struct CoasttySpacesSection: View {
    let spaces: [CoasttySpaceSummary]
    let activeSpaceID: UUID?
    let palette: CoasttyPalette
    let rowGap: CGFloat
    let onSelectSpace: (UUID) -> Void
    let onNewSpace: () -> Void
    let onCloseSpace: (UUID) -> Void
    let onRenameSpace: (UUID) -> Void
    let onMoveSpace: (Int, Int) -> Void

    @State private var dragState = CoasttyDragReorderState<UUID>()
    /// Each row's own on-screen frame, keyed by Space id, reported live by `CoasttyRowFramePreferenceKey`.
    @State private var rowFrames: [UUID: CGRect] = [:]
    /// `rowFrames` frozen at the instant a drag begins, so the drag's math compares against the list's real pre-drag layout.
    @State private var dragStartFrames: [UUID: CGRect] = [:]

    /// Named so each row's `GeometryReader` frame and its drag gesture are both measured relative to this list, not the whole window.
    fileprivate static let coordinateSpaceName = "coasttySpacesList"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoasttySectionLabel(text: "Spaces", palette: palette)
            ScrollView {
                // Without a gap, two adjacent filled capsules (one active,
                // one hovering) touch edge-to-edge with no gap.
                LazyVStack(alignment: .leading, spacing: rowGap) {
                    ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                        CoasttySpaceRow(
                            space: space,
                            palette: palette,
                            isActive: space.id == activeSpaceID,
                            isDragging: space.id == dragState.draggingID,
                            onClose: { onCloseSpace(space.id) },
                            onRename: { onRenameSpace(space.id) },
                            onDragChanged: { translationY in
                                handleDragChanged(space: space, translationY: translationY)
                            },
                            onDragEnded: {
                                handleDragEnded(space: space)
                            }
                        )
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: CoasttyRowFramePreferenceKey<UUID>.self,
                                    value: [space.id: geometry.frame(in: .named(Self.coordinateSpaceName))]
                                )
                            }
                        )
                        .offset(y: offsetY(forSpaceAt: index, spaceID: space.id))
                        .zIndex(space.id == dragState.draggingID ? 1 : 0)
                        .coasttyReorderRowAnimation(
                            isDragging: space.id == dragState.draggingID,
                            translation: dragState.translation
                        )
                    }
                }
            }
            .coordinateSpace(name: Self.coordinateSpaceName)
            .onPreferenceChange(CoasttyRowFramePreferenceKey<UUID>.self) { rowFrames = $0 }
            // A non-scrolling footer row, appended after the ScrollView
            // (not inside its LazyVStack) so it stays pinned at the
            // bottom-left of the section instead of scrolling away with
            // the space list — issue #12 (coastty repo), Round 3.
            CoasttyNewSpaceRow(palette: palette, action: onNewSpace)
        }
    }

    /// The dragged Space's index before the drag moved anything.
    private var draggingOriginalIndex: Int? {
        guard let draggingID = dragState.draggingID else { return nil }
        return spaces.firstIndex { $0.id == draggingID }
    }

    /// The slot the dragged row currently belongs in, from how many other rows' frozen midpoints now sit above its live position.
    private var targetIndex: Int? {
        guard let draggingID = dragState.draggingID, let originalFrame = dragStartFrames[draggingID] else { return nil }
        let pointerY = originalFrame.midY + dragState.translation

        var index = 0
        for space in spaces where space.id != draggingID {
            guard let frame = dragStartFrames[space.id] else { continue }
            if pointerY > frame.midY { index += 1 }
        }
        return min(index, spaces.count - 1)
    }

    private func offsetY(forSpaceAt index: Int, spaceID: UUID) -> CGFloat {
        guard let draggingID = dragState.draggingID,
              let originalIndex = draggingOriginalIndex,
              let slotSize = dragStartFrames[draggingID].map({ $0.height + rowGap })
        else { return 0 }

        if spaceID == draggingID {
            return dragState.clampedTranslation(originalIndex: originalIndex, count: spaces.count, slotSize: slotSize)
        }
        guard let targetIndex else { return 0 }
        return CoasttyDragReorderState<UUID>.siblingOffset(forIndexAt: index, originalIndex: originalIndex, targetIndex: targetIndex, slotSize: slotSize)
    }

    /// Selects `space` the moment its drag starts, then tracks the live translation.
    private func handleDragChanged(space: CoasttySpaceSummary, translationY: CGFloat) {
        dragState.changed(id: space.id, translation: translationY) {
            dragStartFrames = rowFrames
            onSelectSpace(space.id)
        }
    }

    /// Commits the reorder via `onMoveSpace` if the drag actually moved `space` to a new slot.
    private func handleDragEnded(space: CoasttySpaceSummary) {
        let finalIndex = targetIndex
        defer {
            dragState.reset()
            dragStartFrames = [:]
        }
        guard let originalIndex = spaces.firstIndex(where: { $0.id == space.id }),
              let finalIndex, finalIndex != originalIndex
        else { return }
        onMoveSpace(originalIndex, finalIndex)
    }
}

/// "+ New" control pinned at the bottom of the Spaces section, styled
/// consistently with `CoasttySpaceRow`/`CoasttyAgentRowView`'s existing row
/// conventions (same horizontal/vertical padding, corner radius, and hover
/// background).
///
/// Round 4 (issue #12, coastty repo): the "+" used to sit inside an
/// explicit 16pt-wide frame, while `CoasttySpaceRow`'s own leading icon
/// slot (`CoasttyStatusIconView`, ~7pt) and `CoasttyAgentRowView`'s
/// (`CoasttyStatusIconView` too) both have no such frame at all — that
/// extra frame centered the glyph well past where those rows' icons
/// actually sit, reading as "too much left margin before the +". Dropping
/// it lines this row's icon up with the rows above it. The label's font
/// also used to be 13pt, larger than every other row's own text — sized
/// down to `CoasttyMetrics.titleFontSize`, the same shared constant every
/// other row's primary text now uses.
private struct CoasttyNewSpaceRow: View {
    let palette: CoasttyPalette
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isHovering ? palette.textPrimary : palette.textSecondary)
                Text("New")
                    .font(.system(size: CoasttyMetrics.titleFontSize))
                    .foregroundColor(isHovering ? palette.textPrimary : palette.textSecondary)
            }
            // Stretched to the sidebar's full width, experimentally - was
            // sized to just the icon/text before (see this type's own doc
            // comment above).
            .frame(maxWidth: .infinity, alignment: .leading)
            // Slight breathing room between the icon/text and the
            // capsule's own ring on both sides.
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(
                // Same ring-on-hover treatment as CoasttyCloseButton
                // (icon+text brighten, a faint ring appears) rather than a
                // filled highlight block - kept at this row's own text
                // sizes rather than switching to the close button's fixed
                // ones. Shaped like the Space rows above it rather than
                // like a tab: it sits in that list, so a capsule outline
                // here would be the one differently-shaped row in it.
                CoasttyMetrics.listRowShape
                    .strokeBorder(isHovering ? palette.textSecondary.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            .contentShape(CoasttyMetrics.listRowShape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A window can now hold more than one Space (issue #12, coastty repo,
/// Round 4), so its row needs a real selected-state — reusing the same
/// visual language `CoasttyTabItemView.isActive` already uses for the tab
/// bar's own active tab, rather than inventing a second one.
private struct CoasttySpaceRow: View {
    let space: CoasttySpaceSummary
    let palette: CoasttyPalette
    let isActive: Bool
    let isDragging: Bool
    let onClose: () -> Void
    let onRename: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            CoasttyStatusIconView(status: space.aggregatedStatus, palette: palette)
            Text(space.name)
                .font(.system(size: CoasttyMetrics.titleFontSize))
                .foregroundColor(palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            // Right-aligned, same hover treatment (ring + brighter glyph) as
            // a tab's own close control, swapped for the real configured
            // goto_space shortcut (e.g. "⌃⇧1") when not hovering - mirrors
            // CoasttyTabItemView's own badge/close-button swap exactly (see
            // its `shortcutLabel`). No fixed-width edge zone here, unlike
            // that view - this row's title isn't centered, so there's
            // nothing for one to keep symmetric with.
            HStack {
                if isHovering {
                    CoasttyCloseButton(palette: palette, action: onClose)
                        .coasttyFadeDuringDrag(isDragging)
                } else if let shortcutLabel = space.shortcutLabel {
                    Text(shortcutLabel)
                        .font(.system(size: 10))
                        .foregroundColor(palette.textTertiary)
                }
            }
            // Fixed height, matching CoasttyCloseButton's own diameter -
            // without this, swapping in the taller close button on hover
            // grows the row's HStack (it sizes to its tallest child),
            // nudging every row below it in the list.
            .frame(height: 16, alignment: .center)
        }
        .padding(.leading, 10)
        // Tighter than the leading edge - the trailing zone reads as
        // "more right-aligned, hugging the panel edge" this way, matching
        // the tab bar's own tighter trailing inset around its badge/close
        // zone rather than mirroring the leading side's roomier margin.
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(
            CoasttyMetrics.listRowShape
                .fill(isActive ? palette.backgroundSelected : (isHovering ? palette.backgroundRowHover : Color.clear))
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .coasttyDragToReorder(
            axis: .vertical,
            coordinateSpace: .named(CoasttySpacesSection.coordinateSpaceName),
            onChanged: onDragChanged,
            onEnded: onDragEnded
        )
        .contextMenu {
            Button("Rename...", action: onRename)
            Divider()
            Button("Close", action: onClose)
        }
    }
}

// MARK: - Agents section

/// Two-line rows: `[icon] folder · tab name` with the agent's name
/// indented below.
private struct CoasttyAgentsSection: View {
    let rows: [CoasttyAgentRow]
    let palette: CoasttyPalette
    /// The same `space-row-gap` the Spaces section uses, so both lists
    /// breathe identically rather than the Agents rows sitting flush.
    let rowGap: CGFloat
    /// The configured `goto_urgent_agent` shortcut (e.g. "⌘U"), or nil if unbound.
    let shortcutLabel: String?
    let onSelectAgent: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoasttySectionLabel(text: "Agents", palette: palette, shortcutLabel: shortcutLabel)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: rowGap) {
                    ForEach(rows) { row in
                        CoasttyAgentRowView(row: row, palette: palette, onSelect: onSelectAgent)
                    }
                }
            }
        }
    }
}

private struct CoasttyAgentRowView: View {
    let row: CoasttyAgentRow
    let palette: CoasttyPalette
    let onSelect: (UUID) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                CoasttyStatusIconView(status: row.tab.status, palette: palette, context: .agents)
                // Matches the row directly above it in the Spaces section,
                // including a user-set rename.
                Text(row.spaceName)
                    .font(.system(size: CoasttyMetrics.titleFontSize))
                    .foregroundColor(palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\u{2022}")
                    .font(.system(size: 11))
                    .foregroundColor(palette.textTertiary)
                Text(row.tab.tabName)
                    .font(.system(size: CoasttyMetrics.titleFontSize))
                    .foregroundColor(palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let agentName = row.tab.agentName {
                Text(agentName)
                    .font(.system(size: 11))
                    .foregroundColor(palette.textTertiary)
                    .padding(.leading, 15)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 7)
        // Stretched before the background is applied, so the highlight
        // spans the full row the way `CoasttySpaceRow`'s does (that one
        // gets there via its trailing `Spacer`, which this two-line layout
        // has no place for).
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            CoasttyMetrics.listRowShape
                .fill(rowBackground)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onSelect(row.id) }
    }

    /// The active pane's row stays highlighted regardless of hover, so the
    /// agent you are looking at is identifiable among several - herdr marks
    /// the same row with its own `active_row_bg` (`src/ui/sidebar.rs`).
    private var rowBackground: Color {
        if row.tab.isActive { return palette.backgroundSelected }
        return isHovering ? palette.backgroundRowHover : Color.clear
    }
}

// MARK: - Shared row furniture

private struct CoasttySectionLabel: View {
    let text: String
    let palette: CoasttyPalette
    /// Shortcut hint flush to the trailing edge - nil for sections without one, like "Spaces".
    var shortcutLabel: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundColor(palette.textTertiary)
            if let shortcutLabel {
                Spacer(minLength: 0)
                Text(shortcutLabel)
                    .font(.system(size: 10))
                    .foregroundColor(palette.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Draggable gap between panels

/// Resizes the split between the "Spaces" and "Agents" panels below. Its
/// ratio is read from and written back to a `CoasttySidebarSplitRatioStore`
/// so it persists across launches.
///
/// design/sidebar-rounded-sections (issue #12, coastty repo): previously
/// drew a visible line here (the divider "between Spaces and Agents"
/// itself, distinct from the panels' own dividers) — now that Spaces and
/// Agents are two independently-rounded floating cards with a real margin
/// between them, that line read as a stray extra border rather than
/// anything meaningful. The gap itself is now the drag target; nothing is
/// drawn in it.
private struct CoasttySidebarDragHandle: View {
    let totalHeight: CGFloat
    @ObservedObject var ratioStore: CoasttySidebarSplitRatioStore

    @State private var isDragging = false
    @State private var dragStartRatio: CGFloat?

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let startRatio = dragStartRatio ?? ratioStore.agentsRatio
                        if dragStartRatio == nil {
                            dragStartRatio = startRatio
                            isDragging = true
                        }
                        guard totalHeight > 0 else { return }
                        // Dragging the divider down grows "Spaces" and
                        // shrinks "Agents", so a positive vertical
                        // translation subtracts from the Agents ratio.
                        let delta = -(value.translation.height) / totalHeight
                        ratioStore.updateRatio(startRatio + delta)
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragStartRatio = nil
                        ratioStore.persist()
                    }
            )
    }
}
