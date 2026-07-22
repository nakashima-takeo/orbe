---
title: UI 言語（現状）
description: 現在言語ホルダー LocalizationStore を @Environment で全 chrome root へ配る日英2言語 i18n コア — 型付きキー辞書・即時切替・OS 追従の既定・プロセスロケール不干渉
updated: 2026-07-22
---

UI 言語は **日本語 / 英語の 2 択**。現在言語は `LocalizationStore` が唯一の SSOT として保持し（所有は `WindowController`）、`@Environment` で全 SwiftUI root へ注入する——chrome は複数の独立 root に跨るため、1 つのストアを配って全体を同時に動かす。言語を代入すると全 root が再描画され、**UI 全体が即時に切り替わる（再起動不要）**。Environment 未注入（preview・浮遊 popup）の既定は OS 追従。

**プロセスロケール不干渉（境界）**: `AppleLanguages`・プロセスロケールには一切書き込まない。OS 言語は**読むだけ**。端末 pane の CJK 字形は locale 非依存で固定されており（[config](config.md)）、UI 言語切替はその字形描画に影響しない。

**既定言語（OS 追従）**: OS の優先言語の先頭コードが `ja` 始まりなら日本語、それ以外・不明は英語（純関数の分類）。確定した言語は `app-state.json` に永続し（[persistence](persistence.md)）、起動時に「永続値、無ければ OS 追従」で解決する。

**文言辞書**: UI 文言は型付きキー（フラット enum・粒度は「1 UI 文言 = 1 キー」）で参照し、値は日英ペアの辞書。SwiftUI 側と AppKit メインメニューの双方が同じ引き口を通す（言語分岐を 1 箇所へ集約するため）。辞書が全キーを網羅すること（欠落ゼロ）はテストが機械保証する。

**引き方**: 素文言・位置引数付き書式・複数形の 3 つ。書式テンプレートは言語ごとに語順を持つ（日英で語順が食い違うため）。複数形は英語が `count==1` で単数形、日本語は助数詞で単複不変（同一文言）。

**AppKit メインメニュー**: アプリ／編集メニューの文言も現在言語に追従する。言語変更のたびにメインメニューを現在言語で組み直す（theme が `NSApp.appearance` を同期するのと同じ位置づけ。言語未確定の初回は OS 追従の言語で建てる）。

言語の確定 UI は 2 つ: 初回起動の言語選択画面（[agent-launch](agent-launch.md)）と設定パレットの言語ドリルイン行（[settings-palette](settings-palette.md)）。いずれも「ストア更新 → メインメニュー再構築 → 永続化」を束ねて即時反映する。
