---
title: ビルドチャネル（現状）
description: dev / release の 2 チャネル。ORBE_CHANNEL を唯一の入力に identity（bundle ID・表示名・アイコン）と Swift 定義を全導出し、dev は「Orbe Dev」として本番と併存する
updated: 2026-07-23
---

チャネルは dev / release の 2 つ。`scripts/build-app.sh` の env `ORBE_CHANNEL` が唯一の入力で、厳密一致の `release`（`release-app.sh` だけが立てる）のみ release、それ以外はすべて dev。

| | dev | release |
|---|---|---|
| bundle ID | `dev.orbe.app.dev` | `dev.orbe.app` |
| 表示名（CFBundleName / CFBundleDisplayName） | Orbe Dev | Orbe |
| アイコン | アンバー地（glyph は共有） | オリジナル |
| Swift 定義 | なし | `-DORBE_RELEASE` |
| インストール先 | `/Applications/Orbe Dev.app`（local-release） | `/Applications/Orbe.app`（DMG / Sparkle） |

- **`app/Info.plist` は 1 枚が SSOT。** dev の identity 差分はビルド時に導出して上書きする（release は無加工）。アイコンも `app/Orbe.icon` 1 つが SSOT で、dev は背景 fill だけ差し替えて actool にかける。`CFBundleExecutable` は両チャネル `Orbe`。
- **Swift 定義は `-DORBE_RELEASE` の 1 本**（release がオプトイン）。素の `swift build` は dev になる——フラグを付け忘れた経路が本番 identity へ落ちないための極性。
- **バンドルを持たない実行体（`orb`・`orbe-mcp`）は `Bundle.main.bundleIdentifier` が取れない**ため、fallback bundle ID を同じ定義から焼く（`OrbePaths.fallbackBundleId`）。同一チャネルでビルドされた GUI と CLI は必ず同じ state / control.sock を解決する。
- **state は bundle ID 由来で全分離**（[persistence](persistence.md)）。dev と release は workspaces・settings・control.sock・UserDefaults を共有せず、同時起動できる。
- dev は Sparkle の更新確認に行かない（[update](update.md) の起動ゲート）。
