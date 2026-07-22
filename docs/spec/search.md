---
title: スクロールバック検索（現状）
description: Cmd+F の SearchBar オーバーレイ — libghostty 委譲の逐次検索・循環ジャンプ・件数表示
updated: 2026-07-22
---

Cmd+F でフォーカス中ペインに検索バーをオーバーレイ。needle 入力で逐次検索、Enter 次 / Shift+Enter 前へ循環ジャンプ、Esc で終了しターミナルへフォーカスを返す、件数は selected/total 表示。表示中の再 Cmd+F は入力欄への再フォーカスのみ（二重生成しない）。

検索本体は libghostty に委譲する。host は `ghostty_surface_binding_action` の `search:<needle>` / `navigate_search:next|previous` / `end_search` を駆動し、件数は `SEARCH_TOTAL` / `SEARCH_SELECTED` アクションで受ける。リテラルのみ（正規表現非対応）。

`SearchBar` は AppKit facade（公開 API とコールバックは AppKit のまま）で、中身は SwiftUI。次へは `.onSubmit`（IME 変換確定の Enter では発火しない）、前へは Shift+Return のみ捕捉して plain Return は素通し、閉じるは Esc。

見た目はガラス面（[config](config.md) §5.5）。入力中（focus かつ非空）は外枠の accent リングだけで示し下線は持たない。一致なし（total=0）は danger 色で「一致なし」。**検索窓の幅は固定**で、件数表示の有無・桁数では変わらない（入力欄が伸縮して吸収する）。ガラス面は背景透過（`ChromeTranslucency`）に連動し、透過時は tint を実効不透明度で薄め、ブラー OFF なら VisualEffectView を外して素通し半透明にする。不透明時（100%・フルスクリーン）は不透明ガラスカードのまま。
