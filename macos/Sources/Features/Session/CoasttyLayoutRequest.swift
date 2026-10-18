import Foundation

/// A change a layout command asks the app to make, as the daemon hands it over in a `request` event (see `REQUEST` in `host/wire.zig`).
///
/// The daemon has already resolved and validated it, so the app carries it out as given without asking again.
enum CoasttyLayoutRequest: Equatable {
    case newSpace(NewSpace)
    case closeSpace(id: UUID)
    case renameSpace(id: UUID, name: String)
    case moveSpace(MoveSpace)
    case focusSpace(id: UUID)
    case newTab(NewTab)
    case closeTab(id: UUID)
    case renameTab(id: UUID, name: String)
    case moveTab(id: UUID, index: Int)
    case focusTab(id: UUID)
    case splitPane(SplitPane)
    case closePane(id: String)
    case focusPane(id: String)

    /// A new Space with one starter tab, joining the window `windowID` names, else the one that shows `besideSpaceID`, else the frontmost one.
    struct NewSpace: Equatable {
        let spaceID: UUID
        let tabID: UUID
        let windowID: UUID?
        let besideSpaceID: UUID?
        let name: String
        let directory: String
        let focus: Bool
    }

    /// A Space moving to `index` among the visible Spaces, landing after the ones in `after`; with `windowID`, it moves to that window and `after` names only that window's Spaces.
    struct MoveSpace: Equatable {
        let id: UUID
        let index: Int
        let after: [UUID]
        let windowID: UUID?
    }

    /// A new tab at the end of a Space, starting the user's shell in `directory`.
    struct NewTab: Equatable {
        let spaceID: UUID
        let tabID: UUID
        let name: String
        let directory: String
        let focus: Bool
    }

    /// A new pane split off the pane with daemon id `paneID`, starting the user's shell in `directory`.
    struct SplitPane: Equatable {
        enum Direction: String {
            case right
            case down
        }

        let paneID: String
        /// The id the new surface takes, which is what the daemon knows its pane by.
        let surfaceID: UUID
        let direction: Direction
        let directory: String
        let focus: Bool
    }

    /// The request a `request` event carries, or nil for one this build does not know or that names ids it cannot read.
    static func decode(_ json: Data) -> CoasttyLayoutRequest? {
        // Malformed JSON can't be acted on; the command times out and says it couldn't verify.
        guard let event = try? JSONDecoder().decode(Event.self, from: json) else { return nil }
        // Only request events ask the app for anything.
        guard event.event == "request" else { return nil }

        // Every request names the Space or tab it creates or acts on.
        let spaceID = event.space.flatMap(UUID.init(uuidString:))
        let tabID = event.tab.flatMap(UUID.init(uuidString:))

        switch (event.scope, event.op) {
        case ("space", "new"):
            // The daemon always sends these; one missing or unreadable means a request this build can't trust.
            guard let spaceID, let tabID, let directory = event.directory else { return nil }
            return .newSpace(.init(
                spaceID: spaceID,
                tabID: tabID,
                windowID: event.window.flatMap(UUID.init(uuidString:)),
                besideSpaceID: event.beside.flatMap(UUID.init(uuidString:)),
                name: event.name ?? "",
                directory: directory,
                focus: event.focus ?? false))
        case ("space", "close"):
            guard let spaceID else { return nil }
            return .closeSpace(id: spaceID)
        case ("space", "rename"):
            guard let spaceID, let name = event.name else { return nil }
            return .renameSpace(id: spaceID, name: name)
        // Only a move's anchors may be unreadable: one that isn't a UUID names no Space a window could hold.
        case ("space", "move"):
            guard let spaceID, let index = event.index, let after = event.after else { return nil }
            // A window named but unreadable can't be moved to; staying put would leave the command waiting on nothing.
            let windowID = event.window.flatMap(UUID.init(uuidString:))
            if let window = event.window, !window.isEmpty, windowID == nil { return nil }
            return .moveSpace(.init(
                id: spaceID,
                index: index,
                after: after.compactMap(UUID.init(uuidString:)),
                windowID: windowID))
        case ("space", "focus"):
            guard let spaceID else { return nil }
            return .focusSpace(id: spaceID)
        case ("tab", "new"):
            // The daemon always sends these; one missing or unreadable means a request this build can't trust.
            guard let spaceID, let tabID, let directory = event.directory else { return nil }
            return .newTab(.init(
                spaceID: spaceID,
                tabID: tabID,
                name: event.name ?? "",
                directory: directory,
                focus: event.focus ?? false))
        // As for a new tab, a field the daemon always sends being absent means a request this build can't trust.
        case ("tab", "close"):
            guard let tabID else { return nil }
            return .closeTab(id: tabID)
        case ("tab", "rename"):
            guard let tabID, let name = event.name else { return nil }
            return .renameTab(id: tabID, name: name)
        case ("tab", "move"):
            guard let tabID, let index = event.index else { return nil }
            return .moveTab(id: tabID, index: index)
        case ("tab", "focus"):
            guard let tabID else { return nil }
            return .focusTab(id: tabID)
        // Panes are named by the daemon's own id, which is not always a UUID.
        case ("pane", "split"):
            guard let paneID = event.pane,
                  let surfaceID = event.surface.flatMap(UUID.init(uuidString:)),
                  let direction = event.direction.flatMap(SplitPane.Direction.init(rawValue:)),
                  let directory = event.directory else { return nil }
            return .splitPane(.init(
                paneID: paneID,
                surfaceID: surfaceID,
                direction: direction,
                directory: directory,
                focus: event.focus ?? false))
        case ("pane", "close"):
            guard let paneID = event.pane else { return nil }
            return .closePane(id: paneID)
        case ("pane", "focus"):
            guard let paneID = event.pane else { return nil }
            return .focusPane(id: paneID)
        default:
            return nil
        }
    }

    /// Every field any request can carry; which ones are present depends on the scope and op.
    private struct Event: Decodable {
        let event: String
        let scope: String
        let op: String
        let space: String?
        let beside: String?
        let window: String?
        let tab: String?
        let pane: String?
        let surface: String?
        let direction: String?
        let name: String?
        let directory: String?
        let focus: Bool?
        let index: Int?
        let after: [String]?
    }
}
