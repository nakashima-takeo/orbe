---
title: ターミナル基盤（現状）
description: libghostty 埋め込みの土台 — 描画・入力・選択・クリップボード・描画駆動・ライフサイクル・ビルド構成
updated: 2026-07-22
---

Apple Silicon 専用の自己署名 `.app`。[libghostty](libghostty.md) の surface API を NSView に埋め込み、リソースをバンドルから自動検出して環境変数なしで自己完結する。

起動直後（Ghostty 初期化前）に 2 つの前処理を置く:
- `SIGPIPE` を無視する——制御ソケットの fire-and-forget クライアントが切断した後の write で本体が落ちないため（write は戻り値で扱う）。
- 自プロセス環境から Claude Code 系のセッション判定マーカーを明示列挙で一掃する（ユーザー設定・認証系の環境変数は残す）。これにより Claude Code セッション内から起こされた場合でも、各ペイン（Orbe から開いた Orbe の入れ子を含む）は親セッションの文脈を継承せず独立したトップレベルセッションとして起動する。

## surface の生成・操作

surface の生成・操作（`ghostty_surface_new`／`set_size`／`set_focus`／`key`／`binding_action`／`surface_free`／`surface_draw` 等）は app を作った単一スレッド＝main(AppKit) 固定の外部契約（background へ出さない）。呼び出しは `dispatchPrecondition` で明示する。

`SurfaceView` は AppKit bounds × backingScale から算出した**非負・非ゼロ面積**のピクセルサイズだけを `ghostty_surface_set_size` へ渡す。レイアウト途中の不正／ゼロ面積フレーム（負・NaN・∞・ゼロ）は渡さない（settle 後の有効フレームで後着更新される）。

pty fork ＋シェル起動のみ surface 生成時に spawn される io スレッドで非同期（生成は起動完了を待たない）。アクティブ workspace の surface 生成は可視タブ即時・隠れタブを後続 runloop tick へ分割スケジュールして 1 turn の生成数を上限化する（[workspace](workspace.md)）。

GPU 描画。surface view は layer-hosting（libghostty が自前のレイヤを view に代入してから `wantsLayer` を立てる規約に従い、host 側は `wantsLayer` を先に立てない）。描画駆動は `wakeup_cb` → `ghostty_app_tick` → RENDER アクション → `ghostty_surface_draw`。CVDisplayLink で vsync コアレッス（常時 60fps タイマーを持たない）。

**可視性同期（外部契約）**: surface の可視性はホストが `ghostty_surface_set_occlusion` へ同期する。`window != nil && 非 hidden && ウィンドウが可視` を導出し、差分ゲート（同値スキップ・初回必送）を通して送る（導出とゲートは純ロジックに切り出し。surface 未生成時は送信も記録もしない）。集約点は view の hide/unhide・window 付替えの全分岐・ウィンドウの occlusion 変化通知（window 付替えで購読を張り替え・すべて main）。可視へ転じたときはサイズを無条件に再アサートする。**不可視中の surface は描画のみ停止**し、端末状態・pty は前進する（制御 API の読みは不変）。表示復帰時の 1 フレーム描画は libghostty が担保する。backingScale 変化時はレイヤの `contentsScale` を（アニメーション無効で）同期してからサイズを更新する。

## 入力・クリップボード

- 全キーボード入力・修飾キー・マウス選択・コピー&ペースト。危険ペーストの確認は `confirm_read_clipboard_cb` に回り、許可する。**OSC 52 read（端末アプリ発のクリップボード読み取り）は空文字で完了して拒否する**（情報漏洩防止）。
- ベル（`RING_BELL`）は警告音のみで視覚表現を持たない。
- ターミナル内 URL／ファイルパスのオープン（`OPEN_URL`）は host が処理し `NSWorkspace` で開く。この action は常に処理済みを返し libghostty のフォールバックオープナーは使わない。C 側の文字列ポインタはコールバック中だけ有効なので bytes を即コピーしてから main で開く。解決は純関数: scheme 付きはそのまま、scheme 無しは `~` 展開してファイル URL 扱い、`kind==text` は既定エディタ・それ以外は URL の既定アプリ。
- マウスボタンは左/右/中および拡張ボタンを libghostty へ転送する（マウスレポート有効な TUI のため）。フォーカス移動は左クリックのみ。マウス位置は tracking area で伝える（enter で viewport 内に位置確立・exit で範囲外座標）。
- スクロールは `scrollWheel` で受けた delta を即蓄積して返し、次 run loop tick の合体 flush で累積 delta と mods を 1 回だけ渡す（`scrollWheel` 内で同期呼び出しせず、同一 tick の複数入力を 1 回に合体する。累積総量は保存される）。precision／momentum phase は AppKit イベント由来で mods に載せ、mods は最新を採る。
- キー入力は `ghostty_surface_key_translation_mods`（`macos-option-as-alt`）で mods を翻訳したイベントを `interpretKeyEvents` へ渡す（mods 不変時は元イベントを再利用）。surface へ渡す `key.text` は PUA 関数キー（0xF700–0xF8FF）を除外し、先頭バイトが 0x20 以上のときだけ付与する——**C0 制御文字（Enter/Tab/Escape 等）は text を付けず keycode のみで送る**（特殊キー・制御の符号化は libghostty が keycode から行うため）。`key.consumed_mods` は翻訳 mods から control/command を除いた集合。
- Finder からのファイル／フォルダのドラッグ&ドロップ（`.fileURL` のみ受理）はドロップ先ペインへフォーカスを移してから、各パスをシェルエスケープしスペース区切りでカーソル位置へ挿入する（Enter は送らない）。
- 日本語 IME は [ime](ime.md)。

## スクロールバー

各ペインは `NSScrollView` ラップ層に包まれ、ネイティブの overlay スクローラ（autohide）を持つ。スクロール量とセル寸法は libghostty のアクションで受け取り、documentView の高さとスクロール位置に同期する（AppKit の +Y 上向きへ反転）。バードラッグは live scroll を行へ換算し binding action で core へ送る（同一行は冗長送信を抑制）。

ペインフォーカス時の `Cmd+↑`/`Cmd+↓`（Shift なし）は chrome が先取りしてスクロールバック先頭/末尾へジャンプさせる——このため ghostty 既定の `jump_to_prompt` はこの 2 キーからは呼べない。

## ライフサイクル

ウィンドウを閉じる時に実行中プロセスがあれば確認ダイアログ（`ghostty_app_needs_confirm_quit`）。最後のウィンドウを閉じるとアプリ自体が終了し、終了時に永続のデバウンス待ち保存を flush する（[persistence](persistence.md)）。shell exit 時は該当ペインを閉じる。

標準メニューバー（App＋Edit）を据える。Edit の標準編集コマンドは target=nil で responder chain へ配送され、overlay（chrome）のテキスト入力欄が ⌘V/⌘C/⌘X/⌘A を受ける。端末 surface はコピー&ペーストを自前実装し `paste:`/`copy:`/`selectAll:` を responder として実装しないため、これらメニュー項目は surface フォーカス時に自動無効化され、key equivalent が消費されず keyDown → libghostty へ通る（端末側の ⌘V 等は非破壊）。App メニューの ⌘Q は上記の実行中プロセス確認を経て終了する。

## 構成

SwiftPM（GhosttyKit は `.binaryTarget`、md プレビュー用に apple/swift-markdown を依存 → [editor-pane](editor-pane.md)）。`Sources/Orbe/` 配下が本体、実行ターゲット `orbe-mcp`/`orbe-report` は [control-api](control-api.md)、`orbe-cli` は [orbe-cli](orbe-cli.md)。`scripts/build-app.sh` が `.app` 生成・自己署名。端末テーマ `app/themes/OrbeDark・OrbeLight` は識別色 SSOT から生成してコミットする成果物で、`swift test` が ANSI ink スロットの背景に対する WCAG AA 4.5 と SSOT からの drift を検証する。
