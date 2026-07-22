---
title: レイアウト（現状）
description: window / workspace / タブ / ペイン分割ツリーの構造・一方向参照・フォーカス管理・ショートカット
updated: 2026-07-22
---

host 所有。`window.contentView` は SwiftUI ルート `ChromeHostingView`。ルートビュー `AppShell` は最背面に装飾層 `BackgroundGlow`（accent＋working のラジアル・非対話）を敷き、その上に上段 chrome ＋下段 content、表示中は右に sidePanel（EditorPane）を置く。

- `BackgroundGlow` の地は透過状態で変わる: **不透明時（100%・フルスクリーン）は不透明な地を敷き**、**透過時は地を敷かず clear** にする——端末の透明ピクセルをデスクトップまで抜くため。glow ラジアル自体は透過時も残る。
- content の不透明な地は通常は各端末 surface が描くため、**surface が 1 枚も無い 0 タブ workspace のときだけ** content を薄めた地で埋める（透過ウィンドウ越しにデスクトップが透けるのを防ぐ backstop。背景不透明度の設定変更にライブ追従する。タブがあるときは出さず二重 veil を避ける）。
- 上段 chrome はネイティブ SwiftUI。content / sidePanel（端末ツリーの器／EditorPane）は既存 AppKit ビューを passthrough representable で内包する。
- sidePanel の幅は未指定なら窓幅比の既定幅、ドラッグで選ぶと固定値。実効幅は上下限にクランプ（→ [editor-pane](editor-pane.md)）。
- 配置状態（content / sidePanel / 表示可否 / 幅）と上段 chrome の状態は薄い `@Observable` モデル経由で `WindowController` が所有・駆動する（状態の正は WindowController）。
- 背景透過／ブラーは `WindowController` が所有する `ChromeTranslucency` を各 SwiftUI root へ Environment 注入して chrome 各面へ配り、各面が自分の地を同じ実効不透明度で薄める——端末面と veil 濃度を揃えるため。端末領域には塗らず二重 veil を避ける（値更新は窓の不透明度同期と同一 tick）。
- 窓ドラッグは chrome 背景の透明 NSView が `mouseDown` で処理する。1 クリックは `window.performDrag(with:)` で Window Server へ委譲し（Space 切替等に参加させるため）、ダブルクリックはシステム設定 `AppleActionOnDoubleClick` を読んで zoom / miniaturize / 無効を明示実行する。タブ／＋ は前面で tap を持つため空き領域だけを拾う。信号機ボタンの位置は極小 representable が読み、上段テキストの縦中心へ反映する。
- パレット・オンボーディング等のフルウィンドウ overlay は `AppShell` の `.overlay` でネイティブ SwiftUI compose する（提示状態と各 overlay のモデルを提示元が立て下げる。addSubview／入れ子 NSHostingView は持たない）。窓全面（タイトルバー帯を含む）を占めるため safe-area を無視する。

1 ウィンドウは複数の workspace（→ [workspace](workspace.md)）を束ね、各 workspace が複数タブ、各タブは `NSSplitView` ツリーのペイン分割。ドメイン状態は Foundation 純粋型 `SessionStore` が持ち、`WindowController` が窓・ビュー・chrome を束ねる薄いコーディネータ、`Workspace`（root path ＋タブ群）・`TerminalController`（タブ内の分割ツリー）・`SurfaceView`（surface 1 = NSView 1）と続く。分割ツリーの葉は `SurfaceView` をネイティブスクロールバー層で包んだ単位（→ [terminal-core](terminal-core.md)）で、走査・分割・クローズ・スナップショットはこのラップを単位に扱う。

参照は**一方向**: ペイン → 上位の通知（タブ閉鎖・タイトル・レイアウト変化・ウィンドウレベル chrome キー・cwd 報告・エージェント状態変化）はすべて `TerminalController` のクロージャを `WindowController` が配線し、ペインは上位を型として参照しない。

ただし chrome キー（`WindowCommand`）は「タブ／ペインが無くても効くか」の網羅分類を持つ（default 節なしの switch＝将来のコマンド追加は分類がコンパイルで強制される）。**タブ不要のコマンド**（新タブ・新規 workspace・workspace 切替・デフォルトエージェント起動・各パレット表示・設定）は window レベルが surface より先に配信するため、surface が 1 枚も無い 0 タブでも効く（overlay 表示中は不活性。surface があるときも同じハンドラへ集約されるので挙動差はない）。**タブ依存のコマンド**（タブ切替・EditorPane 系・リネーム・⌘W）は surface 起点のままで、0 タブでは受け手が無く no-op。

フォーカスは排他管理。タブ切替・workspace 切替・パレットを閉じた時は、切替先タブが最後にフォーカスしていたペイン（無ければ最初のペイン）へフォーカスが戻る。

- Cmd+T 新タブ / Cmd+D 左右分割 / Cmd+Shift+D 上下分割 / Cmd+Shift+[ ] および Cmd+Shift+←→ タブ切替 / Cmd+W カスケードクローズ（ペイン → タブ → アクティブ workspace の最後のタブを閉じても 0 タブの空状態でアクティブに残る〔ウィンドウは閉じない〕→ [workspace](workspace.md)）/ Cmd+G エディタペイン（→ [editor-pane](editor-pane.md)）/ Cmd+Shift+A エージェント起動パレット・Cmd+Shift+C デフォルトエージェント起動（→ [agent-launch](agent-launch.md)）/ Cmd+Shift+S workspace パレット（→ [workspace](workspace.md)）/ Cmd+, 設定パレット（→ [settings-palette](settings-palette.md)）/ Cmd+F スクロールバック検索（→ [search](search.md)）/ Cmd+R タブリネーム（→ [chrome](chrome.md)）/ Cmd+↑↓ スクロールバック先頭/末尾ジャンプ（→ [terminal-core](terminal-core.md)）/ Cmd+Shift+E アクティブペインの cwd を GUI エディタで開く。
- フォント動的ズーム Cmd +/-/0（ghostty binding action）。
- 分割は `ghostty_surface_inherited_config`（OSC 7 で記憶した cwd 等）を親ペインから継承する。新タブとエージェント起動タブの初期 cwd はアクティブペインの実効 cwd（ペイン不在＝0 タブなら workspace の root path）を**明示指定**して起こす——cwd 未指定の surface は ghostty がホームへ解決してしまうため、ここで必ず確定させる。workspace 新規作成時の初期シェルは rootPath 指定（→ [workspace](workspace.md)）。
- Cmd+Shift+E はアクティブペインの cwd（OSC 7 報告値、無ければ初期 cwd）を GUI エディタでフォルダとして開く。エディタは `$VISUAL` → `$EDITOR`（GUI エディタのときのみ採用）→ PATH 検索（`code`/`cursor`/`windsurf`/`zed`/`subl` の先頭ヒット）で決定し、解決・起動はログインシェルの PATH で行う（GUI アプリの限定 PATH を回避）。解決結果はプロセス内で初回 1 回キャッシュ。未検出は `NSAlert`、cwd 不明はビープ。
