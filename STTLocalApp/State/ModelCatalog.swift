import Foundation

struct ModelCatalogEntry: Identifiable, Equatable {
    let id: String
    let displayName: String
    let sizeLabel: String

    var menuTitle: String {
        "\(displayName)（\(sizeLabel)）"
    }
}

enum ModelCatalog {
    static let highAccuracy = ModelCatalogEntry(
        id: "openai_whisper-large-v3_turbo",
        displayName: "高精度",
        sizeLabel: "約3GB"
    )

    static let standardRecommended = ModelCatalogEntry(
        id: "openai_whisper-large-v3_turbo_954MB",
        displayName: "標準(推奨)",
        sizeLabel: "約954MB"
    )

    static let lightweight = ModelCatalogEntry(
        id: "openai_whisper-small_216MB",
        displayName: "軽量",
        sizeLabel: "約216MB"
    )

    static let all: [ModelCatalogEntry] = [
        highAccuracy,
        standardRecommended,
        lightweight,
    ]
}
