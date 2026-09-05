---
title: ターミナル基盤
description: libghostty の surface API を NSView に埋め込む土台 — 描画・入力・クリップボード・ライフサイクル・ビルド構成の契約
updated: 2026-09-06
---

# ターミナル基盤

Orbe のターミナル画面そのものを支える土台。ターミナルエンジンには [libghostty](libghostty.md) を採用し、その surface API を NSView に埋め込んで Metal で描画する。成果物は Apple Silicon 専用の自己署名 `.app` で、リソースをバンドルから自動検出するため環境変数なしで自己完結する。

## 起動時の前処理

Ghostty を初期化する前に、プロセス全体へ効く 2 つの前処理を置く。

- **`SIGPIPE` を無視する。** 制御ソケットの fire-and-forget クライアントが切断した後の write でシグナルが飛び、本体ごと落ちるのを防ぐため。write の失敗は戻り値で扱う。
- **Claude Code 系のセッション判定マーカーを自プロセス環境から一掃する**（明示列挙。ユーザー設定・認証系の環境変数は残す）。Orbe 自体が Claude Code セッション内から起動された場合でも、各タブ（Orbe から開いた Orbe の入れ子を含む）が親セッションの文脈を継承せず、独立したトップレベルセッションとして始まるようにするため。

## surface の生成・操作

surface の生成・操作（`ghostty_surface_new`／`set_size`／`set_focus`／`key`／`binding_action`／`surface_free`／`surface_draw` など）は、app を作った単一スレッド＝main(AppKit) に固定して呼ぶ。これは libghostty 側の外部契約で、background へ出してはならない。呼び出しは `dispatchPrecondition` でこの規律を明示する。

`SurfaceView` が `ghostty_surface_set_size` へ渡すのは、AppKit bounds × backingScale から算出した**非負・非ゼロ面積**のピクセルサイズだけ。レイアウト途中に現れる不正フレーム（負・NaN・∞・ゼロ面積）は渡さない。落としても、レイアウトが settle した後の有効フレームで後着更新されるため問題にならない。

pty fork ＋シェル起動だけは、surface 生成時に spawn される io スレッドで非同期に走る（surface 生成はシェルの起動完了を待たない）。アクティブ workspace の surface 生成は、可視タブを即時・隠れタブを後続の runloop tick へ分けてスケジュールし、1 turn あたりの生成数に上限を設ける（[workspace](../platform/workspace.md)）。

## 描画

GPU（Metal）描画。surface view は layer-hosting で、libghostty が自前のレイヤを view に代入してから `wantsLayer` を立てる規約に従う——host 側が先に `wantsLayer` を立ててはならない。

描画駆動は `wakeup_cb` → `ghostty_app_tick` → RENDER アクション → `ghostty_surface_draw` の流れ。vsync への同期は CVDisplayLink でコアレッスし、常時 60fps のタイマーは持たない。

### 可視性の同期（外部契約）

surface の可視性はホストが `ghostty_surface_set_occlusion` へ同期する。可視判定は `window != nil && 非 hidden && ウィンドウが可視` から導出し、差分ゲート（同値スキップ・初回必送）を通して送る。導出とゲートは純ロジックに切り出してあり、surface 未生成時は送信も記録もしない。

同期の集約点は、view の hide/unhide・window 付替えの全分岐・ウィンドウの occlusion 変化通知（window 付替えで購読を張り替える。すべて main）。可視へ転じたときはサイズを無条件に再アサートする。

**不可視中の surface は描画のみ停止**し、端末状態・pty は前進し続ける。したがって制御 API からの読み取りは可視性に影響されない。表示復帰時の 1 フレーム描画は libghostty が担保する。backingScale 変化時はレイヤの `contentsScale` を（アニメーション無効で）同期してからサイズを更新する。

## 入力・クリップボード

全キーボード入力・修飾キー・マウス選択・コピー&ペーストを扱う。

- **クリップボード**: 危険ペーストの確認は `confirm_read_clipboard_cb` に回り、許可する。**OSC 52 read（端末アプリ発のクリップボード読み取り）は空文字で完了して拒否する**——クリップボード内容の情報漏洩を防ぐため。
- **ベル**（`RING_BELL`）は警告音のみで、視覚表現を持たない。
- **URL／ファイルパスのオープン**（`OPEN_URL`）は host が処理し `NSWorkspace` で開く。この action は常に処理済みを返し、libghostty のフォールバックオープナーは使わない。C 側の文字列ポインタはコールバック中だけ有効なため、bytes を即コピーしてから main で開く。開き先の解決は純関数: scheme 付きはそのまま、scheme 無しは `~` 展開してファイル URL 扱い、`kind==text` は既定エディタ・それ以外は URL の既定アプリ。
- **マウス**: 左/右/中および拡張ボタンを libghostty へ転送する（マウスレポートを使う TUI のため）。フォーカス移動は左クリックのみ。マウス位置は tracking area で伝える（enter で viewport 内に位置確立・exit で範囲外座標）。
- **スクロール**: `scrollWheel` で受けた delta を即蓄積して返し、次 run loop tick の合体 flush で累積 delta と mods を 1 回だけ渡す。`scrollWheel` 内で同期呼び出しはせず、同一 tick の複数入力を 1 回に合体する（累積総量は保存される）。precision／momentum phase は AppKit イベント由来で mods に載せ、mods は最新を採る。
- **キー入力**: `ghostty_surface_key_translation_mods`（`macos-option-as-alt`）で mods を翻訳したイベントを `interpretKeyEvents` へ渡す（mods 不変時は元イベントを再利用）。surface へ渡すキー入力の値（keycode・生成文字・無修飾文字・mods・消費された mods）は、物理キー経路と制御チャネルの `send_key`（→ [control/api](../control/api.md)）が同じ型で組み、送出の規則はそこに集まる: `key.text` は PUA 関数キー（0xF700–0xF8FF）を除外し、先頭バイトが 0x20 以上かつ DEL（0x7F）でないときだけ付与する。**C0 制御文字（Enter/Tab/Escape 等）と DEL は text を付けず keycode のみで送る**——特殊キー・制御の符号化は libghostty が keycode から行うため（text を載せると消費された修飾が差し引かれ、Shift+Enter や kitty 下の Shift+Backspace の修飾が落ちる）。`key.consumed_mods` は text を生成するために消費された修飾で、物理経路では翻訳 mods から control/command を除いた集合。
- **ドラッグ&ドロップ**: Finder からのファイル／フォルダ（`.fileURL` のみ受理）は、ドロップ先の端末へフォーカスを移してから、各パスをシェルエスケープしスペース区切りでカーソル位置へ挿入する。Enter は送らない——実行するかはユーザーの判断に残す。
- 日本語 IME は [ime](ime.md) が持つ。

## スクロールバー

各タブの surface は `NSScrollView` ラップ層に包まれ、ネイティブの overlay スクローラ（autohide）を持つ。スクロール量とセル寸法は libghostty のアクションで受け取り、documentView の高さとスクロール位置に同期する（AppKit の +Y 上向きへ反転）。バードラッグは live scroll を行へ換算し、binding action で core へ送る（同一行は冗長送信を抑制）。

端末フォーカス時の `Cmd+↑`/`Cmd+↓`（Shift なし）は chrome が先取りし、スクロールバック先頭/末尾へジャンプさせる。このため ghostty 既定の `jump_to_prompt` はこの 2 キーからは呼べない。

## ライフサイクル

アプリを終了するとき、実行中プロセスがあれば確認ダイアログを出す（`ghostty_app_needs_confirm_quit`）。確認を持つのは終了の関門ひとつだけで、ウィンドウの ✕・⌘Q / App メニュー・アップデートの再起動・ログアウトのどの経路から終了しても**同じ確認が 1 回だけ**出る。この関門はシステム側から始まる終了も通るので、ここに置かないと確認を素通りする経路ができる。確認の最中も端末の描画と制御 API は動き続ける——実行中プロセスの是非を問う画面で、判断材料である当のプロセスの出力が凍らないため。

ウィンドウは 1 枚で、それを閉じることはアプリを終了することと同義。よって ✕ は窓を閉じず終了を要求し、窓が閉じるのは終了が確定した後になる。確認をキャンセルすればウィンドウもメニューバー常駐もそのまま残る——窓を先に閉じると、キャンセルしたときにメニューバーの常駐だけが残り、開き直す先を失う。

終了時に永続のデバウンス待ち保存を flush する（[persistence](../platform/persistence.md)）。shell exit 時は該当タブを閉じる。

標準メニューバー（App＋Edit）を据える。Edit の標準編集コマンドは target=nil で responder chain へ配送され、overlay（chrome）のテキスト入力欄が ⌘V/⌘C/⌘X/⌘A を受ける。端末 surface はコピー&ペーストを自前実装しており、`paste:`/`copy:`/`selectAll:` を responder として実装しない。このためこれらのメニュー項目は surface フォーカス時に自動無効化され、key equivalent が消費されずに keyDown → libghostty へ通る（端末側の ⌘V 等を壊さない）。

## ビルド構成

SwiftPM のみで構成する。GhosttyKit は `.binaryTarget`、リリースノートの描画用に apple/swift-markdown を依存に持つ（→ [update](../platform/update.md)）。`Sources/Orbe/` 配下が本体。実行ターゲット `orbe-mcp`／`orbe-report` は [control/api](../control/api.md)、`orbe-cli` は [control/cli](../control/cli.md) が持つ。`scripts/build-app.sh` が `.app` 生成と自己署名を行う。

端末テーマ `app/themes/OrbeDark・OrbeLight` は識別色 SSOT から生成してコミットする成果物で、`swift test` が ANSI ink スロットの背景に対する WCAG AA 4.5 と、SSOT からの drift を検証する。
