---
title: スクロールバック検索
description: ⌘F の SearchBar オーバーレイ。検索本体は libghostty へ委譲し、host は UI と件数表示を持つ
updated: 2026-09-06
---

# スクロールバック検索

⌘F でアクティブタブに検索バーをオーバーレイする。needle を入力すると逐次検索し、Enter で次 / Shift+Enter で前へ循環ジャンプ、Esc で終了してターミナルへフォーカスを返す。件数は selected/total で表示する。表示中にもう一度 ⌘F を押した場合は入力欄への再フォーカスのみで、バーを二重生成しない。

## 検索本体は libghostty へ委譲

検索そのものは libghostty が持つ。host は `ghostty_surface_binding_action` の `search:<needle>` / `navigate_search:next|previous` / `end_search` を駆動し、件数を `SEARCH_TOTAL` / `SEARCH_SELECTED` アクションで受け取るだけ。対応はリテラル一致のみ（正規表現非対応）。

## UI

`SearchBar` は AppKit facade（公開 API とコールバックは AppKit のまま）で、中身は SwiftUI。「次へ」は `.onSubmit` で拾うため、IME 変換確定の Enter では発火しない。「前へ」は Shift+Return のみ捕捉し、plain Return は素通しする。閉じるのは Esc。

見た目はガラス面。入力中（focus かつ非空）は外枠の accent リングだけで示し、下線は持たない。一致なし（total=0）は danger 色で「一致なし」と示す。**検索窓の幅は固定**で、件数表示の有無・桁数では変わらない——入力欄が伸縮して吸収する。ガラス面は背景透過（`ChromeTranslucency`、[config](../platform/config.md) の背景透過とブラー）に連動し、透過時は tint を実効不透明度で薄め、ブラー OFF なら VisualEffectView を外して素通し半透明にする。不透明時（100%・フルスクリーン）は不透明ガラスカードのまま。
