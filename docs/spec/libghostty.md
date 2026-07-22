---
title: libghostty の外部契約（現状）
description: Orbe が固定 SHA pin で埋め込む ghostty のライブラリ（MIT）— 2 層 API・alpha C API の性質・OSC 受信の境界・画面テキストの out-of-band 取得・埋め込みフォント
updated: 2026-07-22
---

ghostty のターミナル描画ライブラリ。MIT。Orbe はこれを埋め込んでいる。Orbe の実装が乗る外部契約——変えられない境界のみを記す。

## API は 2 層

- **surface 埋め込み API**（`include/ghostty.h`）… NSView を渡すと libghostty が Metal で GPU 描画し、PTY/shell 起動・VT パース・フォント整形・検索・リンク検出まで内部で行う。host は chrome（ウィンドウ/タブ/分割/設定/action 処理）だけ担う。Orbe が採用。
- **libghostty-vt**（`include/ghostty/vt.h`）… VT パースのみ。描画・PTY は自前。

## 性質

- **alpha・C API 非安定。** ヘッダ自身が「汎用 embedding 向けに安定化されていない／唯一の利用者は公式 macOS app」と明言。union/struct タグはヘッダと `.a` の不一致時にコンパイルが通っても実行時メモリ破壊を起こしうる。
- **リソース自動検出。** shell-integration / themes / terminfo を実行体からの相対で検出する（`Contents/Resources/terminfo/78/xterm-ghostty` をセンチネルに climb）。これが在れば `GHOSTTY_RESOURCES_DIR` 不要で自己完結する。
- macOS では `login`（setuid root）経由で shell を起動する。
- cwd は `terminal.getPwd()`＝シェルが OSC 7 で報告した値に依存（分割継承は `ghostty_surface_inherited_config` が運ぶ）。

## host へ渡る in-band シグナル（OSC 受信の境界）

surface の出力ストリーム由来のイベントは `action_cb`（`ghostty_action_tag_e`, `include/ghostty.h`）経由でのみ host に届く。出る/出ないの境界が固定:

- **host に露出する OSC 由来 action**: `SET_TITLE`/`SET_TAB_TITLE`（OSC 0/2）, `PWD`（OSC 7）, `DESKTOP_NOTIFICATION`（OSC 9 / 777）, `PROGRESS_REPORT`（OSC 9;4）, `MOUSE_OVER_LINK`（OSC 8）, `COLOR_CHANGE`（OSC 4/10/11）。
- **内部完結で host に来ない**: OSC 52 clipboard・OSC 66/21 kitty・OSC 133 semantic prompt 等。
- **独自/未知 OSC 番号は受け取れない**: OSC パーサ（`src/terminal/osc.zig`）はホワイトリスト方式で、未知番号は `.invalid` に遷移して全バイト破棄。
- **APC/DCS も host 非露出**: `src/terminal/stream.zig` で parse はされるが apprt 層で C API action に変換されない。

帰結: アプリ独自データを in-band で host に運びたい場合、**標準の通知 OSC（9/777）に相乗りする**しか無い（独自番号・APC/DCS は libghostty 改修＝pin と衝突）。典拠は `vendor/ghostty` の `include/ghostty.h`・`src/terminal/osc.zig`・`src/terminal/stream.zig`（pin SHA `3ba5e9c2`）。

## host が画面テキストを読む（out-of-band 取得）

上記の in-band（出力ストリーム由来イベント）の境界とは別に、host から能動的に画面テキストを取れる API がある（`include/ghostty.h`）:
- `ghostty_surface_read_text(surface, ghostty_selection_s, ghostty_text_s*)` … 選択範囲のテキストを取得。範囲は `ghostty_point_s`（tag: `ACTIVE`/`VIEWPORT`/`SCREEN`/`SURFACE`、coord: `EXACT`/`TOP_LEFT`/`BOTTOM_RIGHT`）で指定。`SCREEN` + `TOP_LEFT`〜`BOTTOM_RIGHT` で**スクロールバック全体**を平文取得できる。
- `ghostty_surface_read_selection` … 現在の選択範囲。返した `ghostty_text_s` は `ghostty_surface_free_text` で解放する。
- 入力注入は `ghostty_surface_text`（テキスト・ペースト相当で自己実行しない）・`ghostty_surface_key`（keycode/mods/text のキーイベント）。

帰結: 「画面/PTY は読み出せない」は誤り——可視範囲もスクロールバックも host から読める。Orbe の制御 API（[control-api](control-api.md)）はこの 3 経路に乗る。

## フォント

- 既定フォントは埋め込みの JetBrainsMono（NoNF 版、`src/font/embedded.zig`）。
- **Symbols Nerd Font（symbols-only 版）も埋め込まれ、実行時に常時 fallback face として登録される**（`src/font/SharedGridSet.zig:324`、`fallback = true`）。帰結: Nerd Font の PUA グリフは、フォント設定・システム導入なしで surface 上に描画される。
- 上記の埋め込み・fallback 登録が効くのは surface（terminal 描画）側のみ。native AppKit（chrome）側で PUA グリフを描くには明示フォント指定が要る。同梱登録は `CTFontManagerRegisterFontsForURL` で行え、TTF は `vendor/ghostty/src/font/res/` に実在する。

## 所在

- GitHub: https://github.com/ghostty-org/ghostty
- Orbe では `vendor/ghostty` submodule として固定 SHA `3ba5e9c2` に pin。
- ビルドは `docs/BUILD.md` 参照。
