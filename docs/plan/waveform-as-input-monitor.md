# 設計: 波形は「入力モニタ」として文字起こしから分離する

## 原則
波形アニメーションと文字起こしは**目的が別**:
- 波形 = **入力モニタ**。マイクが声を拾えているかをユーザーがリアルタイムに確認するためのもの。
  「波形は動くのに文字が出ない＝推論側の問題」「波形も動かない＝マイク/入力の問題」という
  切り分けを可能にし、ユーザーが確信を持って喋れるようにする UX 機能。
- 文字起こし = **推論**。重く間欠的。波形をこれに同期させる必然性は無い。

→ 波形はマイク入力（エネルギー）から**独立した周期**で駆動する。transcribe ループに依存させない。

## 技術的背景（確認済み）
- `WhisperKit.transcribe(...)` は内部で `await`（taskGroup・async モデル推論）を持ち、
  協調プール上で実行される。呼び出し元の `@MainActor` は transcribe 中も原則フリー。
  → 独立した MainActor タイマーから UI（`appState.bufferEnergy`）を更新すれば、推論中も描画できる。
- `AudioProcessor` は録音タップ（real-time audio thread）で毎バッファ `relativeEnergy` を更新している。
  これを 30fps 程度で読んで反映すればよい。
- 過去 T-004 で別タスク化しても動かなかったのは、当時 VAD/pruneSilence のバッファ肥大化で
  推論が極端に重く UI が CPU 的に枯渇していたため（タスク分離自体は正しい方針だった）。
  T-005 でパイプラインを戻し推論が軽くなったので、独立波形タスクが本来の意図どおり機能する。

## 実装（T-006, `StreamingTranscriber.swift` のみ）
- `realtimeLoop` 内の `updateEnergy(pipe)` 呼び出しを削除（文字起こしループから波形を外す）。
- 独立した `energyTask`（約 33ms = 30fps）を `start()` で起動し、`updateEnergy` を回す。
- `stop()` / エラー / キャンセル時に `energyTask` を確実に停止。
- クラスは `@MainActor` なのでタスク本体も MainActor 上で動き、`appState` 更新の整合は保たれる。

## 検証
- 手動: 発話中（=transcribe 実行中）も波形が滑らかに動く。
- 手動: わざと無音→波形が静まる、喋る→波形が立つ、が入力に追従する。
- 文字起こしの速度・精度に影響しない（transcribe 経路は不変）。

## 将来の保険
万一、重い推論中に波形がカクつく（CPU 枯渇）場合は、文字起こしループ自体を MainActor から
外す（transcribe を background 実行し、appState 更新だけ MainActor へ hop する）アーキテクチャ変更を検討。
ただし large-v3-turbo は ANE 実行のため CPU 枯渇は起きにくい想定。
