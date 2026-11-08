import AppKit

enum AppWindowStyle {
    // Keep SwiftUI's titlebar safe area aligned with AppKit's content view.
    // Without fullSizeContentView, MapReader counts the titlebar offset again
    // when converting actual map clicks in an NSHostingView.
    static let main: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
}
