import AppKit
import GhosttyKit

/// Building windows from the two halves of a session: what exists, which the daemon owns, and what a window makes of it, which is the GUI's own.
///
/// Produces the same `UndoState` the window construction path already takes, so nothing about how a window is built changes here - only where its contents come from.
enum CoasttySessionRestore {
    /// One window's worth of state, ready for `TerminalController(_:with:)`.
    static func windows(
        spaces modelSpaces: [CoasttyHostModel.Space],
        layouts: [CoasttyWindowLayout],
        app: ghostty_app_t
    ) -> [TerminalController.UndoState] {
        var remaining = modelSpaces
        var states: [TerminalController.UndoState] = []

        for layout in layouts {
            var spaces: [CoasttySpace] = []
            for wanted in layout.spaces {
                guard let index = remaining.firstIndex(where: { $0.id == wanted.spaceID }) else { continue }
                let modelSpace = remaining.remove(at: index)
                spaces.append(space(modelSpace, layout: wanted, app: app))
            }

            // A window that ends up showing nothing is not worth restoring - its
            // Spaces are gone from the model, so there is no window left to rebuild.
            guard !spaces.isEmpty else { continue }
            states.append(.init(
                windowID: layout.windowID.flatMap(UUID.init(uuidString:)),
                frame: layout.frame,
                spaces: spaces,
                activeSpaceIndex: min(max(layout.activeSpaceIndex, 0), spaces.count - 1),
                tabColor: layout.tabColor))
        }

        // Spaces the model holds that no window claimed - created from another
        // client, or left behind when a window's layout was lost. They exist, so
        // they have to be reachable somewhere.
        guard !remaining.isEmpty else { return states }
        let orphans = remaining.map { space($0, layout: nil, app: app) }

        guard let first = states.first else {
            return [.init(windowID: nil, frame: .zero, spaces: orphans, activeSpaceIndex: 0, tabColor: .none)]
        }
        states[0] = .init(
            windowID: first.windowID,
            frame: first.frame,
            spaces: first.spaces + orphans,
            activeSpaceIndex: first.activeSpaceIndex,
            tabColor: first.tabColor)
        return states
    }

    /// `model` with everything holding nothing dropped, and the operations that end those in the daemon too.
    ///
    /// A pane outlives a quit - that is the point of the daemon - so a tab with none never came from one. It is what a leak, or a window that took its panes with it, leaves behind. Rebuilding it with a fresh shell would make the leftover permanent and give the user something they cannot tell from a Space they made.
    static func pruningEmpties(
        _ model: CoasttyHostModel
    ) -> (spaces: [CoasttyHostModel.Space], operations: [CoasttyModelSync.Operation]) {
        var kept: [CoasttyHostModel.Space] = []
        var operations: [CoasttyModelSync.Operation] = []

        for space in model.spaces {
            let live = space.tabs.filter { !$0.panes.isEmpty }
            guard !live.isEmpty else {
                // The whole Space goes, which takes its tabs with it.
                if let id = UUID(uuidString: space.id) { operations.append(.spaceClose(id: id)) }
                continue
            }

            for tab in space.tabs where tab.panes.isEmpty {
                if let id = UUID(uuidString: tab.id) { operations.append(.tabClose(id: id)) }
            }

            guard live.count != space.tabs.count else {
                kept.append(space)
                continue
            }
            kept.append(.init(
                id: space.id,
                name: space.name,
                defaultName: space.defaultName,
                hidden: space.hidden,
                restoreIndex: space.restoreIndex,
                tabs: live))
        }
        return (kept, operations)
    }

    private static func space(
        _ modelSpace: CoasttyHostModel.Space,
        layout: CoasttyWindowLayout.Space?,
        app: ghostty_app_t
    ) -> CoasttySpace {
        var tabs: [CoasttyTab] = []
        for modelTab in modelSpace.tabs {
            tabs.append(tab(modelTab, layout: layout?.tabs.first { $0.tabID == modelTab.id }, app: app))
        }

        // Only reachable for a Space the prune kept, so this is a tab whose
        // panes were lost rather than a Space that never had any.
        if tabs.isEmpty {
            tabs.append(.init(tree: .init(view: Ghostty.SurfaceView(app)), focusedSurfaceID: nil))
        }

        var space = CoasttySpace(
            id: UUID(uuidString: modelSpace.id) ?? UUID(),
            tabs: tabs,
            activeTabIndex: min(max(layout?.activeTabIndex ?? 0, 0), tabs.count - 1),
            nameOverride: modelSpace.name.isEmpty ? nil : modelSpace.name,
            initialFolderName: modelSpace.defaultName)
        space.activeTabIndex = min(max(layout?.activeTabIndex ?? 0, 0), tabs.count - 1)
        return space
    }

    private static func tab(
        _ modelTab: CoasttyHostModel.Tab,
        layout: CoasttyWindowLayout.Tab?,
        app: ghostty_app_t
    ) -> CoasttyTab {
        var panes: [Ghostty.SurfaceView] = []
        for modelPane in modelTab.panes {
            guard let view = surface(modelPane, app: app) else { continue }
            panes.append(view)
        }

        // Every tab shows something, even one whose panes the model lost.
        if panes.isEmpty { panes.append(Ghostty.SurfaceView(app)) }

        let tree = CoasttyLayoutShape.tree(panes: panes, shape: layout?.shape)
        let focused = layout?.focusedPaneID.flatMap { id in panes.first { $0.id.uuidString == paneUUID(id) } }

        var tab = CoasttyTab(
            id: UUID(uuidString: modelTab.id) ?? UUID(),
            tree: tree,
            focusedSurfaceID: focused?.id ?? panes.first?.id)
        tab.titleOverride = modelTab.name.isEmpty ? nil : modelTab.name
        return tab
    }

    /// Recreates the surface for one pane the daemon holds. Its id is what
    /// reattaches it to the live process; its directory is where a fresh shell
    /// starts if that process is gone.
    private static func surface(_ pane: CoasttyHostModel.Pane, app: ghostty_app_t) -> Ghostty.SurfaceView? {
        guard let uuid = UUID(uuidString: paneUUID(pane.id)) else { return nil }

        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = pane.directory.isEmpty ? nil : pane.directory

        // The title is the live process's, and arrives again as soon as this
        // surface attaches - there is nothing to seed here.
        return Ghostty.SurfaceView(app, baseConfig: config, uuid: uuid)
    }

    /// The daemon names a pane `surface:<uuid>`; the GUI knows it by the uuid alone.
    private static func paneUUID(_ id: String) -> String {
        guard let range = id.range(of: "surface:") else { return id }
        return String(id[range.upperBound...])
    }
}
