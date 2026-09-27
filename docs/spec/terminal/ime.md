---
title: 日本語 IME 入力
description: NSTextInputClient 準拠で preedit・確定・候補ウィンドウ配置を libghostty へ配線する
updated: 2026-09-27
---

# 日本語 IME 入力

ターミナルで日本語入力を成立させるための配線。macOS の IME は `NSTextInputClient` を通じてアプリと対話するため、`SurfaceView` がこれに準拠し、未確定文字列（preedit）・確定・候補ウィンドウ配置を libghostty へ橋渡しする。

## キーイベントの優先順位

`keyDown` は chrome キー・補完 popup のキーを先取りしてから IME 解釈へ回す。変換中でもアプリ操作キーを IME に奪わせないための順序。IME の確定は、`keyDown` の中でも外（音声入力・文字ビューア・変換中の ⌘ キーを IME へ渡している間の確定）でも、打った文字としてキーの道で送る——貼り付け（bracketed paste）にはしない。変換中の ⌘ 付きのキーは、窓の根でまず IME へ渡り、IME が使わなければ（渡している間にキー割り当てのコマンドを返せば）変換中でないときと同じ順で流れる（→ [レイアウト](../chrome/layout.md)の「chrome キーの分類」）。IME が先に確定してからコマンドを返したときは、確定した文字が打った文字として届いてから、キーが同じ順で流れる。

## 確定文字への貫通防止

生キー送出時の `composing` フラグは、IME 解釈の**前後の preedit 有無の OR** で決める。こうすると preedit 最後の 1 文字を消す Backspace も `composing: true` になり、libghostty が端末出力を抑制して、確定済み文字への Backspace 貫通を防ぐ。

## 補完との共存

preedit の開始（空→非空）は補完 popup を消し、変換中は popup のキー横取りを止める（[completion](../palette/completion.md) の IME preedit 共存）。
