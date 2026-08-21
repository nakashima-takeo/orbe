---
title: 制御 API（外部 → Orbe）
description: Unix socket 上の JSON-RPC でペイン/タブ/workspace/エージェントを操作する out-of-band 制御チャネルと、MCP ブリッジ・ツール群・mount 境界
updated: 2026-08-21
---

# 制御 API（外部 → Orbe）

外部やエージェントが Orbe 全体を操作するための out-of-band 制御チャネル。「人とエージェントが同じターミナルを扱える」の、エージェント側の入口がここ。エージェント状態報告（[agent/notify](../agent/notify.md) の `report_agent`）もこのチャネルに集約する。

## トランスポート

Unix domain socket `control.sock`（workspaces.json と並置・パーミッション 0600）。置き場は `StateDir` が一元解決し、`ORBE_STATE_DIR`（非空）設定時はその dir 直下（検証用の隔離インスタンス。[persistence](../platform/persistence.md) と同じ解決）。プロトコルは改行区切り JSON-RPC 2.0。プロセスに 1 つで、起動は `applicationDidFinishLaunching`・終了で socket を unlink する。accept/受信/行分割/応答/イベント配信/timeout は専用シリアルキュー 1 本上で直列実行し、domain 操作は main へ hop する（libghostty surface API と AppKit は main 規律）。AF_UNIX の sun_path 長上限を超えるパスでは無効化される。

接続 fd は accept 後に非ブロッキング化し、I/O がキューをブロックしない——詰まった 1 接続が accept・他接続・event 配信・timeout を巻き添えにしないため。送信は per-connection 出力バッファ経由で、書込不可は書込可能まで待機・EINTR はリトライ・EPIPE 等は切断。出力滞留が上限を超えた接続は切断する。受信は改行が来ないまま 1 行が上限を超えた接続を切断する（メモリ枯渇防止）。

## エラー

失敗は `error.code` で伝える。この語彙は `swift test` が実 `Connection` 上で 1 対 1 に固定する。

- `-32700` 行が JSON テキストとして読めない（壊れた JSON・不正 UTF-8・最上位スカラ）。`id` は null。
- `-32600` JSON だがリクエストオブジェクトでない（配列・`method` 欠落）。`id` は取れれば返す。
- `-32601` 未知の method。
- `-32602` params の欠落・型不一致・値域外。
- `-32004` 宛先（pane / tab / workspace）が見つからない。宛先 ID を解決へ直に渡すメソッド（`get_pane_text` / `send_text` / `send_key` / `report_agent` / `completion_accept`）は `paneId` の欠落・型不一致もここに落ちる（解決の前に検証を挟むメソッドは `-32602`）。
- `-32005` 1 接続に 2 件目の `wait_for_event`。
- `-32000` 実行できない（ウィンドウ未接続・spawn 失敗・最後の workspace 削除・分割不可）。

無応答契約を持つのは `completion_update` / `completion_end` の 2 つだけで、他は必ず 1 行応答を返す——読めない行にも返すことで、クライアントが応答待ちでハングしない。

## 宛先 ID

workspace / tab / pane にプロセス内単調増加 ID。型をまたいで一意。セッション内のみ有効（永続しない・再起動で振り直し）。配列インデックスでなく ID で指す。

## ツール

JSON-RPC メソッド = MCP ツール名の 1:1。ただし `report_agent`・`config_*`・workspace CRUD・`split_pane`/`close_pane`/`focus_pane`/`close_tab`・`completion_*` は socket 専用で、MCP ブリッジには出さない（[cli](cli.md) が直に叩く）。

- `list_workspaces` → `{workspaces:[…]}` … id・name・rootPath・active・tabCount・activated・dormantAgentCount。`activated` は配下にmaterialize開始済みタブが1枚以上あるかを表す現在値で、0タブまたは全タブ未activatedならfalse。`dormantAgentCount` は現在残る未消費の復元チケット（休眠agent）ペイン数で、混在workspaceでは `activated: true` と正の値が同時に成立する。0タブworkspaceを前面化した場合は `active: true, activated: false, dormantAgentCount: 0` となる。
- `list_panes` → `{panes:[…]}` … paneId・workspaceId・tabId・workspaceName・title・cwd・agentState・agentSessionId（resume 用・未設定なら null）・focused（全 workspace 横断・ツリー順）。
- `list_agents` → `{agents:[…]}` … 検出済みエージェント CLI の command と解決済み絶対 path を列挙する（読み取り専用）。アプリ保持の検出結果をそのまま返し、新規検出（login shell 起動）は起こさない。検出未完了でもエラーにせず**空配列を返す**。`spawn_agent` / `resume_agent` に渡す command の候補源。
- `get_pane_text {paneId, scrollback?}` → `{text}` … 画面テキスト平文。scrollback 真で履歴全体、偽で可視範囲。
- `send_text {paneId, text}` … ペースト相当で PTY へ書く。bracketed paste 下では改行を含めても**自己実行せず**プロンプトに留まる。コマンド実行は別途 `send_key` の enter。
- `send_key {paneId, key}` … 名前付きキー（case-insensitive）。特殊キー（enter/tab/escape/space/backspace/delete/上下左右/home/end/pageup/pagedown）は仮想 keycode で press+release を送り、libghostty にモード対応エンコードさせる（application cursor mode 等に追従。修飾も渡すため `ctrl+enter`・`shift+tab` 等が有効）。単一文字の修飾はモード非依存バイトに畳む——`ctrl+<char>` は C0 制御（レンジ外は拒否）、`alt`/`meta`/`option+<char>` は ESC プレフィックス。端末バイト表現を持たない `cmd`/`super` 付き単一文字と未知修飾は `-32602` で拒否する——修飾を黙殺して素の文字を注入しないため（ただし単一文字の `shift` は畳む先が無くビットが落ちる＝`shift+a` は `a`）。
- `spawn {workspaceId?, cwd?, command?}` … 新タブを開く。command 省略はシェル・指定はそれを直接起動。cwd 省略は GUI の新規タブと同じフォールバック（対象 workspace のペイン cwd → その workspace の rootPath）。戻り値は新ペイン ID。workspaceId が未知ならエラーにせずアクティブ workspace へフォールバックする。
- `spawn_agent {command?, workspaceId?, cwd?}` / `resume_agent {command, sessionId, workspaceId?, cwd?}` → `{paneId, tabId, workspaceId, agent:{command, path}}` … 検出済みエージェントを新タブで起こす。`spawn` との違いは、**GUI の起動（⌘⇧A / ⌘⇧C）と同じ組成**——検出済みの絶対パスを使い、子プロセス PATH を注入する（[agent/launch](../agent/launch.md)）。`command` を渡さない `spawn_agent` は**対象 workspace の**実効 `default-agent` を解く（アクティブ WS ではない）。`resume_agent` はエージェント自身の再開コマンド形を組み立て、セッション ID の文字集合もそこで検証する。未検出 command は `-32602`、解決できるエージェントが無ければ `-32000`。**未知 workspaceId は `-32004`**——`spawn` のフォールバックを継がないのは、新しい入口が「指定と違う対象を黙って触る」振る舞いを引き継ぐ理由がないため。実セッション ID は返さない（`spawn` 時点では存在せず、`resume` では入力の反響でしかない）。取得口は `list_panes` の `agentSessionId` 一つ。
- `activate_workspace {workspaceId}` → `{activeWorkspaceId, paneIds}` … 背景/休眠 workspace を前面化し全タブを mount する。0 タブ WS は GUI どおり空状態（シェルは自動起動しない・paneIds 空）。未知 id は `-32004`（spawn と違いフォールバックしない）、workspaceId 欠落は `-32602`。既にアクティブな WS への activate は no-op で成功（冪等）。手元 Mac のアクティブ workspace も実際に切り替わる。
- `config_list {workspaceId?}` → `{settings:[{key, value, scope, type, domain}]}` … 全設定の実効値（global＋当該 WS 上書き＋既定を畳んだ値）・由来 scope（`global`/`workspace`/`default`）・型・ドメイン（stepper の範囲、bool/enum の候補、フォント名一覧、`tab-title-font-family` は開いた列挙〔候補は空提示・任意文字列受理〕、`default-agent` は検出済み command、`agent-state-icons` は状態別 curated symbols）を返す。設定レジストリ走査の generic 1 実装。`workspaceId` 省略はアクティブ WS（未知 id は `-32004`）。読み取り専用。socket 専用。
- `config_set {key, value, scope, workspaceId?}` → `{ok, key, value, scope}` … 設定を適用する（設定パレットと同一経路）。**全設定**が `scope` ∈ {global, workspace}。workspace は `workspaceId` 省略でアクティブ WS、指定でその WS（非アクティブ可・未知 id は `-32004`）の上書き層へ書く。**保存は常に、ライブ反映は global か対象がアクティブ WS の時だけ**（非アクティブ WS 上書きは次回 activate 時に効く）。値検証はレジストリの domain 駆動＝唯一の検証点で、`value: null` は「解除（継承へ戻す）」として受理する。未知 key・型不一致・値域外・不正 enum は `-32602`。socket 専用。
- `create_workspace {name, rootPath?}` → `{workspaceId, name, rootPath}` … `name` 空（trim 後）は `-32602`。`rootPath` を渡してそれが空（trim 後）も `-32602`（省略はアクティブペイン cwd → ホーム導出。`~` 展開あり）。socket 専用。
- `rename_workspace {workspaceId, name}` … 未知 id は `-32004`、`name` 空は `-32602`。socket 専用。
- `set_workspace_root {workspaceId, rootPath}` … GUI パレットのディレクトリ変更と同一経路（trim・`~` 展開・実在チェックなし・アクティブなら chrome 即時更新・永続化）。未知 id は `-32004`、空は `-32602`。socket 専用。
- `remove_workspace {workspaceId}` … 未知 id は `-32004`。最後の 1 つは削除不可で `-32000`（[workspace](../platform/workspace.md) の「最低 1 枚を残す」規律）。socket 専用。
- `split_pane {paneId, direction, command?}` → `{paneId}` … `direction` ∈ {`right`, `down`}。command 省略は素シェル・指定はそのコマンド（cwd 等は分割元から継承）。未知 pane は `-32004`、direction 不正は `-32602`、分割不可（未 mount 等）は `-32000`。socket 専用。
- `close_pane {paneId}` … カスケードは GUI（Cmd+W）と同一——最後の pane→tab のカスケードで、アクティブ workspace の最後のタブを閉じても 0 タブの空状態でアクティブに残る（ウィンドウは閉じない）。teardown は main 遅延で走るため応答を先に返す（自己 close も安全）。未知 pane は `-32004`。socket 専用。
- `focus_pane {paneId}` … 別 workspace のペインなら activate を伴う（手元 Mac のアクティブ workspace も切り替わる）。冪等。未知 pane は `-32004`。socket 専用。
- `close_tab {tabId}` … close_pane と同じカスケード規律。未知 tab は `-32004`。socket 専用。
- `report_agent {paneId, agent, state, sessionId?, message?, messageSource?}` … エージェント hook の状態報告を発信元ペインへ適用する（[agent/notify](../agent/notify.md)）。`messageSource` は文言の出所で、ツール由来かどうかだけが上書き可否を決める（表示には出ない）。`state=="clear"` で状態/コマンド/セッション ID/文言/状態変化時刻を消し、それ以外は state/command を立て、sessionId は新値があれば更新・無ければ同じ CLI からの報告のあいだだけ引き継ぎ（command が変われば捨てる）、文言は state の遷移と出所で上書き可否が決まる（状態変化時刻は state が実際に変わったときだけ進む）。**未消費（休眠）の復元ペイン宛の報告・clear は破棄する**（[agent/notify](../agent/notify.md)）。
- `wait_for_event {paneId?, kinds?, timeoutMs?}` … 状態変化を長ポーリングで待つ。kind ∈ {agent_state, pane_title, pwd, pane_closed}。`event.value` は kind 固有（`agent_state` が運ぶのは状態語で、セッション ID ではない）。フィルタ一致で {event}、timeout 超過で {timedOut:true}。1 接続あたり待機 1 件（2 件目は `-32005` で即拒否）。**params は待機を張る前に検証する**——未知 kind・空 kinds・型違いの paneId・値域外の timeoutMs はいずれも `-32602`。黙って通すと「永久に一致せずただ時間切れ」「絞り込みが外れて別ペインのイベントを掴む」という、呼び出し側から何も起きなかったのと区別できない形になるため。timeoutMs に上限を置くのも同じ理由で、際限なく大きな値は待機の期限が事実上訪れなくなり、1 件しかない待機枠を握ったまま応答が返らなくなる。
- `completion_update` / `completion_end` / `completion_accept` … コマンド補完用（[completion](../palette/completion.md)）。前 2 つは**無応答**。`completion_` 系は宛先解決ガードより前で分岐し、無応答メソッドは宛先不在でも応答を出さない（打鍵ごとの update が accept fd に行を積まない）。読めない行にはこの分岐より前でエラー行を返すため、accept fd から読める行が accept 応答だけとは限らない——クライアントは `id` で自分の応答を選ぶ（[completion](../palette/completion.md)）。socket 専用。

## 境界

- get_pane_text / send_text / send_key は **mount 済み（surface 生存）ペインにのみ作用**する。条件は surface が生きていることであって、そのペインが見えていることではない。未 mount ペインは get_pane_text が空・send 系は no-op。
- **制御 API がタブを作るとき（`spawn` / `spawn_agent` / `resume_agent`）は、対象が背景 workspace でもその場で surface を起こす**——前面化はせず、実サイズで起こす。作れと言われた 1 枚をすぐ駆動できないと、返した paneId が「読めず届かない ID」になるため。前面化したいときは `focus_pane` / `activate_workspace` が明示的に担う。
- 背景workspaceで明示的に作成したタブは、その1枚だけをactivatedにするため、owner workspaceのcomputedな `activated` もtrueになる。ただし `activeWorkspace`・表示タブ・focus・MRUは変えず、同じworkspaceの既存復元タブは未materializeのまま残る。作成したタブの状態報告はAttention一覧・メニューバーのピル・通知音へ即時に出る一方、未activatedタブへ直接注入された報告は注意喚起とlive集計へ出さない。`wait_for_event` は表示集合に関係なくイベント自体を扱う。
- 既存タブの mount は従来どおり workspace 単位の keep-alive 遅延（[workspace](../platform/workspace.md)）。永続復元直後はアクティブ workspace の**全タブ**が mount され、背景 workspace のタブは ID を持つが surface 未生成で、`activate_workspace` で前面化すれば読めるようになる。復元で休眠 workspace のシェルを一斉に起こさないための遅延であり、明示的に 1 枚作れという要求には及ばない。
- `wait_for_event` が扱うのは libghostty が host に出す OSC 由来シグナル（[libghostty](../terminal/libghostty.md)）とペイン破棄のみ。**生の PTY 出力は待てない**（コマンド完了待ちは agent_state=done か get_pane_text ポーリングで代替する）。

## libghostty 経路

テキスト注入・キー注入・テキスト取得は libghostty の C API を直に呼ぶ。イベント源はペインの paneTitle・currentPwd・agentState の変化と破棄（pane_closed）で、これが socket 待機者（`wait_for_event`）へ配信される。

## MCP ブリッジ

`orbe-mcp` 実行ターゲット（GhosttyKit/AppKit 非依存）。MCP stdio を喋りツール定義を保持し、tools/call を control.sock へ転送する薄い層——ツールの反復に Orbe 本体の再ビルド/再起動が要らない。`.mcp.json` の `Orbe` サーバは起動スクリプトが毎回 `swift build` を通してから exec する（stale バイナリが別チャネルの socket を掴まないため・[channel](../platform/channel.md)）。接続先 control.sock は app と同じ規則で `ORBE_STATE_DIR` を honor するため、隔離インスタンスと bridge を同じ `ORBE_STATE_DIR` で起こせば、その隔離インスタンスを MCP で駆動できる。

## 開発検証

制御 API の導通は `swift test` の L4（プロセス境界）が担う。テストプロセス内に実 `WindowController` を target とした `ControlServer` を立て、外部プロセスの `orbe-mcp` / `orb` / `orbe-report` から駆動して assert する。「ペインで実際に実行された」ことは、コマンド行の中で 2 つのリテラルに割った目印（`echo L4D""ONE_<id>`）を送り、連結された `L4DONE_<id>` が `get_pane_text` に現れるまでポーリングして見る——連結形はシェルが引用符除去を評価した出力にしか現れないので、プロンプトの描画挙動に依らない。`.app` の起動経路と `AppDelegate` の配線はその外側で、隔離した使い捨てインスタンスを起こす `sandbox-run`（`.claude/skills/`）が同じ形の煙探知を通す。再起動の orchestration も制御 API の外側に置く——socket はアプリと心中するため、自己再起動は循環になる。

CLI は `orbe-mcp`（MCP ブリッジ）・`orbe-report`（状態報告）・`orb`（ユーザー/AI 向け操作 CLI・[cli](cli.md)）。`.app` に同梱されるのは `orbe-report` と `orb` で、`orbe-mcp` は同梱せず `.mcp.json` の起動スクリプトがビルドして exec する。
