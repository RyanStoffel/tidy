import AppKit
import SwiftUI

/// Shared setup for Tidy's windows. No colors or appearance overrides: they use the
/// standard window material and follow the system appearance like any native app.
enum WindowFactory {
    static func make<Content: View>(title: String, size: NSSize, minSize: NSSize, content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentMinSize = minSize
        window.contentView = NSHostingView(rootView: content)
        window.center()
        return window
    }
}
