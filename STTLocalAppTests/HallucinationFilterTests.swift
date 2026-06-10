import AppKit
import XCTest
import WhisperKit
@testable import STTLocalApp

final class HallucinationFilterTests: XCTestCase {
    // MARK: - 動画アウトロ系（部分一致で無条件除去）

    func testRemovesOutroSubstringRegardlessOfConfidence() {
        // 高確信度（実発話相当の信号）でも、アウトロ定型句は除去される。
        let segment = makeSegment(text: "ご視聴ありがとうございました", noSpeechProb: 0.01, avgLogprob: -0.1)
        XCTAssertEqual(HallucinationFilter.filter([segment]), [])
    }

    func testRemovesOutroEvenWhenEmbeddedInLargerText() {
        // 前後に他語が付いても部分一致で除去。
        let segment = makeSegment(text: "それでは最後までご視聴いただきありがとうございました", noSpeechProb: 0.01, avgLogprob: -0.1)
        XCTAssertEqual(HallucinationFilter.filter([segment]), [])
    }

    func testRemovesChannelRegistration() {
        let segment = makeSegment(text: "チャンネル登録お願いします", noSpeechProb: 0.01, avgLogprob: -0.1)
        XCTAssertEqual(HallucinationFilter.filter([segment]), [])
    }

    // MARK: - ありがとう系（standalone のみ除去）

    func testRemovesStandaloneThanksRegardlessOfConfidence() {
        // 高確信度でも、セグメント全体が「ありがとうございます」だけなら除去。
        let segment = makeSegment(text: "ありがとうございます。", noSpeechProb: 0.01, avgLogprob: -0.1)
        XCTAssertEqual(HallucinationFilter.filter([segment]), [])
    }

    func testRemovesRepeatedStandaloneThanks() {
        // 反復（連結）も除去。
        let segment = makeSegment(text: "ありがとうございましたありがとうございました", noSpeechProb: 0.5, avgLogprob: -0.9)
        XCTAssertEqual(HallucinationFilter.filter([segment]), [])
    }

    func testKeepsThanksWhenEmbeddedInRealSentence() {
        // 文中に紛れた「ありがとうございました」は実発話として残す。
        let segment = makeSegment(text: "本日はお集まりいただきありがとうございました、では始めます", noSpeechProb: 0.01, avgLogprob: -0.1)
        XCTAssertEqual(HallucinationFilter.filter([segment]), [segment])
    }

    // MARK: - 通常発話は常に残す

    func testKeepsNonBlockedPhrase() {
        let segment = makeSegment(text: "通常の発話です", noSpeechProb: 0.99, avgLogprob: -1.5)
        XCTAssertEqual(HallucinationFilter.filter([segment]), [segment])
    }

    // MARK: - normalize

    func testNormalizeRemovesWhitespaceAndPunctuation() {
        XCTAssertEqual(
            HallucinationFilter.normalize("ご視聴ありがとうございました。"),
            "ご視聴ありがとうございました"
        )
        XCTAssertEqual(
            HallucinationFilter.normalize(" ありがとうございます "),
            "ありがとうございます"
        )
    }

    @MainActor
    func testCurrentTextConcatenatesConfirmedAndUnconfirmedText() {
        let appState = AppState()
        appState.confirmedText = "確定 "
        appState.unconfirmedText = "未確定"

        XCTAssertEqual(appState.currentText, "確定 未確定")
    }

    @MainActor
    func testCopyableTextMatchesTrimmedCurrentTextWhileRecording() {
        let appState = AppState()
        appState.phase = .recording
        appState.confirmedText = " 先頭 "
        appState.unconfirmedText = "末尾 \n"

        XCTAssertEqual(appState.currentText, " 先頭 末尾 \n")
        XCTAssertEqual(appState.copyableText, "先頭 末尾")
    }

    @MainActor
    func testHandleFinalTextSkipsCopyToastAndOverwriteForTrimmedEmptyText() {
        let appDelegate = AppDelegate()
        appDelegate.appState.lastFinalText = "前回の結果"
        var copiedTexts: [String] = []
        appDelegate.clipboardCopy = { copiedTexts.append($0) }

        appDelegate.handleFinalText(" \n ")

        XCTAssertTrue(copiedTexts.isEmpty)
        XCTAssertEqual(appDelegate.appState.lastFinalText, "前回の結果")
        XCTAssertFalse(appDelegate.appState.justCopied)
    }

    @MainActor
    func testHandleFinalTextCopiesAndShowsToastForNonEmptyText() {
        let appDelegate = AppDelegate()
        var copiedText: String?
        appDelegate.clipboardCopy = { copiedText = $0 }

        appDelegate.handleFinalText("  確定テキスト \n")

        XCTAssertEqual(copiedText, "確定テキスト")
        XCTAssertEqual(appDelegate.appState.lastFinalText, "確定テキスト")
        XCTAssertTrue(appDelegate.appState.justCopied)
    }

    func testClipboardCopyPreservesExistingContentsForTrimmedEmptyText() {
        let pasteboard = NSPasteboard.general
        let originalValue = pasteboard.string(forType: .string)
        let sentinel = "clipboard-sentinel-\(UUID().uuidString)"

        defer {
            pasteboard.clearContents()
            if let originalValue {
                pasteboard.setString(originalValue, forType: .string)
            }
        }

        Clipboard.copy(sentinel)
        XCTAssertEqual(pasteboard.string(forType: .string), sentinel)

        Clipboard.copy(" \n ")
        XCTAssertEqual(pasteboard.string(forType: .string), sentinel)
    }

    // MARK: - Helpers

    private func makeSegment(
        text: String,
        noSpeechProb: Float,
        avgLogprob: Float
    ) -> TranscriptionSegment {
        TranscriptionSegment(
            text: text,
            avgLogprob: avgLogprob,
            noSpeechProb: noSpeechProb
        )
    }
}
