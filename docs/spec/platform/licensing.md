---
title: ライセンスと第三者帰属
description: Orbe 自身の GPL-3.0-or-later 表明と、第三者ライセンスの帰属（NOTICE）・全文（licenses/）・.app 同梱の構成
updated: 2026-09-17
---

# ライセンスと第三者帰属

Orbe 自身のライセンスは **GPL-3.0-or-later**。著作権表示は `Copyright (C) 2026 Takeo Nakashima`。この文字列はルート `LICENSE`（GPL 全文の冒頭ヘッダ）・`NOTICE` 冒頭・`app/Info.plist` の `NSHumanReadableCopyright` の 3 箇所で一字一句一致する。リポジトリ全体に適用し、`vendor/` 配下の**第三者由来ファイル**だけは上流のライセンス（MIT 等）を維持し GPL 許諾の対象外（vendor/ 内の Orbe 自作分は GPL）——この境界は `NOTICE` 冒頭で明示する。

## ファイル構成

- **`LICENSE`**（ルート）… GPL-3.0 全文。冒頭に著作権表示＋標準の適用告知。
- **`NOTICE`**（ルート）… 配布物に含まれる第三者の帰属表示。冒頭に GPL 宣言・ソース入手先 `https://github.com/nakashima-takeo/orbe`・vendor 除外の注記。各エントリは著作権者・ライセンス名・配布物中のパス・上流 URL・全文の所在（`licenses/` 基準）を持つ。
- **`licenses/`**（ルート）… 第三者ライセンス全文の唯一の置き場。**上流の pin 版からの逐語コピー**であり、書き起こしも著作権年の書き換えもしない（Orbe 自身の著作権年を更新する一括処理の対象外）。同一ライセンス全文を複数コンポーネントで共有する場合はライセンス名で置く（`Apache-2.0.txt`・`OFL-1.1.txt`・`LGPL-2.1.txt`）。単独のものは `<component>-<上流ファイル名>.txt`（`freetype-FTL.txt`・`swift-cmark-COPYING.txt` など）。部品の上流ライセンスファイルが別ファイルを明示的に指す場合は、そのファイルも同じ命名で置く（`freetype-bdf-README.txt`・`uucode-LICENSE_unicode.txt` など）。

**pin 版**とは、配布物に入るものを固定している版を指す。依存パッケージなら `build.zig.zon`（`vendor/ghostty` 配下を含む）の `.hash` が固定する tarball、または `Package.resolved` が固定するリビジョン。Zig 標準ライブラリならツールチェーンの同梱物で、版は `mise.toml` が固定する。pin 版の配布物がライセンスファイルを含まない場合に限り、同じコミットの上流原本から取る。

**第三者の一覧は `NOTICE` が唯一の正で、この spec は持たない。** 同じ一覧を 2 箇所に置くと片方だけが更新されるため。読むべきは `NOTICE` 本体。

## `.app` 同梱

`build-app.sh` が `LICENSE`・`NOTICE`・`licenses/` を `<bundle>/Contents/Resources/` 直下へコピーする（テキストのため app 署名の封に入る）。`NSHumanReadableCopyright` は Finder の「情報を見る」と標準 About パネルに出る。

## 追随の規律

依存を追加・変更したら、`NOTICE` のエントリと `licenses/` の全文を追随させる。追随のきっかけは `vendor/ghostty` の SHA 更新・`Package.resolved` 更新・`mise.toml` の zig 版更新の 3 つ。zig 版が対象に入るのは、libghostty に焼き込まれる Zig 標準ライブラリと compiler_rt の帰属がツールチェーンの版に付くため。`licenses/` はコミット原本であり、手で追随する。

### 網羅の基準

帰属は**部品単位**で行う。Chromium の credits、Android の NOTICE、Electron アプリなど、一般的な製品と同じ基準である。部品とは、`Orbe.app`（実行体と同梱リソース）に入る第三者のパッケージ・ライブラリ・フォント・ツールチェーンのランタイムを指す。

- **`NOTICE`:** 部品ごとに、名前・pin 版の版数・上流ライセンスファイルに書かれた著作権者・ライセンス名・配布物中の所在・上流 URL を書く。
- **`licenses/`:** 上流が配布するライセンスファイルを逐語で置く。上流のトップレベルのライセンスファイルが、部品の一部について別のファイルを明示的に指している場合は、そのファイルも置く。
- **部品の中:** 個々のファイルの出所や派生元は追わない。部品の上流ライセンスに委ねる。

### 部品が入っているかの確認

部品が入っているかは、部品ごとに確かめる。`build.zig.zon` は候補の列挙にしか使えない。`.lazy = true` の依存は構成によって入ったり入らなかったりする（HarfBuzz は macOS/CoreText 構成では入らず、libintl・dcimgui は lazy でも入る）。

- **コード:** `build-app.sh` と同じ `zig build` フラグに `-Dstrip=false` を足して libghostty を組み、`swift build -c release` で Orbe をリンクする。`dsymutil .build/release/Orbe -o <worktree の外>` で dSYM を作り、`dwarfdump --debug-line` の行テーブルで、その部品のソース（`vendor/ghostty/zig-pkg/<hash>/` など）にアドレスが 0 でない行があるかを見る。あれば入っている。`<hash>` がどの部品かは `vendor/ghostty/build.zig.zon` と `vendor/ghostty/pkg/<name>/build.zig.zon` の `.hash` で引く。
- **埋め込みデータ:** `@embedFile` で埋め込むフォントなどは、元ファイルの断片がバイト列として実行体に現れるかで確かめる。
- **同梱リソース:** `build-app.sh` が `Contents/Resources` にコピーするものを確かめる。

### 載せないもの

- **Swift ランタイム。** 実行体に埋め込まれる部分は、Swift の Runtime Library Exception が帰属の義務を免除する。
- **Apple SDK ヘッダのインライン部分。** Xcode と Apple SDK の使用許諾の下で組み込むもので、全ての macOS アプリが同じ形で含む。
- **libc++。** ランタイムはシステムの動的ライブラリ（`otool -L` で確認）で、実行体にはヘッダのインライン部分しか入らない。
- **最終リンクで除かれる部品。** libvaxis・zf は Ghostty の CLI アクション用で、`libghostty-internal.a` には入るが、Orbe の最終リンクで除かれて `Contents/MacOS/Orbe` には残らない。

### 監査後の復元

監査用のビルドは `vendor/ghostty/macos/GhosttyKit.xcframework` をデバッグ情報付きで上書きする。確認が終わったら通常の `zig build` を再実行し、通常ビルドの成果物に戻す（キャッシュが効くので数秒で済み、出力アーカイブは監査前とバイト単位で一致する）。dSYM などの監査生成物は worktree の外に置く。
