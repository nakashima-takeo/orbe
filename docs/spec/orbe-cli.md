---
title: Orbe CLI（Orbe 自身を操作する CLI・現状）
description: ペイン内・外から Orbe 自身の設定/ワークスペース/pane/tab を操作する `orb` CLI（config/ws/pane/tab サブコマンド・明示ターゲット・全ペイン PATH 注入配布・socket 文脈解決・終了コード契約）
updated: 2026-08-06
---

ユーザー/AI がペイン内・外から Orbe 自身を構成・操作する CLI。[control-api](control-api.md) の control.sock を直に叩く薄い socket クライアント（GhosttyKit/AppKit 非依存・Foundation のみ）。**PATH 上のコマンド名は `orb`**（`.app` の GUI 実行体 `Orbe` と別名。`Orbe` と打つと GUI 本体が起動してしまうため名前を分けている）。設定変更は GUI 設定パレット（[settings-palette](settings-palette.md)）と同一の適用経路を control 越しに使う。

## サーフェス

設定・ワークスペース（インスタンス/WS 単位。ペイン非依存）:
- `orb config list [--workspace [<id|current>]] [--json]` … 設定の現在値・scope・domain。
- `orb config get <key> [--workspace [<id|current>]] [--json]` … 単一設定（クライアントが list から抽出）。
- `orb config set <key> <value> [--workspace [<id|current>]]` … 設定適用。`key` は設定パレットと同じ安定 kebab key。値型は key ごと（数値／真偽〔`true/false/on/off/1/0`〕／文字列）。全設定が `--workspace` で上書き可。
- `orb config unset <key> [--workspace [<id|current>]]` … 上書きを解除して継承へ戻す。`--workspace` 省略は global 明示値の除去、指定はその WS 上書きの解除。
  - `--workspace` の値: フラグのみ＝アクティブ WS、`<id|current>` 指定＝**その WS**（非アクティブ可）。無指定は `set`/`unset` が global を書き、`list`/`get` はアクティブ WS の上書きを重ねた実効値を読む。
  - フラグと位置引数を取り切った残余に `-` 始まりが残れば usage エラー（exit 2）。`--workspace=<id>`（= 区切り）・綴り誤り・2 個目の `--workspace` はここで落ちる——黙って捨てると exit 0 のまま指定と違う WS を触ることになる。`-` 始まりを値として通す席は `config set <key> <value>` の `<value>` だけで（`config set font-size -1`）、`<key>` の席は通さない。
- `orb ws list [--json]` / `ws new <name> [--dir <path>]` / `ws rename <id|current> <name>` / `ws dir <id|current> <path>` / `ws switch <id>` / `ws rm <id|current>`
  - `--workspace` は取らない（対象は位置引数の `<id|current>`）。フラグと位置引数を取り切った残余に `-` 始まりが残れば usage エラー（exit 2）。位置引数（`<name>`・`<id|current>`・`<path>`）はいずれも `-` 始まりを取らないので、pane/tab と同じく**位置引数の席にも例外を設けない**。黙って捨てると `ws new <name> --dir=<path>` が既定 root の workspace を exit 0 で作る。

pane/tab（レイアウト操作。ペイン内は `ORBE_PANE` を現ペイン既定に、外部は明示ターゲット必須）:
- `orb pane list [--workspace <id|current>] [--json]` … pane 一覧（paneId/workspaceId/tabId/title/cwd/agentState/focused）。
- `orb pane split [<pane>] [-v|-h]` … 分割（`-v`＝左右〔縦線・既定〕、`-h`＝上下）。新 paneId を返す。
- `orb pane close [<pane>]` … GUI の Cmd+W と同一カスケード（最後の pane→tab→アクティブ WS の最後のタブは 0 タブ空状態で残す）。
- `orb pane focus <pane>` … 別 WS なら activate 込み。位置引数必須。
- `orb tab new [--workspace <id|current>] [--cmd "…"] [--dir <path>]` / `orb tab close [<tab>]`
  - `--workspace` を取るのは `pane list` と `tab new` だけ（値必須。bare は usage エラー）。他の pane/tab コマンドは取らない。
  - フラグと位置引数を取り切った残余に `-` 始まりが残れば usage エラー（exit 2）。pane/tab の id は常に正なので、config 系と違い**位置引数の席にも例外を設けない**（先頭から検査する）。黙って捨てると `ORBE_PANE` 既定へ落ち、`pane close`/`tab close` では指定と無関係な現ペイン・現タブが exit 0 のまま消える。

各サブコマンドは対応する [control-api](control-api.md) メソッドへそのまま乗る。`--json` は全サブコマンドで効き、control の result をそのまま出す——write が採番した id（`ws new` の workspaceId・`tab new` / `pane split` の paneId）はこの出力からしか読めない。`--help` は全階層で効き、固有 usage を持つのは `config set` と `pane split`、他はドメインの usage を出す（`pane split` の `-h` は上下分割フラグであって help ではない。help は `--help` のみ）。`<id|current>` の `current` はアクティブ WS。

値必須フラグ（`--workspace <id>` / `--dir <path>` / `--cmd "…"`）の値は `-` 始まりも空文字も取らない（usage エラー、exit 2）。`orb tab new --dir "$DIR" --cmd "$CMD"` の `$DIR` が空になる形が両方ここで落ちる——引用符が無ければトークンごと消えて `--cmd` が cwd に化け、引用符があれば空文字が cwd として通る。パスは絶対パスで渡す（`-` 始まりのディレクトリは `./-foo` の形）——相対パスは CLI も control も解決せずそのまま格納するので、利用者のシェルの cwd 基準にはならない。`~` 始まりを展開するのは workspace のパス（`ws new --dir` / `ws dir`）だけで、`tab new --dir` は展開せずそのまま cwd にする。

## 文脈解決

control.sock の解決順は `ORBE_STATE_DIR`（非空の明示指定・最優先。`$ORBE_STATE_DIR/control.sock` を使い `ORBE_SOCK` は見ない）→ `ORBE_SOCK`（ペイン注入の絶対パス）→ 既定の Application Support 直下（自ビルドのチャネルが焼いた bundle id・[channel](channel.md)）。pane/tab は現ペイン既定に `ORBE_PANE`（ペイン注入の自 pane id）を読む。config/ws はインスタンス/WS 単位なので `ORBE_PANE` を読まない。外部（`ORBE_PANE` 無し）で pane/tab の対象を省略すると usage エラー（exit 2）。

## 終了コード・エラー

- 成功=0、usage エラー（未知 key・引数不足・非数値 id・対象欠如等でクライアントが弾く）=2、RPC/接続エラー=1。
- Orbe 未起動や Orbe 外（socket 不達）は、クラッシュせず構造化メッセージ＋非 0 終了（`--json` 時は `{"error":{code,message}}`）。
- control の error は code/message をそのまま出す（値域外・不正 enum・未知/最後の workspace・未知 pane/tab 等は control 側が弾く）。未知 key・型不一致はクライアントが `config_list` を SSOT に事前に弾く。

## 配布・PATH

ビルド成果物を `build-app.sh` が `.app/Contents/Resources/bin/orb` へ同梱し、ad-hoc 署名に含める。`SurfaceView` が**全ペイン（root・split とも）**の生成時にこの bin dir をペイン `PATH` の先頭へ前置する（`ORBE_SOCK`/`ORBE_PANE`/`ORBE_REPORT_BIN` 注入と同じ機構）。libghostty は各ペインの PATH に `.app` の実行体 dir を無条件で append するが、CLI は別名 `orb` なので **PATH 順序に依存せず必ず同梱 CLI に解決する**。これにより Orbe が生成した任意ペイン（リポジトリ外 cwd・分割で生じたペイン含む）で `orb` が当該インスタンスの socket に届く。global install や symlink は行わない。

実体は `Sources/orbe-cli/`。設定適用の共有経路は設定パレットと共用（[settings-palette](settings-palette.md)）。
