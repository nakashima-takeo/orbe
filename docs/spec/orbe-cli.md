---
title: Orbe CLI（Orbe 自身を操作する CLI・現状）
description: ペイン内・外から Orbe 自身の設定/ワークスペース/pane/tab を操作する `orb` CLI（config/ws/pane/tab サブコマンド・明示ターゲット・全ペイン PATH 注入配布・socket 文脈解決・終了コード契約）
updated: 2026-07-23
---

ユーザー/AI がペイン内・外から Orbe 自身を構成・操作する CLI。[control-api](control-api.md) の control.sock を直に叩く薄い socket クライアント（GhosttyKit/AppKit 非依存・Foundation のみ）。**PATH 上のコマンド名は `orb`**（`.app` の GUI 実行体 `Orbe` と別名。`Orbe` と打つと GUI 本体が起動してしまうため名前を分けている）。設定変更は GUI 設定パレット（[settings-palette](settings-palette.md)）と同一の適用経路を control 越しに使う。

## サーフェス

設定・ワークスペース（インスタンス/WS 単位。ペイン非依存）:
- `orb config list [--workspace [<id>]] [--json]` … 設定の現在値・scope・domain。
- `orb config get <key> [--workspace [<id>]] [--json]` … 単一設定（クライアントが list から抽出）。
- `orb config set <key> <value> [--workspace [<id>]]` … 設定適用。`key` は設定パレットと同じ安定 kebab key。値型は key ごと（数値／真偽〔`true/false/on/off/1/0`〕／文字列）。全設定が `--workspace` で上書き可。
- `orb config unset <key> [--workspace [<id>]]` … 上書きを解除して継承へ戻す。`--workspace` 省略は global 明示値の除去、指定はその WS 上書きの解除。
  - `--workspace` の値: 無指定＝global、フラグのみ＝アクティブ WS 上書き、`<id>` 指定＝**その WS**（非アクティブ可）の上書き。
- `orb ws list [--json]` / `ws new <name> [--dir <path>]` / `ws rename <id|current> <name>` / `ws dir <id|current> <path>` / `ws switch <id>` / `ws rm <id|current>`

pane/tab（レイアウト操作。ペイン内は `ORBE_PANE` を現ペイン既定に、外部は明示ターゲット必須）:
- `orb pane list [--workspace <id>] [--json]` … pane 一覧（paneId/workspaceId/tabId/title/cwd/agentState/focused）。
- `orb pane split [<pane>] [-v|-h]` … 分割（`-v`＝左右〔縦線・既定〕、`-h`＝上下）。新 paneId を返す。
- `orb pane close [<pane>]` … GUI の Cmd+W と同一カスケード（最後の pane→tab→アクティブ WS の最後のタブは 0 タブ空状態で残す）。
- `orb pane focus <pane>` … 別 WS なら activate 込み。位置引数必須。
- `orb tab new [--workspace <id>] [--cmd "…"] [--dir <path>]` / `orb tab close [<tab>]`

各サブコマンドは対応する [control-api](control-api.md) メソッドへそのまま乗る。`--json` は全 read、`--help` は全階層で固有 usage（`pane split` の `-h` は上下分割フラグであって help ではない。help は `--help` のみ）。`<id|current>` の `current` はアクティブ WS。

## 文脈解決

control.sock の解決順は `ORBE_STATE_DIR`（非空の明示指定・最優先。`$ORBE_STATE_DIR/control.sock` を使い `ORBE_SOCK` は見ない）→ `ORBE_SOCK`（ペイン注入の絶対パス）→ 既定の Application Support 直下（自ビルドのチャネルが焼いた bundle id・[channel](channel.md)）。pane/tab は現ペイン既定に `ORBE_PANE`（ペイン注入の自 pane id）を読む。config/ws はインスタンス/WS 単位なので `ORBE_PANE` を読まない。外部（`ORBE_PANE` 無し）で pane/tab の対象を省略すると usage エラー（exit 2）。

## 終了コード・エラー

- 成功=0、usage エラー（未知 key・引数不足・非数値 id・対象欠如等でクライアントが弾く）=2、RPC/接続エラー=1。
- Orbe 未起動や Orbe 外（socket 不達）は、クラッシュせず構造化メッセージ＋非 0 終了（`--json` 時は `{"error":{code,message}}`）。
- control の error は code/message をそのまま出す（値域外・不正 enum・未知/最後の workspace・未知 pane/tab 等は control 側が弾く）。未知 key・型不一致はクライアントが `config_list` を SSOT に事前に弾く。

## 配布・PATH

ビルド成果物を `build-app.sh` が `.app/Contents/Resources/bin/orb` へ同梱し、ad-hoc 署名に含める。`SurfaceView` が**全ペイン（root・split とも）**の生成時にこの bin dir をペイン `PATH` の先頭へ前置する（`ORBE_SOCK`/`ORBE_PANE`/`ORBE_REPORT_BIN` 注入と同じ機構）。libghostty は各ペインの PATH に `.app` の実行体 dir を無条件で append するが、CLI は別名 `orb` なので **PATH 順序に依存せず必ず同梱 CLI に解決する**。これにより Orbe が生成した任意ペイン（リポジトリ外 cwd・分割で生じたペイン含む）で `orb` が当該インスタンスの socket に届く。global install や symlink は行わない。

実体は `Sources/orbe-cli/`。設定適用の共有経路は設定パレットと共用（[settings-palette](settings-palette.md)）。
