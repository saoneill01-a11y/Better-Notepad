import AppKit
import SwiftUI

/// App colours for light and dark mode, modelled on Windows 11 Notepad: the tab bar and status
/// bar share a "chrome" colour, and the selected tab uses the editor colour so it joins the page.
enum Theme {
    private static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    /// Tab bar, find bar and status bar.
    static let chrome = dynamic("BNChrome", light: rgb(0xF0F0F0), dark: rgb(0x1C1C1C))
    /// Editor page and the selected tab.
    static let editorBackground = dynamic("BNEditor", light: rgb(0xFFFFFF), dark: rgb(0x2B2B2B))
    /// Hairline between the chrome and the page.
    static let border = dynamic("BNBorder", light: rgb(0x000000, alpha: 0.12), dark: rgb(0x000000, alpha: 0.55))
    /// Hovered, unselected tab.
    static let tabHover = dynamic("BNTabHover", light: rgb(0x000000, alpha: 0.05), dark: rgb(0xFFFFFF, alpha: 0.06))
    /// Line numbers.
    static let gutterText = dynamic("BNGutterText", light: rgb(0x000000, alpha: 0.35), dark: rgb(0xFFFFFF, alpha: 0.32))

    /// Faded Markdown symbols (#, **, -, >, link URLs).
    static let markdownMarker = dynamic("BNMarkdownMarker", light: rgb(0x000000, alpha: 0.32), dark: rgb(0xFFFFFF, alpha: 0.32))
    /// List bullets, numbers and checkboxes.
    static let markdownAccent = dynamic("BNMarkdownAccent", light: rgb(0x2F6FD6), dark: rgb(0x6EA8FF))
    /// Background behind inline code and code blocks.
    static let codeBackground = dynamic("BNCodeBackground", light: rgb(0x000000, alpha: 0.05), dark: rgb(0xFFFFFF, alpha: 0.07))

    static var chromeColor: Color { Color(nsColor: chrome) }
    static var editorColor: Color { Color(nsColor: editorBackground) }
    static var borderColor: Color { Color(nsColor: border) }
    static var tabHoverColor: Color { Color(nsColor: tabHover) }
}
