---
title: ライセンスと第三者帰属
description: Orbe 自身の GPL-3.0-or-later 表明と、第三者ライセンスの帰属（NOTICE）・全文（licenses/）・.app 同梱の構成
updated: 2026-09-17
---

# ライセンスと第三者帰属

Orbe 自身のライセンスは **GPL-3.0-or-later**。著作権表示は `Copyright (C) 2026 Takeo Nakashima`。この文字列はルート `LICENSE`（GPL 全文の冒頭ヘッダ）・`NOTICE` 冒頭・`app/Info.plist` の `NSHumanReadableCopyright` の 3 箇所で一字一句一致する。リポジトリ全体に適用し、`vendor/` 配下の**第三者由来ファイル**だけは上流のライセンス（MIT 等）を維持し GPL 許諾の対象外（vendor/ 内の Orbe 自作分は GPL）——この境界は `NOTICE` 冒頭で明示する。

## ファイル構成

- **`LICENSE`**（ルート）… GPL-3.0 全文。冒頭に著作権表示＋標準の適用告知。
- **`NOTICE`**（ルート）… 配布物に含まれる第三者の帰属表示。冒頭に GPL 宣言・ソース入手先 `https://github.com/nakashima-takeo/orbe`・vendor 除外の注記。各エントリは部品名・ライセンス名・配布物中の所在・上流 URL・全文の所在（`licenses/` 基準）を持つ。
- **`licenses/`**（ルート）… 第三者ライセンス全文の唯一の置き場。**上流ライセンスファイルの逐語コピー**であり、書き起こしも著作権年の書き換えもしない（Orbe 自身の著作権年を更新する一括処理の対象外）。同一ライセンス全文を複数コンポーネントで共有する場合はライセンス名で置く（`Apache-2.0.txt`・`OFL-1.1.txt`・`LGPL-2.1.txt`）。単独のものは `<component>-<上流ファイル名>.txt`（`freetype-FTL.txt`・`swift-cmark-COPYING.txt` など）。部品の上流ライセンスファイルが別ファイルを明示的に指す場合は、そのファイルも同じ命名で置く（`freetype-bdf-README.txt`・`uucode-LICENSE_unicode.txt` など）。

ライセンスファイルは、部品を足したときに pin されている版から取る。依存パッケージなら `build.zig.zon`（`vendor/ghostty` 配下を含む）の `.hash` が固定する tarball、または `Package.resolved` が固定するリビジョン。Zig 標準ライブラリなら `mise.toml` が固定するツールチェーンの同梱物。その配布物がライセンスファイルを含まない場合に限り、同じコミットの上流原本から取る。

**第三者の一覧は `NOTICE` が唯一の正で、この spec は持たない。** 同じ一覧を 2 箇所に置くと片方だけが更新されるため。読むべきは `NOTICE` 本体。

## `.app` 同梱

`build-app.sh` が `LICENSE`・`NOTICE`・`licenses/` を `<bundle>/Contents/Resources/` 直下へコピーする（テキストのため app 署名の封に入る）。`NSHumanReadableCopyright` は Finder の「情報を見る」と標準 About パネルに出る。

## 追随の規律

### 基準

帰属は、Chromium の credits など一般的な製品と同じく**部品単位**で行う。部品とは、`Orbe.app`（実行体と同梱リソース）に入る第三者のパッケージ・ライブラリ・フォント・ツールチェーンのランタイムを指す。

- `NOTICE` には部品ごとに、部品名・ライセンス名・`licenses/` のライセンスファイルへの参照を書く。
- **版数は書かない。**
- **著作権者は上流ライセンスファイルに委ねる。** `NOTICE` 本文に書くのは、上流のライセンス文そのものが配布文書に求める帰属文（FreeType の「based in part on the work of the FreeType Team」など）だけ。
- 出所の説明も、版やファイル名に依存しない書き方にする。
- ライセンスの種類が複数ある部品（二重ライセンス、部品の一部が別ライセンス）は、その旨をライセンス名に書く。
- 上流のトップレベルのライセンスファイルが別のライセンスファイルを明示的に指していれば、それも `licenses/` に置く。

こうしておくと、版の更新では `NOTICE` も `licenses/` も変わらない。

### いつ追随するか

次のときに、その部品のエントリと上流ライセンスファイルを足す・消す。

- 依存を追加・削除したとき。対象は `Package.resolved`、`build.zig.zon`（`vendor/ghostty` 配下を含む）、`mise.toml` のツールチェーン、補完エンジン（`vendor/completion-engine`）の依存、同梱するフォントやリソースなど。
- `vendor/ghostty` の pin 更新で、依存の顔ぶれが変わったとき。

**版の更新だけなら、ライセンスの種類が変わらない限り作業は要らない。**

### 載せないもの

- **Swift ランタイム。** 実行体に埋め込まれる部分は、Swift の Runtime Library Exception が帰属の義務を免除する。
- **Apple SDK ヘッダのインライン部分。** Xcode と Apple SDK の使用許諾の下で組み込む。
- **libc++。** ランタイムはシステムの動的ライブラリで、実行体にはヘッダのインライン部分しか入らない。
- **最終リンクで除かれる部品。** libvaxis・zf は `libghostty-internal.a` には入るが、Orbe の最終リンクで除かれて実行体には残らない。

### 顔ぶれの確認（任意）

libghostty の依存の顔ぶれに疑いがあるときは、実行体に実際に入っている部品を確かめられる。

- **コード:** `build-app.sh` と同じ `zig build` に `-Dstrip=false` を足して組み、`swift build -c release`・`dsymutil` で worktree の外に dSYM を作る。`dwarfdump --debug-line` の行テーブルに、その部品のソース（`vendor/ghostty/zig-pkg/<hash>/` 配下）でアドレスが 0 でない行があれば、その部品は入っている。
- **埋め込みフォント:** 元ファイルの断片がバイト列として実行体にあるかで確かめる。

確認後は通常の `zig build` を再実行し、デバッグ情報付きで上書きされた `vendor/ghostty/macos/GhosttyKit.xcframework` を通常の成果物に戻す。
