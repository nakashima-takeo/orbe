---
title: ライセンスと第三者帰属（現状）
description: Orbe 自身の GPL-3.0-or-later 表明と、第三者ライセンスの帰属（NOTICE）・全文（licenses/）・.app 同梱の構成
updated: 2026-07-22
---

Orbe 自身のライセンスは **GPL-3.0-or-later**。著作権表示は `Copyright (C) 2026 Takeo Nakashima`。この文字列はルート `LICENSE`（GPL 全文の冒頭ヘッダ）・`NOTICE` 冒頭・`app/Info.plist` の `NSHumanReadableCopyright` の 3 箇所で一字一句一致する。リポジトリ全体に適用し、`vendor/` 配下の**第三者由来ファイル**だけは上流のライセンス（MIT 等）を維持し GPL 許諾の対象外（vendor/ 内の Orbe 自作分は GPL）——この境界は `NOTICE` 冒頭で明示する。

ファイル構成:
- **`LICENSE`**（ルート）… GPL-3.0 全文。冒頭に著作権表示＋標準の適用告知。
- **`NOTICE`**（ルート）… 配布物に含まれる第三者の帰属表示。冒頭に GPL 宣言・ソース入手先 `https://github.com/nakashima-takeo/orbe`・vendor 除外の注記。各エントリは著作権者・ライセンス名・配布物中のパス・上流 URL・全文の所在（`licenses/` 基準）を持つ。
- **`licenses/`**（ルート）… 第三者ライセンス全文の唯一の置き場。**上流の pin 版からの逐語コピー**であり、書き起こしも著作権年の書き換えもしない（Orbe 自身の著作権年を更新する一括処理の対象外）。同一ライセンス全文を複数コンポーネントで共有する場合はライセンス名で置く（`Apache-2.0.txt`・`OFL-1.1.txt`・`LGPL-2.1.txt`）。単独のものは `<component>-<上流ファイル名>.txt`（`freetype-FTL.txt`・`swift-cmark-COPYING.txt` など）。

**第三者の一覧は `NOTICE` が唯一の正で、この spec は持たない。** 同じ一覧を 2 箇所に置くと片方だけが更新される。読むべきは `NOTICE` 本体。

`.app` 同梱: `build-app.sh` が `LICENSE`・`NOTICE`・`licenses/` を `<bundle>/Contents/Resources/` 直下へコピーする（テキストのため app 署名の封に入る）。`NSHumanReadableCopyright` は Finder の「情報を見る」と標準 About パネルに出る。

依存を追加・変更したら、`NOTICE` のエントリと `licenses/` の全文を追随させる（`vendor/ghostty` の SHA 更新時・`Package.resolved` 更新時が対象）。`licenses/` はコミット原本であり手で追随する。

**網羅の確認は配布バイナリから行う。** `nm -a` で `Contents/MacOS/Orbe` の OSO デバッグマップを全列挙し、アーカイブメンバごとに出所を帰属させる。`build.zig.zon` の依存一覧は網羅の根拠にならない——`.lazy = true` の依存は構成によってリンクされず（HarfBuzz は macOS/CoreText 構成では入らない）、逆に lazy でも無条件にリンクされるもの（libintl・dcimgui）がある。
