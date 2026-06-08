# ストリーミング文字起こし: 窓を縮めても無損失に保つ（継ぎ目問題）

## 背景 / 問題
リアルタイム文字起こしの遅延は、`decode` 時間が支配的で、しかも **再デコードするスパン
（窓長 − 確定済み先頭）に比例**する。連続発話で確定が遅れると窓が肥大（実測 11s）し
`decode` が 1873ms まで膨らんで追従が悪化した（体感の遅さの主因）。

窓を小さく保つには「テキストを確定して凍結 → そこから先だけ再デコード」が必要。しかし
**Whisper のセグメント境界（タイムスタンプ）は不正確**で、不安定な境界で確定すると
次デコードの開始位置がズレ、**継ぎ目で単語が落ちる（テキスト消失）**。これはストリーミング
ASR で有名な「継ぎ目問題」。

## やってはいけなかったこと（リグレッション履歴）
1. **生の時間位置でのカット + 未確定テキストの force-commit**（T-025 第1〜2版）。
   セグメント途中で音声を切り、テキストを確定しきれず、連続発話で発話が丸ごと欠落。
   さらに `lastConfirmedSegmentEndSeconds = 0` リセットでバッファ座標が desync し
   `audioIn=40.4s` の異常値も発生。→ `avoid-mutating-audio-pipeline-timing.md` の領域。
2. **最後の不安定セグメントまで確定**（T-025 第3版）。継ぎ目で単語が「一部」落ちた。
3. **char 単位の de-dup**（重複文字の突き合わせ）は日本語（スペース無し・表記揺れ）で不安定。不採用。

## 効いた設計（無損失スライド）
窓が `maxWindowSeconds` を超えたら、先頭の未確定セグメントを確定へ昇格させて確定境界を
進め、既存の「確定境界スライド（overlap を左文脈に残し overlap から再デコード）」で縮める。
**鍵は『後続セグメントが残る安定境界だけ確定する』こと**:

```swift
// 最後の1セグメントは必ず未確定で残す（count > 1）。後続ありの境界だけ確定するので
// 継ぎ目の単語落ちが原理的に起きない（元の自然確定 requiredSegmentsForConfirmation=1 と同じ無損失原理）。
while lastConfirmedSegmentEndSeconds < needConfirmEnd, unconfirmedSegments.count > 1 {
    let first = unconfirmedSegments.removeFirst()
    if !confirmedSegments.contains(first) { confirmedSegments.append(first) }
    lastConfirmedSegmentEndSeconds = first.end
}
```

実装: `StreamingTranscriber.slideWindowIfNeeded`。

## 重要な洞察
- **decode コストは「窓のサイズ」ではなく「未確定スパン」で決まる**。確定さえ進めば、窓が
  多少大きくても decode は軽い（実測: 窓 中央 8s でも pipeline 中央 818ms）。だから窓を
  無理に詰める必要はなく、**確定を安定して進めること**が本質。
- **継ぎ目の無損失は『後続文脈のある境界だけ確定』で担保**。これは元コードが消えなかった理由
  そのもの。force-confirm でもこの原理を必ず守る。
- 極端な単一巨大セグメント（息継ぎゼロ）では確定が進まず窓が育つ＝一時的に遅いが**無損失**。許容。

## 計測のコツ
- `[STT/timings]` ログは `print()`＝stdout。**ターミナルから直接起動**しないと見えない
  （`open`/ダブルクリック/Console.app では出ない）。
- バッファ問題（`| tee` はブロックバッファ）を避けるため PTY 経由で:
  `rm -f /tmp/stt.log && script -q /tmp/stt.log <app binary>`（script は追記なので毎回 rm）。
- 切り分けの肝: `encode` は窓長非依存の ~280ms 固定（30s パディング）→ GPU 併用は無意味。
  支配項は `decode`。`confirmedEnd`/`slid` ログで確定の進みとスライド発火を可視化。
