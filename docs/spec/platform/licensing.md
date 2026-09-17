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
- **`licenses/`**（ルート）… 第三者ライセンス全文の唯一の置き場。**上流の pin 版からの逐語コピー**であり、書き起こしも著作権年の書き換えもしない（Orbe 自身の著作権年を更新する一括処理の対象外）。同一ライセンス全文を複数コンポーネントで共有する場合はライセンス名で置く（`Apache-2.0.txt`・`OFL-1.1.txt`・`LGPL-2.1.txt`）。単独のものは `<component>-<上流ファイル名>.txt`（`freetype-FTL.txt`・`swift-cmark-COPYING.txt` など）。

**第三者の一覧は `NOTICE` が唯一の正で、この spec は持たない。** 同じ一覧を 2 箇所に置くと片方だけが更新されるため。読むべきは `NOTICE` 本体。

## `.app` 同梱

`build-app.sh` が `LICENSE`・`NOTICE`・`licenses/` を `<bundle>/Contents/Resources/` 直下へコピーする（テキストのため app 署名の封に入る）。`NSHumanReadableCopyright` は Finder の「情報を見る」と標準 About パネルに出る。

## 追随の規律

依存を追加・変更したら、`NOTICE` のエントリと `licenses/` の全文を追随させる。追随のきっかけは `vendor/ghostty` の SHA 更新・`Package.resolved` 更新・`mise.toml` の zig 版更新の 3 つ。zig 版が対象に入るのは、libghostty に焼き込まれる Zig 標準ライブラリと compiler_rt の帰属がツールチェーンの版に付くため。`licenses/` はコミット原本であり、手で追随する。

libghostty 側の網羅は、**配布する最終実行体 `Contents/MacOS/Orbe` に実際に残ったもの**から導く。確認はコードとデータの 2 段で行う。コードは行テーブルで見えるが、`@embedFile` で埋め込まれたフォント等のデータは行テーブルに現れないため。

### コードの帰属

1. `build-app.sh` と同じ `zig build` フラグに `-Dstrip=false` を足して libghostty を組み、`swift build -c release` で Orbe をリンクする。
2. `dsymutil .build/release/Orbe -o <worktree の外>` で dSYM を作り、`dwarfdump --debug-line` で行テーブルを出す。
3. 各 `debug_line` セクションの `include_directories`／`file_names` で File 番号をパスに解決し、**アドレスが 0 でない行を 1 つでも持つソースファイル**を集める。コンパイル単位によってはパスが相対で出るが、`zig-pkg/<パッケージハッシュ>` などの部分で出所は決まる。**行を持つ＝実行体に入っている**、が判定規則。
4. 集めたファイルを出所の単位にまとめる: `vendor/ghostty/zig-pkg/<pkg>`（依存の原本。C/C++ 依存の原本もここにあり、どのライブラリかは `vendor/ghostty/pkg/<name>/build.zig.zon` のハッシュで引く）、`vendor/ghostty/pkg/<name>`（ghostty 側のビルド用ラッパー）、ツールチェーンの `lib/std`・`lib/compiler_rt`、ghostty 自身の `src/`。各単位を `NOTICE` のエントリと突き合わせる。
5. 生きている依存やツールチェーンのファイルが第三者由来のコードを含むことがある。そのため生存ファイルの冒頭（10 行程度）を `Ported from`・`Derived from`・`Copyright` で走査し、派生元を拾う。派生元は、生存ファイルで確認できたものだけを `NOTICE` 本文に書き、その全文を `licenses/` に置く。上流 LICENSE が挙げていても生存しない派生元は載せない。

### データの帰属

生存した Zig パッケージと ghostty `src/` について、`@embedFile` の対象とビルド時生成物（uucode の Unicode 表など）を列挙する。ghostty は参照されない `@embedFile` を実行体に残さないため、宣言の有無では判定できない。各候補の固有文字列を `strings` で実行体から探し、実在を確かめる。フォントの name table は UTF-16 なので、ASCII と UTF-16BE の両方で探す。

### 載せないもの

ツールチェーン提供のヘッダで、ランタイムがシステム側の動的ライブラリ（`otool -L` で確認）にあり、ライセンスが埋め込み例外を持つものは載せない。該当するのは libc++ で、行テーブルにはヘッダのインライン部分が出るが、LLVM exception の免除対象になる。

### 根拠にならないもの

- **`build.zig.zon` の依存一覧。** `.lazy = true` の依存は構成によってリンクされず（HarfBuzz は macOS/CoreText 構成では入らない）、逆に lazy でも無条件にリンクされるもの（libintl・dcimgui）がある。
- **アーカイブのメンバ列挙（`ar -t`・`nm -a` の OSO デバッグマップ）。** Zig ソースの依存は全て `libghostty_zcu.o` 1 つに合体してメンバ名から消え、ReleaseFast＋strip ではシンボル名も残らない。逆に libvaxis・zf のように、アーカイブにはあっても Swift 側リンクの `-dead_strip` で実行体に残らないものを見分けられない。

### 監査後の復元

監査用のビルドは `vendor/ghostty/macos/GhosttyKit.xcframework` をデバッグ情報付きで上書きする。確認が終わったら通常の `zig build` を再実行し、通常ビルドの成果物に戻す（キャッシュが効くので数秒で済み、出力アーカイブは監査前とバイト単位で一致する）。dSYM や集計結果などの監査生成物は worktree の外に置く。
