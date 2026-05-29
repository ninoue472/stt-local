import Foundation
import WhisperKit

enum DecodingPresets {
    static func japanese(noSpeechThreshold: Float) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "ja",
            temperature: 0.0,
            // リアルタイム性優先: 低確信度時の再デコード（リトライ）を行わない。
            // ストリーミングでは次ループで文脈が増えて再評価されるため、1回で十分。
            temperatureFallbackCount: 0,
            sampleLength: 224,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: noSpeechThreshold
        )
    }
}
