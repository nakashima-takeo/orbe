# Orbe

AI コーディングエージェントのためのネイティブ macOS ターミナルアプリ。

- SwiftUI / AppKit + libghostty(MIT) によるネイティブ描画
- 並列エージェントセッション・worktree 連携
- VSCode とのワークスペース連動(予定)

## 動作要件

macOS 14.0 以降（Apple Silicon / Intel）。

## ビルド

フル Xcode と Zig 0.15.2 が要る。手順は **[docs/BUILD.md](docs/BUILD.md)**。

```bash
git submodule update --init --recursive
./scripts/build-app.sh
open build/Orbe.app
```

## 構成

`Orbe.app` 本体に加え、制御チャネル（`control.sock`・改行区切り JSON-RPC 2.0）を介する
補助実行体を持つ。`.app` に同梱されるのは `orb`（orbe-cli の同梱名）と `orbe-report`。

| 実行体 | 役割 |
|---|---|
| `Orbe.app` | ターミナル本体（libghostty を静的リンク） |
| `orbe-cli` | `config` / `ws` / `pane` / `tab` サブコマンド（同梱名 `orb`） |
| `orbe-mcp` | MCP(stdio) を制御チャネルへ転送するブリッジ（`.mcp.json` から起動・非同梱） |
| `orbe-report` | エージェント CLI の hook から状態を報告する |

設計ドキュメントは [docs/](docs/) に置く。

## 既知の制限

- **危険ペーストの確認ダイアログが出ない。** 上流 Ghostty は改行を含むペースト等を検出すると確認を求めるが、
  Orbe は現状これを無条件で許可する（上流との差分）。Web ページからコピーしたコマンドが意図せず
  そのまま実行されうるため、貼り付ける内容は自分で確認すること。確認 UI は v1.1 で対応予定。

## ライセンス

Orbe は [GPL-3.0-or-later](LICENSE)。Copyright (C) 2026 Takeo Nakashima
ソースコード: https://github.com/nakashima-takeo/orbe

同梱する第三者ソフトウェア（libghostty(MIT)、JetBrains Mono / JuliaMono(OFL-1.1)、
swift-markdown(Apache-2.0)、補完エンジン(MIT) 等）の帰属は [NOTICE](NOTICE)、
ライセンス全文は [licenses/](licenses/) に置く。`vendor/` 配下の第三者由来ファイルは上流のライセンスを
維持する（Orbe が書いたファイルは他と同じく GPL-3.0-or-later）。
