import Cocoa
import SwiftUI

/// The window About opens to show the licence texts the app ships with.
class LicensesController: NSWindowController {
    static let shared = LicensesController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Licenses"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LicensesView())
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("LicensesController is built in code, never from a nib")
    }

    /// Brings the window to the front, reopening it if it was closed.
    func show() {
        window?.makeKeyAndOrderFront(nil)
    }
}
