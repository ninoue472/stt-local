import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.r, modifiers: [.command, .shift]))
    static let togglePanel = Self("togglePanel", default: .init(.p, modifiers: [.command, .shift]))
}
