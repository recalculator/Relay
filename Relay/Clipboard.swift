#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Puts plain text on the system clipboard. The text is never logged.
enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
