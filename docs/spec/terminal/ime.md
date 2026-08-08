---
title: 日本語 IME 入力
description: NSTextInputClient 準拠で preedit・確定・候補ウィンドウ配置を libghostty へ配線する
updated: 2026-08-08
---

# 日本語 IME 入力

ターミナルで日本語入力を成立させるための配線。macOS の IME は `NSTextInputClient` を通じてアプリと対話するため、`SurfaceView` がこれに準拠し、未確定文字列（preedit）・確定・候補ウィンドウ配置を libghostty へ橋渡しする。

## キーイベントの優先順位

`keyDown` は chrome キー・補完 popup のキーを先取りしてから IME 解釈へ回す。変換中でもアプリ操作キーを IME に奪わせないための順序。`keyDown` を経ない `insertText`（音声入力・ペーストなど）は、キーではなくテキストとして送出する。

## 確定文字への貫通防止

生キー送出時の `composing` フラグは、IME 解釈の**前後の preedit 有無の OR** で決める。こうすると preedit 最後の 1 文字を消す Backspace も `composing: true` になり、libghostty が端末出力を抑制して、確定済み文字への Backspace 貫通を防ぐ。

## 補完との共存

preedit の開始（空→非空）は補完 popup を消し、変換中は popup のキー横取りを止める（[completion](../palette/completion.md) の IME preedit 共存）。
