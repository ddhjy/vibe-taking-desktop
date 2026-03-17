import Cocoa

enum StatusBarIcon {
    static func make(autoSend: Bool, running: Bool, inputActive: Bool = false) -> NSImage {
        let symbolName: String
        if inputActive {
            symbolName = "text.cursor"
        } else if autoSend {
            symbolName = "doc.on.clipboard.fill"
        } else {
            symbolName = "doc.on.clipboard"
        }

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "随心记")?
            .withSymbolConfiguration(config) else {
            return NSImage()
        }
        image.isTemplate = true
        return image
    }
}
