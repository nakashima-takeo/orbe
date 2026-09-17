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
- **`licenses/`**（ルート）… 第三者ライセンス全文の唯一の置き場。**上流の pin 版からの逐語コピー**であり、書き起こしも著作権年の書き換えもしない（Orbe 自身の著作権年を更新する一括処理の対象外）。同一ライセンス全文を複数コンポーネントで共有する場合はライセンス名で置く（`Apache-2.0.txt`・`OFL-1.1.txt`・`LGPL-2.1.txt`）。単独のものは `<component>-<上流ファイル名>.txt`（`freetype-FTL.txt`・`swift-cmark-COPYING.txt` など）。上流に独立したライセンスファイルが無く、告知がファイル冒頭にしか無いもの（部品の中の第三者由来ファイル）は、その冒頭ブロックを逐語で切り出して `<component>-<ファイル名>-LICENSE.txt` に置く（`freetype-bdfdrivr-LICENSE.txt` など）。

**第三者の一覧は `NOTICE` が唯一の正で、この spec は持たない。** 同じ一覧を 2 箇所に置くと片方だけが更新されるため。読むべきは `NOTICE` 本体。

## `.app` 同梱

`build-app.sh` が `LICENSE`・`NOTICE`・`licenses/` を `<bundle>/Contents/Resources/` 直下へコピーする（テキストのため app 署名の封に入る）。`NSHumanReadableCopyright` は Finder の「情報を見る」と標準 About パネルに出る。

## 追随の規律

依存を追加・変更したら、`NOTICE` のエントリと `licenses/` の全文を追随させる。追随のきっかけは `vendor/ghostty` の SHA 更新・`Package.resolved` 更新・`mise.toml` の zig 版更新の 3 つ。zig 版が対象に入るのは、libghostty に焼き込まれる Zig 標準ライブラリと compiler_rt の帰属がツールチェーンの版に付くため。`licenses/` はコミット原本であり、手で追随する。

### 網羅の単位

libghostty 側の網羅は、**配布する最終実行体 `Contents/MacOS/Orbe` に残るファイル**を単位にする。部品（ライブラリ）単位では足りない。部品の中には、部品自身のライセンス文が覆わない著作権者のファイルが混ざっているため（FreeType の BDF/PCF ドライバ、sentry-native の jsmn.h など）。

判定規則: 生存ファイルの冒頭に現れる著作権者が、その部品の同梱ライセンス文に名前で現れる（または部品の contributors として同じライセンスに含まれる）なら、部品のエントリで覆われている。現れなければ、`NOTICE` にそのファイルの著作権者とライセンス名を書き、告知文を `licenses/` に置く。パブリックドメイン宣言だけのファイルは義務が無いので載せない。

`build.zig.zon` は候補の列挙にしか使えない。`.lazy = true` の依存は構成によって入ったり入らなかったりする（HarfBuzz は macOS/CoreText 構成では入らず、libintl・dcimgui は lazy でも入る）。

確認はコードとデータの 2 段で行う。行テーブルはコードしか映さず、`@embedFile` の中身や comptime の表は映らないため。

### コードの帰属

1. `build-app.sh` と同じ `zig build` フラグに `-Dstrip=false` を足して libghostty を組み、`swift build -c release` で Orbe をリンクする。
2. `dsymutil .build/release/Orbe -o <worktree の外>` で dSYM を作り、`dwarfdump --debug-line` で行テーブルを出す。
3. 各 `debug_line` セクションの `include_directories`／`file_names` で File 番号をパスに解決し、**アドレスが 0 でない行を 1 つでも持つソースファイル**を集める。**行を持つ＝実行体に入っている**、が判定規則。コンパイル単位によってはパスが相対で出るが、`zig-pkg/<パッケージハッシュ>` などの部分で出所は決まる。
4. 集めたファイルを出所の単位にまとめる: `vendor/ghostty/zig-pkg/<hash>`（依存の原本。どの部品かは `vendor/ghostty/pkg/<name>/build.zig.zon` と `vendor/ghostty/build.zig.zon` の `.hash` で引く）、ツールチェーンの `lib/std`・`lib/compiler_rt`、ghostty 自身の `src/`。
5. **生存ファイル全て**について、冒頭 60 行（または先頭のコメントブロック）を `Copyright`・`License`・`Ported from`・`Derived from`・`Based on`・`taken from`・`adapted from`・`public domain` で走査し、網羅の単位の判定規則で部品のライセンス文に覆われない著作権者を拾う。

### データの帰属

ghostty `src/` と生存した Zig パッケージの全ファイルを、生存状態に関係なく走査する。対象は `@embedFile`、ビルド時生成物（uucode の Unicode 表など）、出所コメント（上の語や出所 URL）を伴う comptime の表。ghostty は参照されない `@embedFile` や表を実行体に残さないので、宣言があるだけでは判定できない。各候補の固有文字列を実行体から探し、見つかったものだけを載せる。表なら含まれる名前（キー名・色名など）、フォントなら name table の文字列を探す。name table は UTF-16 なので、ASCII と UTF-16BE の両方で探す。

### 載せないもの

次の 3 類型は行テーブルや走査に出ても載せない。

- **ツールチェーン提供のヘッダで、ランタイムがシステム側の動的ライブラリにあり（`otool -L` で確認）、ライセンスが埋め込み例外を持つもの。** 該当するのは libc++ で、実行体にはヘッダのインライン部分だけが入り、LLVM exception の免除対象になる。
- **埋め込み部分の帰属義務を免除する例外を持つランタイム。** 該当するのは Swift の後方互換ランタイムで、Swift の Runtime Library Exception が、実行体に埋め込まれた部分についての Apache-2.0 の 4(a)(b)(d) の義務を免除する。
- **Apple SDK ヘッダのインライン部分。** Xcode と Apple SDK の使用許諾の下で組み込むもので、全ての macOS アプリが同じ形で含む。

### 監査後の復元

監査用のビルドは `vendor/ghostty/macos/GhosttyKit.xcframework` をデバッグ情報付きで上書きする。確認が終わったら通常の `zig build` を再実行し、通常ビルドの成果物に戻す（キャッシュが効くので数秒で済み、出力アーカイブは監査前とバイト単位で一致する）。dSYM や集計結果などの監査生成物は worktree の外に置く。
