import AppKit

enum Clipboard {
    static func copy(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(trimmedText, forType: .string)
    }
}
