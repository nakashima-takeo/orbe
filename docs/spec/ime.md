---
title: 日本語 IME 入力（現状）
description: NSTextInputClient 準拠による preedit・確定・候補ウィンドウ配置の配線
updated: 2026-07-22
---

`SurfaceView` が `NSTextInputClient` に準拠し、preedit・確定・候補ウィンドウ配置を libghostty へ配線する。`keyDown` は chrome キー・補完 popup キーを先取りしてから IME 解釈へ回す。`keyDown` 外の `insertText`（音声入力・ペースト等）はキーでなくテキストとして送出する。

生キー送出時の `composing` フラグは IME 解釈の **前後の preedit 有無の OR** で決める——preedit 最後の 1 文字を消す Backspace も `composing: true` になり、libghostty が端末出力を抑制して確定文字への貫通を防ぐ。

preedit 開始（空→非空）は補完 popup を消し、変換中は popup のキー横取りを止める（→ [completion](completion.md) の IME preedit 共存）。
