import Foundation
import WhisperKit

/// 無音ハルシネーション（実際には話していない定型句）の除去フィルタ。
///
/// large-v3 系は学習データ（日本語 YouTube 字幕）由来で締めの定型句の prior が極端に高く、
/// 無音・余韻区間で **高確信度のまま**これらを出力する。よって確信度（noSpeechProb/avgLogprob）
/// ゲートでは弾けないため、文字列ベースで除去する。
/// 音声パイプラインのタイミングには一切影響しない純粋関数。
enum HallucinationFilter {
    /// 実際の口述ではまず出ない定型句。セグメント中に**含まれていれば無条件除去**
    /// （部分一致なので連結・反復・前後に他語が付いても捕捉する）。
    static let alwaysDropSubstrings: [String] = [
        "ご視聴ありがとう",
        "ご清聴ありがとう",
        "ご視聴いただき",
        "最後までご視聴",
        "チャンネル登録",
        "高評価",
    ]

    /// 実発話ともなりうる定型句。セグメント**全体がこれ（の繰り返し）だけ**で構成される
    /// standalone の場合のみ幻聴とみなして除去する。文中に紛れている場合は残す。
    static let standaloneDropPhrases: [String] = [
        "ありがとうございました",
        "ありがとうございます",
    ]

    static func filter(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        segments.filter { !isHallucination($0) }
    }

    static func isHallucination(_ segment: TranscriptionSegment) -> Bool {
        let normalized = normalize(segment.text)
        guard !normalized.isEmpty else { return false }

        // (1) 動画アウトロ系: 部分一致で無条件除去。
        if alwaysDropSubstrings.contains(where: { normalized.contains($0) }) {
            return true
        }

        // (2) ありがとう系: セグメントが定型句の繰り返しのみで構成されるなら除去。
        //     文中に紛れている（除去後に他語が残る）場合は残す。
        var residual = normalized
        for phrase in standaloneDropPhrases where !phrase.isEmpty {
            residual = residual.replacingOccurrences(of: phrase, with: "")
        }
        return residual.isEmpty
    }

    /// 前後・内部の空白、句読点、記号を除去した比較用文字列を返す。
    static func normalize(_ text: String) -> String {
        let filteredScalars = text.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
            !CharacterSet.punctuationCharacters.contains(scalar) &&
            !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(filteredScalars))
    }
}
