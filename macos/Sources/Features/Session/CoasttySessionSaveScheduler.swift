import Foundation

/// Debounces and backgrounds session-snapshot writes, modelled on herdr's
/// `src/app/session.rs`: dirty only on structural changes, 5s debounce,
/// write off the main thread.
final class CoasttySessionSaveScheduler {
    static let shared = CoasttySessionSaveScheduler()

    private static let debounceInterval: TimeInterval = 5

    private let queue = DispatchQueue(label: "cc.coastty.session-save", qos: .utility)
    private var pendingWorkItem: DispatchWorkItem?

    private init() {}

    /// Call after any structural tab/Space/split change.
    func markDirty() {
        pendingWorkItem?.cancel()

        let layoutData = captureLayoutData()
        guard let data = captureSnapshotData() else { return }
        let workItem = DispatchWorkItem {
            CoasttySessionPersistence.save(data)
            if let layoutData { CoasttySessionPersistence.saveLayouts(layoutData) }
        }
        pendingWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: workItem)
    }

    /// Writes and waits for it to land - used on app termination so an
    /// in-flight debounced write can't be lost.
    func flushNow() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil

        let layoutData = captureLayoutData()
        guard let data = captureSnapshotData() else {
            if let layoutData { queue.sync { CoasttySessionPersistence.saveLayouts(layoutData) } }
            return
        }
        queue.sync {
            CoasttySessionPersistence.save(data)
            if let layoutData { CoasttySessionPersistence.saveLayouts(layoutData) }
        }
    }

    /// What each window makes of the model - its own half of a session. Same main-thread rule as `captureSnapshotData`.
    private func captureLayoutData() -> Data? {
        precondition(Thread.isMainThread, "layout capture reads live main-thread window state")

        let layouts = TerminalController.all
            .filter { $0.coasttySessionPersistable }
            .compactMap { $0.coasttyWindowLayout }
        return CoasttySessionPersistence.encodeLayouts(layouts)
    }

    /// Must run on the main thread - reads live window state and encodes it here, so only `Data` ever crosses onto `queue`.
    private func captureSnapshotData() -> Data? {
        precondition(Thread.isMainThread, "session capture reads live main-thread window state")

        let windows = TerminalController.all
            .filter { $0.coasttySessionPersistable }
            .compactMap { $0.undoState }
        let snapshot = CoasttySessionSnapshot(windows: windows)
        return CoasttySessionPersistence.encode(snapshot)
    }
}
