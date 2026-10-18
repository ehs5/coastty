import Cocoa
import SwiftUI

/// The window About opens to show the licence texts the app ships with.
class LicensesController: NSWindowController {
    static let shared = LicensesController()

    /// Builds the window in code; it stays alive when closed so `show()` can bring it back.
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

    /// Unused: the window is never loaded from a nib.
    required init?(coder: NSCoder) {
        fatalError("LicensesController is built in code, never from a nib")
    }

    /// Brings the window to the front, reopening it if it was closed.
    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closes the window for the Close menu item and its ⌘W, as About does.
    @IBAction func close(_ sender: Any) {
        window?.performClose(sender)
    }

    /// Closes the window for the Close Window menu item, as About does.
    @IBAction func closeWindow(_ sender: Any) {
        window?.performClose(sender)
    }

    /// Closes the window when Escape is pressed, as About does.
    @objc func cancel(_ sender: Any?) {
        close()
    }
}
