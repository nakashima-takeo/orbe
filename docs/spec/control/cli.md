---
title: Orbe CLI（orb）
description: ペイン内・外から Orbe 自身の設定/ワークスペース/pane/tab/エージェントを操作する `orb` CLI。config/ws/pane/tab/agent（spawn・resume・prompt）/wait サブコマンド・socket 文脈解決・終了コード契約
updated: 2026-09-05
---

# Orbe CLI（`orb`）

ユーザー/AI がペイン内・外から Orbe 自身を構成・操作する CLI。[制御 API](api.md) の control.sock を直に叩く薄い socket クライアント（GhosttyKit/AppKit 非依存・Foundation のみ）。**PATH 上のコマンド名は `orb`**——`.app` の GUI 実行体 `Orbe` と別名にしてあるのは、`Orbe` と打つと GUI 本体が起動してしまうため。設定変更は GUI 設定パレット（[settings](../palette/settings.md)）と同一の適用経路を control 越しに使う。

## サーフェス

### 設定・ワークスペース（インスタンス/WS 単位。ペイン非依存）

- `orb config list [--workspace [<id|current>]] [--json]` … 設定の現在値・scope・domain。
- `orb config get <key> [--workspace [<id|current>]] [--json]` … 単一設定（クライアントが list から抽出）。
- `orb config set <key> <value> [--workspace [<id|current>]]` … 設定適用。`key` は設定パレットと同じ安定 kebab key。値型は key ごと（数値／真偽〔`true/false/on/off/1/0`〕／文字列／map〔`agent-state-icons`・カスタム音源の 2 件。CLI からは設定できず、設定パレットから入れる。`unset` は効く〕）。全設定が `--workspace` で上書き可。
- `orb config unset <key> [--workspace [<id|current>]]` … 上書きを解除して継承へ戻す。`--workspace` 省略は global 明示値の除去、指定はその WS 上書きの解除。
  - `--workspace` の値: フラグのみ＝アクティブ WS、`<id|current>` 指定＝**その WS**（非アクティブ可）。無指定は `set`/`unset` が global を書き、`list`/`get` はアクティブ WS の上書きを重ねた実効値を読む。
  - フラグを取り切った残余が位置引数の席に収まらなければ usage エラー（exit 2）。`--workspace=<id>`（= 区切り）・綴り誤り・2 個目の `--workspace`・席から溢れたトークン（`config set <key> <value> <余り>`）はここで落ちる——黙って捨てると exit 0 のまま指定と違う WS を触ることになる。`-` 始まりを値として通す席は `config set <key> <value>` の `<value>` だけで（`config set font-size -1`）、`<key>` の席は通さない。
- `orb ws list [--json]` / `ws new <name> [--dir <path>]` / `ws rename <id|current> <name>` / `ws dir <id|current> <path>` / `ws switch <id>` / `ws rm <id|current>`
  - `--workspace` は取らない（対象は位置引数の `<id|current>`）。フラグを取り切った残余が位置引数の席に収まらなければ usage エラー（exit 2）。位置引数（`<name>`・`<id|current>`・`<path>`）はいずれも `-` 始まりを取らないので、pane/tab と同じく**位置引数の席にも例外を設けない**。黙って捨てると `ws new <name> --dir=<path>` も `ws new <name> <path>`（`--dir` の書き忘れ）も、既定 root の workspace を exit 0 で作ってしまう。

### pane/tab（レイアウト操作）

ペイン内は `ORBE_PANE` を現ペイン既定に、外部は明示ターゲット必須。

- `orb pane list [--workspace <id|current>] [--json]` … pane 一覧（paneId/workspaceId/tabId/title/cwd/agentState/focused）。
- `orb pane split [<pane>] [-v|-h]` … 分割（`-v`＝左右〔縦線・既定〕、`-h`＝上下）。新 paneId を返す。
- `orb pane close [<pane>]` … GUI の Cmd+W と同一カスケード（最後の pane→tab→アクティブ WS の最後のタブは 0 タブ空状態で残す）。
- `orb pane focus <pane>` … 別 WS なら activate 込み。位置引数必須。
- `orb pane text [<pane>] [--scrollback] [--json]` … 画面テキスト。`--scrollback` で履歴全体、既定は可視範囲。人間向け出力は**捕捉した画面をそのまま**書き、末尾改行を足さない——整形された報告ではなく中身なので、`orb pane text > snapshot.txt` が画面を再現できる必要がある。
- `orb pane send [<pane>] (--text <text> | --stdin)` … ペースト相当でテキストを送る。**enter は押さない**（実行は `pane key --key enter` が担う。送信と実行を分けるのは、送った内容を確かめてから走らせられるようにするため）。`--text` と `--stdin` はちょうど一方が必須で、`--stdin` を明示必須にしたのは、引数を書き損じたときに CLI が黙って標準入力を待って固まらないため。
- `orb pane key [<pane>] --key <key>` … 名前付きキー 1 打。キー名の語彙は control が持ち、CLI は弾かない（`--help` の一覧は人が読むための写しで、ドリフトはテストが落とす）。
- `orb tab new [--workspace <id|current>] [--cmd "…"] [--dir <path>]` / `orb tab close [<tab>]`
  - `--workspace` を取るのは `pane list` と `tab new` だけ（値必須。bare は usage エラー）。他の pane/tab コマンドは取らない。
  - フラグを取り切った残余が位置引数の席に収まらなければ usage エラー（exit 2）。pane/tab の id は常に正なので、config 系と違い**位置引数の席にも例外を設けない**（先頭から検査する）。黙って捨てると `ORBE_PANE` 既定へ落ち、`pane close`/`tab close` では指定と無関係な現ペイン・現タブが exit 0 のまま消えてしまう。`tab new <path>`（`--dir` の書き忘れ）はアクティブ WS の既定 cwd にタブを開く。

### エージェント（起動・再開・対話）

- `orb agent list [--json]` … 検出済みエージェント CLI の command と絶対パス。検出ゼロはエラーではなく空の結果。
- `orb agent spawn [<agent>] [--workspace <id|current>] [--dir <path>] [--timeout-ms <ms>] [--json]` … 新タブでエージェントを起こし、**準備できるまで待つ**。`<agent>` 省略は**対象 workspace の**実効 `default-agent`。
- `orb agent resume <agent> <session-id> [--workspace <id|current>] [--dir <path>] [--timeout-ms <ms>] [--json]` … 既存セッションを継いで起こす。`<session-id>` の出所は `orb pane list --json` の `agentSessionId`。
- `orb agent prompt <pane> (--text <text> | --stdin) [--timeout-ms <ms>] [--json]` … エージェントに問うて答えを待つ。テキストを送って enter を押し、その後に初めてターンが止まった状態で返る。`<pane>` は必須で `ORBE_PANE` に落ちない（自ペインのエージェントに問う形は無い）。`--text` / `--stdin` の規則は `pane send` と同じ。

いずれも GUI の起動（⌘⇧A / ⌘⇧C）と**同じタブ生成経路**を通る。CLI と GUI で起動のされ方が割れると、その差は「GUI からは動くが CLI からは動かない」という遠い形で出るため、経路を分けない。

`--workspace` でその workspace にタブを開けるが、**前面化はしない**——見ている画面を CLI が勝手に奪わないため。前面化は `orb pane focus` が明示的に担う。開いたペインは前面化を待たずに `pane text` / `pane send` / `pane key` が効く。

`spawn` は解決済みの絶対パスを起動し、`resume` はエージェント自身の再開コマンド形を注入済み PATH に解決させる（永続復元の resume と同じ形）。どちらも既定で「準備できた」（起動後の最初の `idle` 報告）まで待つ——待てるのは起動時に報告する agent（claude）だけで、報告しない agent（codex / agy）は待たず即返る。人間向け出力は準備できたときだけ行末に ` ready (session <id>)` を添え、`--json` は `ready` / `agentSessionId` / `timedOut` で区別できる（[api](api.md)）。既定 timeout は 30 秒で、時間切れは exit 124 だがタブは開いている（`--json` は paneId を含む result を stdout に出し、人間向けは spawned 行を stdout・`timed out` を stderr に書く）。

`prompt` は「入力欄が空いている状態にだけ届く」動詞で、対象が `working` / `waiting` なら何も送らずエラー（exit 1）——`waiting` へのテキスト送信は承認の確定になるため。waiting への応答は `pane key` で行う。既定 timeout は 1 時間。人間向け stdout は**答えの文言だけ**（`done` の最終応答・`waiting` の質問文。無ければ空）で、`answer=$(orb agent prompt …)` の形で受けられる。止まった状態は終了コードで伝える（下記）。

### 待機

- `orb wait [<pane>] [--kind <kind>]... [--value <value>] [--after <seq>] [--timeout-ms <ms>] [--json]` … 状態変化イベントを待つ低水準の口。`--kind` は繰り返せ、省略は全 kind。`--value` は kind 固有値の一致（`--kind agent_state --value done` 等）。`--after` は「この seq より後」（0 以上）で、既に済んだ一致があれば待たずに返る。既定 timeout は 30 秒。

`<pane>` を省略すると**全 pane** を監視する。pane 系コマンドと違い `ORBE_PANE` に落ちない——`wait` は pane ドメインの外にあるトップレベル動詞であり、ペイン内で走らせたスクリプトが黙って自ペインだけを見る形になると、同じコマンドが環境によって違う意味になるため。自ペインを待つなら `orb wait $ORBE_PANE` と明示する。

`--after` に渡す seq は `orb pane list --json` や書き込み系の `--json` 応答から取る（[api](api.md)）。`pane send --json` の `seq` を `wait --after` に渡せば、送信と待機の隙間に済んだ変化を取りこぼさず、前ターンの古いイベントも掴まない。エージェントに問うて答えを待つだけなら `agent prompt` が seq を隠して同じことをする。

kind の語彙と値域の検証は control が持つ（未知 kind は CLI を素通りして control が弾く）。人間向け出力行は `kind\tpane\tvalue`。`agent_state` のイベントは状態語に加えて遷移時点の文言と session id を運び、`--json` でそのまま読める。

### 共通

各サブコマンドは対応する [制御 API](api.md) メソッドへそのまま乗る。`--json` は全サブコマンドで効き、control の result をそのまま出す——成功応答に載る `seq`（[api](api.md)）もそのまま出る（例外は 2 つ——`config get` は `config_list` から抽出した 1 行で `seq` を持たない、`pane list` は `--workspace` で絞った後の `{"panes":[…], "seq": N}`）。write が採番した id（`ws new` の workspaceId・`tab new` / `pane split` の paneId）は人間向け出力にも載るが、書式が割れずに読めるのは `--json` だけ。`--help` は全階層で効き、固有 usage を持つのは `config set` と `pane split`、他はドメインの usage を出す（`pane split` の `-h` は上下分割フラグであって help ではない。help は `--help` のみ）。`<id|current>` の `current` はアクティブ WS。

値必須フラグ（`--workspace <id>` / `--dir <path>` / `--cmd "…"` / `--text <text>` / `--key <key>` / `--kind <kind>` / `--value <value>` / `--after <seq>` / `--timeout-ms <ms>`）の値は `-` 始まりも空（空白だけの形も含む）も取らない（usage エラー、exit 2）。`orb tab new --dir "$DIR" --cmd "$CMD"` の `$DIR` が空になる形が両方ここで落ちる——引用符が無ければトークンごと消えて `--cmd` が cwd に化け、引用符があれば空文字が cwd として通ってしまうため。パスは絶対パスで渡す（`-` 始まりのディレクトリは `./-foo` の形）——相対パスは CLI も control も解決せずそのまま格納するので、利用者のシェルの cwd 基準にはならない。`~` 始まりを展開するのは workspace のパス（`ws new --dir` / `ws dir`）だけで、`tab new --dir` は展開せずそのまま cwd にする。

この規約が禁じる形のテキスト——`-` 始まり・空・空白だけ——をペインへ送りたいときは `pane send --stdin` を使う。標準入力は席ではないので規約の対象外で、0 バイトだけを usage エラーにする。`printf '%s' "$PROMPT" | orb pane send --stdin` の `$PROMPT` 未設定が 0 バイトとして現れる形は規約が守ろうとしているものと同じだが、ファイルや heredoc の中身が空白・改行だけであることは正当にあり得るためこの線を引く。

## 文脈解決

control.sock の解決順は `ORBE_STATE_DIR`（非空の明示指定・最優先。`$ORBE_STATE_DIR/control.sock` を使い `ORBE_SOCK` は見ない）→ `ORBE_SOCK`（ペイン注入の絶対パス）→ 既定の Application Support 直下（自ビルドのチャネルが焼いた bundle id・[channel](../platform/channel.md)）。pane/tab は現ペイン既定に `ORBE_PANE`（ペイン注入の自 pane id）を読む。config/ws はインスタンス/WS 単位なので `ORBE_PANE` を読まない。外部（`ORBE_PANE` 無し）で pane/tab の対象を省略すると usage エラー（exit 2）。

## 終了コード・エラー

- 成功=0、usage エラー（未知 key・引数不足・非数値 id・対象欠如等でクライアントが弾く）=2、RPC/接続エラー=1、`agent prompt` がエージェントの入力待ち（`waiting`）で止まった=3、同じくセッション終了（`clear`）で止まった=4、`wait` / `agent prompt` / `agent spawn` / `agent resume` の時間切れ=124。
- 時間切れに専用コードを与えるのは、待っていたイベントが来ていないのに `orb wait … && 次の処理` が進むのを止めるため——この CLI は成功していないのに 0 を返さない。124 は `timeout(1)` の慣習で、Orbe の文書を読まなくても意味が通る。時間切れは `--json` なら結果を stdout に出すが、それ以外では stdout に何も書かない（`text=$(orb wait …)` が偽のイベントを掴まないため）。`agent prompt` の 3 / 4 も同じ理由で非 0——答えは返っていないので `&& 次の処理` を進めない。3 と 4 を分けるのは対処が違うため（3 は答えを送る、4 は起こし直す）。
- Orbe 未起動や Orbe 外（socket 不達）は、クラッシュせず構造化メッセージ＋非 0 終了（`--json` 時は `{"error":{code,message}}`）。
- control の error は code/message をそのまま出す（値域外・不正 enum・未知/最後の workspace・未知 pane/tab 等は control 側が弾く）。未知 key・型不一致はクライアントが `config_list` を SSOT に事前に弾く。

## 配布・PATH

ビルド成果物を `build-app.sh` が `.app/Contents/Resources/bin/orb` へ同梱し、ad-hoc 署名に含める。`SurfaceView` が**全ペイン（root・split とも）**の生成時にこの bin dir をペイン `PATH` の先頭へ前置する（`ORBE_SOCK`/`ORBE_PANE`/`ORBE_REPORT_BIN` 注入と同じ機構）。libghostty は各ペインの PATH に `.app` の実行体 dir を無条件で append するが、CLI は別名 `orb` なので **PATH 順序に依存せず必ず同梱 CLI に解決する**。これにより Orbe が生成した任意ペイン（リポジトリ外 cwd・分割で生じたペイン含む）で `orb` が当該インスタンスの socket に届く。global install や symlink は行わない。

実体は `Sources/orbe-cli/`。設定適用の共有経路は設定パレットと共用する（[settings](../palette/settings.md)）。
