# Orbe 開発ドキュメント

Orbe は AI エージェントとの開発を前提に設計した macOS ネイティブターミナル。エージェントを作業コンテキストと状態を持つ第一級の存在として扱い、Issue / PR / ブランチから worktree とエージェントを立ち上げ、すべてのセッションの状態を見渡し、エージェント自身にもターミナルを操作させる。

**技術スタック**: Swift 6.0（言語モード v5）/ macOS 14+ / SwiftPM のみ（Xcode プロジェクトなし）/ AppKit + SwiftUI 混在 / ターミナルエンジンは [libghostty](spec/terminal/libghostty.md)（固定 SHA pin・静的リンク・Metal 描画）/ 外部依存は swift-markdown と Sparkle / CI は GitHub Actions（lint・format・build・test）。

## 地図

| 読みたいもの | 場所 |
|---|---|
| 全体像（実行体・制御チャネル・モジュール構成） | [architecture.md](architecture.md) |
| 機能ごとの現状仕様 | [spec/](spec/README.md)（下に目次） |
| ビルド手順 | [guides/build.md](guides/build.md) |
| 外観の思想・トークン | [design/design-system.md](design/design-system.md)（機械可読ミラー [design/tokens.json](design/tokens.json)） |
| テストの層構成と方針 | [testing/test-architecture.md](testing/test-architecture.md) |
| テスト実装の進捗 | [testing/roadmap.md](testing/roadmap.md) |

アイデア・要望・不具合・積んである作業は GitHub Issue が持つ。「なぜ今こうなっているか」の記録は当該変更の PR 本文が持つ。

## spec 目次

規約と領域の定義は [spec/README.md](spec/README.md)。

**terminal/ — ターミナル表面**

- [core](spec/terminal/core.md) — libghostty 埋め込みの土台（描画・入力・ライフサイクル）
- [libghostty](spec/terminal/libghostty.md) — 埋め込むエンジンの外部契約（変えられない境界）
- [ime](spec/terminal/ime.md) — 日本語 IME 入力
- [search](spec/terminal/search.md) — スクロールバック検索（⌘F）

**chrome/ — GUI の枠**

- [chrome](spec/chrome/chrome.md) — 常駐 StatusRow（現在地・タブ行・状態インジケータ）
- [layout](spec/chrome/layout.md) — window 構成・分割ツリー・ショートカット
- [menubar](spec/chrome/menubar.md) — メニューバー投影（4 態のピル）
- [help](spec/chrome/help.md) — ヘルプオーバーレイ（⌘H）

**palette/ — オーバーレイ型 UI**

- [dispatch](spec/palette/dispatch.md) — 作業コンテキストから始める（⌘⇧X）
- [workspace](spec/palette/workspace.md) — workspace 切替・作成（⌘⇧S / ⌘N）・共有 PaletteCard 規律
- [settings](spec/palette/settings.md) — 設定パレット（⌘,）
- [attention](spec/palette/attention.md) — 対応すべきエージェントの一覧（⌘⌘）
- [completion](spec/palette/completion.md) — コマンド補完ドロップダウン

**agent/ — エージェント**

- [launch](spec/agent/launch.md) — CLI 検出と起動（⌘⇧A / ⌘⇧C）
- [notify](spec/agent/notify.md) — hook からの状態報告の配管
- [plugin-package](spec/agent/plugin-package.md) — 配布プラグインパッケージ

**control/ — 外部からの操作**

- [api](spec/control/api.md) — 制御 API（control.sock 上の JSON-RPC）と MCP ブリッジ
- [cli](spec/control/cli.md) — `orb` CLI

**platform/ — アプリ基盤**

- [workspace](spec/platform/workspace.md) — 名前付きコンテナの保持・切替・設定上書き
- [config](spec/platform/config.md) — 設定の 3 層読み込みとテーマ
- [persistence](spec/platform/persistence.md) — 構成の永続と復元・resume
- [channel](spec/platform/channel.md) — dev / release ビルドチャネル
- [update](spec/platform/update.md) — アプリ内アップデート（Sparkle）
- [localization](spec/platform/localization.md) — UI 言語（日英）
- [licensing](spec/platform/licensing.md) — ライセンスと第三者帰属

## 用語集

一般知識やコード読解では意味に辿り着けない、このリポジトリ固有の語だけを載せる。

| 語 | 意味 |
|---|---|
| chrome | ターミナル surface の外側にある Orbe 自身の UI 全般（StatusRow・タブ行・パレット等） |
| surface | libghostty が描くターミナル 1 枚。`SurfaceView`（NSView）1 つに対応する |
| workspace | プロジェクトごとにタブ・作業ディレクトリ・設定を束ねる名前付きコンテナ |
| mount / 休眠 | 分割ツリーをウィンドウ階層へ載せる（外す）こと。休眠 workspace は surface 未生成のまま保持される |
| Dispatch | worktree / ブランチ / Issue / PR から作業を開始するパレット（⌘⇧X） |
| Attention | 対応すべきエージェント（waiting / done）を横断集約する単一情報源とその表示面 |
| エージェント状態 | タブ単位の `working / waiting / done / idle`。hook 報告で遷移する |
| チャネル | dev / release のビルド identity。bundle ID から state まで全分離 |
| state dir | インスタンスの永続一式（workspaces.json 等）と control.sock の置き場 |
| gui.conf | 設定パレットが再生成する ghostty conf の最終層（user 設定より後勝ち） |
