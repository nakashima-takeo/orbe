---
title: レイアウト
description: window の SwiftUI ホスト構成・workspace / タブ / surface の構造・一方向参照・フォーカス管理・ショートカット・オーバーレイ提示機構
updated: 2026-09-06
---

# レイアウト

1 つのウィンドウの中に何がどう積まれ、誰が誰を参照するかの構造。ここが窓・chrome・端末・オーバーレイの土台になる。

## SwiftUI ホスト構成

host 所有。`window.contentView` は SwiftUI ルート `ChromeHostingView`。ルートビュー `AppShell` は最背面に装飾層 `BackgroundGlow`（accent＋working のラジアル・非対話）を敷き、その上に上段 chrome ＋下段 content を置く。

- `BackgroundGlow` の地は透過状態で変わる: **不透明時（100%・フルスクリーン）は不透明な地を敷き**、**透過時は地を敷かず clear** にする——端末の透明ピクセルをデスクトップまで抜くため。glow ラジアル自体は透過時も残る。
- content の不透明な地は通常は各端末 surface が描くため、**surface が 1 枚も無い 0 タブ workspace のときだけ** content を薄めた地で埋める。透過ウィンドウ越しにデスクトップが透けるのを防ぐ backstop で、背景不透明度の設定変更にライブ追従する。タブがあるときは出さず二重 veil を避ける。
- 上段 chrome はネイティブ SwiftUI。content（端末の器）は既存 AppKit ビューを passthrough representable で内包する。
- 配置状態（content とその空判定）と上段 chrome の状態は薄い `@Observable` モデル経由で `WindowController` が所有・駆動する（状態の正は WindowController）。
- 背景透過／ブラーは `WindowController` が所有する `ChromeTranslucency` を各 SwiftUI root へ Environment 注入して chrome 各面へ配り、各面が自分の地を同じ実効不透明度で薄める——端末面と veil 濃度を揃えるため。端末領域には塗らず二重 veil を避ける（値更新は窓の不透明度同期と同一 tick）。
- 窓ドラッグは chrome 背景の透明 NSView が `mouseDown` で処理する。1 クリックは `window.performDrag(with:)` で Window Server へ委譲し（Space 切替等に参加させるため）、ダブルクリックはシステム設定 `AppleActionOnDoubleClick` を読んで zoom / miniaturize / 無効を明示実行する。タブ／＋ は前面で tap を持つため空き領域だけを拾う。信号機ボタンの位置は極小 representable が読み、上段テキストの縦中心へ反映する。
- パレット・オンボーディング等のフルウィンドウ overlay は `AppShell` の `.overlay` でネイティブ SwiftUI compose する（提示状態と各 overlay のモデルを提示元が立て下げる。addSubview／入れ子 NSHostingView は持たない）。窓全面（タイトルバー帯を含む）を占めるため safe-area を無視する。

## 構造と参照方向

1 ウィンドウは複数の workspace（→ [workspace](../platform/workspace.md)）を束ね、各 workspace が複数タブ、各タブが端末 surface を 1 枚持つ。ドメイン状態は Foundation 純粋型 `SessionStore` が持ち、`WindowController` が窓・ビュー・chrome を束ねる薄いコーディネータ、その下に `Workspace`（root path ＋タブ群）・`TerminalTab`（タブの同一性・エージェント状態・明示タイトル・復元単位・制御イベントの発火）・`SurfaceView`（surface 1 = NSView 1。libghostty 埋め込みと、シェルが報告するタイトル / cwd）と続く。タブの表示単位は `SurfaceView` をネイティブスクロールバー層で包んだ view（→ [terminal/core](../terminal/core.md)）で、mount・クローズ・スナップショットはタブを単位に扱う。

参照は**一方向**。タブ → 上位への通知（タブ閉鎖・タイトル・ウィンドウレベル chrome キー・cwd 報告・エージェント状態変化）はすべて `TerminalTab` のクロージャを `WindowController` が配線し、surface は所属タブへ事実（タイトル・cwd・閉鎖要求）を通知するだけで、どちらも上位を型として参照しない。

## chrome キーの分類

chrome キー（`WindowCommand`）は「タブが無くても効くか」の網羅分類を持つ。default 節なしの switch なので、将来コマンドを追加するとこの分類はコンパイルで強制される。

- **タブ不要のコマンド**（新タブ・閉じたエージェント パレット・新規 workspace・workspace 切替・デフォルトエージェント起動・各パレット表示・設定）は window レベルが surface より先に配信するため、surface が 1 枚も無い 0 タブでも効く（overlay 表示中は不活性。surface があるときも同じハンドラへ集約されるので挙動差はない）。
- **タブ依存のコマンド**（タブ切替・リネーム・⌘W）は surface 起点のままで、0 タブでは受け手が無く no-op。

## フォーカス

フォーカスは排他管理。タブ切替・workspace 切替・パレットを閉じたときは、切替先タブの端末へフォーカスが戻る。

## ショートカット

- Cmd+T 新タブ / Cmd+Shift+T 閉じたエージェント パレット（後述）/ Cmd+Shift+[ ] および Cmd+Shift+←→ タブ切替 / Cmd+W タブを閉じる（アクティブ workspace の最後のタブを閉じても 0 タブの空状態でアクティブに残る。ウィンドウは閉じない → [workspace](../platform/workspace.md)）/ Cmd+Shift+A エージェント起動パレット・Cmd+Shift+C デフォルトエージェント起動（→ [agent/launch](../agent/launch.md)）/ Cmd+Shift+S workspace パレット（→ [workspace パレット](../palette/workspace.md)）/ Cmd+, 設定パレット（→ [settings](../palette/settings.md)）/ Cmd+F スクロールバック検索（→ [search](../terminal/search.md)）/ Cmd+R タブリネーム（→ [chrome](chrome.md)）/ Cmd+↑↓ スクロールバック先頭/末尾ジャンプ（→ [terminal/core](../terminal/core.md)）/ Cmd+Shift+E アクティブタブの cwd を GUI エディタで開く / ⌘⌘（Cmd 素タップ×2）Attention パレット（→ [attention](../palette/attention.md)。前面時。背面時はメニューバーのドロップダウン → [menubar](menubar.md)）。
- フォント動的ズーム Cmd +/-/0（ghostty binding action）。

**Cmd+Shift+T は「閉じたエージェント」パレットを開く**（→ [closed-agents](../palette/closed-agents.md)）。この workspace で閉じたまま戻っていないエージェントセッションを[寿命ログ](../platform/session-log.md)から一覧し、Enter で 1 件を末尾に休眠チケットとして戻して起こす。閉じ方（人のジェスチャ・プロセス終了・制御 API・エージェント自身の終了）を問わず、アプリの再起動をまたいで戻せる。素のシェルタブは対象外——戻してもプロセスもスクロールバックも戻らず、resume を持つ CLI だけが中身ごと戻るため。戻るのは cwd と同一性だけで、明示タイトルは付かず、位置は新規タブと同じ規則——同じ worktree の連が残っていればその右端、無ければ末尾（→ [persistence](../platform/persistence.md)・[chrome](chrome.md) の連）。0 タブの workspace でも開く。

## cwd の確定

新タブとエージェント起動タブの初期 cwd はアクティブタブの実効 cwd（0 タブなら workspace の root path）を**明示指定**して起こす——cwd 未指定の surface は ghostty がホームへ解決してしまうため、ここで必ず確定させる。workspace 新規作成時の初期シェルは rootPath 指定（→ [workspace](../platform/workspace.md)）。

## GUI エディタ起動（Cmd+Shift+E）

アクティブタブの cwd（OSC 7 報告値、無ければ初期 cwd）を GUI エディタでフォルダとして開く。エディタは `$VISUAL` → `$EDITOR`（GUI エディタのときのみ採用）→ PATH 検索（`code`/`cursor`/`windsurf`/`zed`/`subl` の先頭ヒット）で決定し、解決・起動は子プロセス PATH（[shell-path](../platform/shell-path.md)）で行う——GUI アプリの限定 PATH を回避するため。解決できたときだけプロセス内に覚える。未検出は `NSAlert`、cwd 不明はビープ。
