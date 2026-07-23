---
title: 制御 API（外部 → Orbe・現状）
description: Unix socket 上の JSON-RPC でペイン/タブ/workspace を操作する out-of-band 制御チャネルと MCP ブリッジ・ツール群・libghostty 経路・mount 境界
updated: 2026-07-23
---

外部やエージェントが Orbe 全体を操作する out-of-band 制御チャネル。エージェント状態報告（[agent-notify](agent-notify.md) の `report_agent`）もこのチャネルに集約する。

## トランスポート
Unix domain socket `control.sock`（workspaces.json と並置・パーミッション 0600）。置き場は `StateDir` が一元解決し、`ORBE_STATE_DIR`（非空）設定時はその dir 直下（検証用の隔離インスタンス。[persistence](persistence.md) と同じ解決）。改行区切り JSON-RPC 2.0。プロセスに 1 つ、起動は `applicationDidFinishLaunching`・終了で socket を unlink。accept/受信/行分割/応答/イベント配信/timeout は専用シリアルキュー 1 本上で直列実行、domain 操作は main へ hop（libghostty surface API と AppKit は main 規律）。AF_UNIX の sun_path 長上限を超えるパスでは無効化。

接続 fd は accept 後に非ブロッキング化し、I/O がキューをブロックしない（詰まった 1 接続が accept・他接続・event 配信・timeout を巻き添えにしない）。送信は per-connection 出力バッファ経由で、書込不可は書込可能まで待機・EINTR はリトライ・EPIPE 等は切断。出力滞留が上限を超えた接続は切断する。受信は改行が来ないまま 1 行が上限を超えた接続を切断する（メモリ枯渇防止）。

## 宛先 ID
workspace / tab / pane にプロセス内単調増加 ID。型をまたいで一意。セッション内のみ有効（永続しない・再起動で振り直し）。配列インデックスでなく ID で指す。

## ツール（JSON-RPC メソッド = MCP ツール名、1:1。ただし `report_agent`・`config_*`・workspace CRUD・`split_pane`/`close_pane`/`focus_pane`/`close_tab`・`completion_*` は socket 専用で MCP ブリッジには出さない〔[orbe-cli](orbe-cli.md) が直に叩く〕）
- `list_workspaces` … id・name・rootPath・active・tabCount・activated・dormantAgentCount（休眠 agent 数＝永続復元した agent 付き leaf 数。休眠 workspace は `list_panes` に出ないため別途この永続カウントで露出する。活性 workspace は live 側で数えるため常に 0）。
- `list_panes` … paneId・workspaceId・tabId・workspaceName・title・cwd・agentState・agentSessionId（resume 用・未設定なら null）・focused（全 workspace 横断・ツリー順）。
- `list_agents` … 検出済みエージェント CLI の command と解決済み絶対 path を列挙する（読み取り専用）。アプリ保持の検出結果をそのまま返し、新規検出（login shell 起動）は起こさない。検出未完了でもエラーにせず**空配列を返す**。
- `get_pane_text {paneId, scrollback?}` … 画面テキスト平文。scrollback 真で履歴全体、偽で可視範囲。
- `send_text {paneId, text}` … ペースト相当で PTY へ書く。bracketed paste 下では改行を含めても**自己実行せず**プロンプトに留まる。コマンド実行は別途 `send_key` の enter。
- `send_key {paneId, key}` … 名前付きキー（case-insensitive）。特殊キー（enter/tab/escape/space/backspace/delete/上下左右/home/end/pageup/pagedown）は仮想 keycode で press+release を送り libghostty にモード対応エンコードさせる（application cursor mode 等に追従。修飾も渡すため `ctrl+enter`・`shift+tab` 等が有効）。単一文字の修飾はモード非依存バイトに畳む——`ctrl+<char>` は C0 制御（レンジ外は拒否）、`alt`/`meta`/`option+<char>` は ESC プレフィックス。端末バイト表現を持たない `cmd`/`super` 付き単一文字と未知修飾は `-32602` で拒否する（修飾を黙殺して素の文字を注入しない。ただし単一文字の `shift` は畳む先が無くビットが落ちる＝`shift+a` は `a`）。
- `spawn {workspaceId?, cwd?, command?}` … 新タブを開く。command 省略はシェル・指定はそれを直接起動。cwd 省略は GUI の新規タブと同じフォールバック（対象 workspace のペイン cwd → その workspace の rootPath）。戻り値は新ペイン ID。アクティブ workspace 指定時は即 mount、背景 workspace は keep-alive で遅延。workspaceId が未知ならエラーにせずアクティブ workspace へフォールバック。
- `activate_workspace {workspaceId}` → `{activeWorkspaceId, paneIds}` … 背景/休眠 workspace を前面化し全タブを mount する。0タブ WS は GUI どおり空状態（シェルは自動起動しない・paneIds 空）。未知 id は `-32004`（spawn と違いフォールバックしない）、workspaceId 欠落は `-32602`。既にアクティブな WS への activate は no-op で成功（冪等）。手元 Mac のアクティブ workspace も実際に切り替わる。
- `config_list {workspaceId?}` → `{settings:[{key, value, scope, type, domain}]}` … 全設定の実効値（global＋当該 WS 上書き＋既定を畳んだ値）・由来 scope（`global`/`workspace`/`default`）・型・ドメイン（stepper の範囲、bool/enum の候補、フォント名一覧、`tab-title-font-family` は開いた列挙〔候補は空提示・任意文字列受理〕、`default-agent` は検出済み command、`agent-state-icons` は状態別 curated symbols）を返す。設定レジストリ走査の generic 1 実装。`workspaceId` 省略はアクティブ WS（未知 id は `-32004`）。読み取り専用。socket 専用。
- `config_set {key, value, scope, workspaceId?}` → `{ok, key, value, scope}` … 設定を適用する（設定パレットと同一経路）。**全設定**が `scope` ∈ {global, workspace}。workspace は `workspaceId` 省略でアクティブ WS、指定でその WS（非アクティブ可・未知 id は `-32004`）の上書き層へ書く。**保存は常に、ライブ反映は global か対象がアクティブ WS の時だけ**（非アクティブ WS 上書きは次回 activate 時に効く）。値検証はレジストリの domain 駆動＝唯一の検証点で、`value: null` は「解除（継承へ戻す）」として受理する。未知 key・型不一致・値域外・不正 enum は `-32602`。socket 専用。
- `create_workspace {name, rootPath?}` → `{workspaceId, name, rootPath}` … `name` 空（trim 後）は `-32602`。`rootPath` 省略はアクティブペイン cwd → ホーム導出（`~` 展開あり）。socket 専用。
- `rename_workspace {workspaceId, name}` … 未知 id は `-32004`、`name` 空は `-32602`。socket 専用。
- `set_workspace_root {workspaceId, rootPath}` … GUI パレットのディレクトリ変更と同一経路（trim・`~` 展開・実在チェックなし・アクティブなら chrome 即時更新・永続化）。未知 id は `-32004`、空は `-32602`。socket 専用。
- `remove_workspace {workspaceId}` … 未知 id は `-32004`。最後の 1 つは削除不可で `-32000`（[workspace](workspace.md) の「最低 1 枚を残す」規律）。socket 専用。
- `split_pane {paneId, direction, command?}` → `{paneId}` … `direction` ∈ {`right`, `down`}。command 省略は素シェル・指定はそのコマンド（cwd 等は分割元から継承）。未知 pane は `-32004`、direction 不正は `-32602`、分割不可（未 mount 等）は `-32000`。socket 専用。
- `close_pane {paneId}` … カスケードは GUI（Cmd+W）と同一——最後の pane→tab のカスケードで、アクティブ workspace の最後のタブを閉じても0タブの空状態でアクティブに残る（ウィンドウは閉じない）。teardown は main 遅延で走るため応答を先に返す（自己 close も安全）。未知 pane は `-32004`。socket 専用。
- `focus_pane {paneId}` … 別 workspace のペインなら activate を伴う（手元 Mac のアクティブ workspace も切り替わる）。冪等。未知 pane は `-32004`。socket 専用。
- `close_tab {tabId}` … close_pane と同じカスケード規律。未知 tab は `-32004`。socket 専用。
- `report_agent {paneId, agent, state, sessionId?}` … エージェント hook の状態報告を発信元ペインへ適用する（[agent-notify](agent-notify.md)）。`state=="clear"` で状態/コマンド/セッション ID を nil、それ以外は state/command を立て sessionId があれば更新。
- `wait_for_event {paneId?, kinds?, timeoutMs?}` … 状態変化を長ポーリングで待つ。kind ∈ {agent_state, pane_title, pwd, pane_closed}。`event.value` は kind 固有。フィルタ一致で {event}、timeout 超過で {timedOut:true}。1 接続あたり待機 1 件（2 件目は `-32005` で即拒否）。
- `completion_update` / `completion_end` / `completion_accept` … コマンド補完用（[completion](completion.md)）。前 2 つは**無応答**。`completion_` 系は宛先解決ガードより前で分岐し、無応答メソッドは宛先不在でも応答を出さない（accept fd の framing を保つ）。socket 専用。

## 境界
- get_pane_text / send_text / send_key は **mount 済み（surface 生存）ペインにのみ作用**する。永続復元直後はアクティブ workspace の**全タブ**が mount される。背景 workspace のタブは ID を持つが surface 未生成（[workspace](workspace.md) の workspace 単位 keep-alive 遅延 mount）。未 mount ペインは get_pane_text が空・send 系は no-op。`activate_workspace` で前面化すれば読めるようになる。
- `wait_for_event` が扱うのは libghostty が host に出す OSC 由来シグナル（[libghostty](libghostty.md)）とペイン破棄のみ。**生の PTY 出力は待てない**（コマンド完了待ちは agent_state=done か get_pane_text ポーリングで代替）。

## libghostty 経路
テキスト注入・キー注入・テキスト取得は libghostty の C API を直に呼ぶ。イベント源はペインの paneTitle・currentPwd・agentState の変化と破棄（pane_closed）で、これが socket 待機者（`wait_for_event`）へ配信される。

## MCP ブリッジ
`orbe-mcp` 実行ターゲット（GhosttyKit/AppKit 非依存）。MCP stdio を喋りツール定義を保持し、tools/call を control.sock へ転送する薄い層（ツール反復に Orbe 本体の再ビルド/再起動が不要）。`.mcp.json` の `Orbe` サーバは起動スクリプトが毎回 `swift build` を通してから exec する（stale バイナリが別チャネルの socket を掴まないため・[channel](channel.md)）。接続先 control.sock は app と同じ規則で `ORBE_STATE_DIR` を honor するため、隔離インスタンスと bridge を同じ `ORBE_STATE_DIR` で起こせばその隔離インスタンスを MCP で駆動できる。

## 開発検証
`scripts/dev-verify.sh` が .app 再ビルド→再起動→ソケット待ち→send_text＋send_key enter→get_pane_text の出現数ポーリングで「実際に実行された」ことを assert。再起動の orchestration は制御 API の外側（socket はアプリと心中するため自己再起動は循環になる）。

CLI は `orbe-mcp`（MCP ブリッジ）・`orbe-report`（状態報告）・`orb`（ユーザー/AI 向け操作 CLI・[orbe-cli](orbe-cli.md)）。`.app` に同梱されるのは `orbe-report` と `orb` で、`orbe-mcp` は同梱せず `.mcp.json` の起動スクリプトがビルドして exec する。
