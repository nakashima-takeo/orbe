---
title: 制御 API（外部 → Orbe）
description: Unix socket 上の JSON-RPC でタブ/workspace/エージェントを操作する out-of-band 制御チャネルと、イベント履歴（seq）・待機・MCP ブリッジ・ツール群・mount 境界
updated: 2026-09-06
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
- `-32004` 宛先（tab / workspace）が見つからない。宛先 ID を解決へ直に渡すメソッド（`get_tab_text` / `send_text` / `send_key` / `report_agent` / `completion_accept`）は `tabId` の欠落・型不一致もここに落ちる（解決の前に検証を挟むメソッドは `-32602`）。
- `-32006` `wait_for_event` の `after` が履歴の保持範囲より古い（対処は seq を取り直す。呼び出し側のバグである `-32602` と分ける）。
- `-32000` 実行できない（ウィンドウ未接続・spawn 失敗・最後の workspace 削除・`prompt_agent` の busy / 未 mount・ready 待ち中のエージェント消滅）。

無応答契約を持つのは `completion_update` / `completion_end` の 2 つだけで、他は必ず 1 行応答を返す——読めない行にも返すことで、クライアントが応答待ちでハングしない。

## 宛先 ID

workspace / tab にプロセス内単調増加 ID。型をまたいで一意。セッション内のみ有効（永続しない・再起動で振り直し）。配列インデックスでなく ID で指す。

## イベントと履歴（seq）

制御 API が観測できる出来事は 4 種——`agent_state`（状態語の実変化）・`title`・`pwd`・`tab_closed`。イベント源はタブのタイトル・cwd・agentState の実変化とタブの消滅で、libghostty が host に出す OSC 由来シグナル（[libghostty](../terminal/libghostty.md)）とエージェントの報告（[agent/notify](../agent/notify.md)）から生まれる。**生の PTY 出力はイベントにならない**。

全イベントに、kind やタブを問わず **1 本の単調増加 `seq`**（1 始まり・プロセス内のみ・永続しない）を振り、直近の一定件数を履歴として保持する。列を 1 本にするのは、待機のフィルタが kind とタブを自由に組み合わせるため——列が分かれると「この位置より後」を 1 つの数で言えない。

イベントの形は `{kind, tabId, seq, value?, message?, sessionId?}`。`value` は kind 固有（`agent_state` は状態語で、報告が消えたときは `clear`。`title` はタイトル、`pwd` は path。`tab_closed` は持たない）。`message` / `sessionId` は `agent_state` だけが持ち、その遷移の時点でタブが持っていた文言と session id（無ければキー欠落）——配信時にタブを読み直す形にしないのは、done→idle の消費や次の遷移と競合するため。

**成功応答の最上位には常に `seq`** が載る——その操作の時点での履歴位置で、これより大きい seq のイベントはその操作より後に起きたもの。`send_text` や `spawn_agent` の応答の `seq` をそのまま次の待機の `after` に渡せる。イベントで完結する応答（`wait_for_event` の一致・`prompt_agent` の結果・spawn / resume の ready）の `seq` は**そのイベントの seq**であって応答時点の最新ではない——履歴から返した場合に、そのイベントと応答の間のイベントを次の `after` で取りこぼさないため。エラー応答には載らない。

この保証は、制御キューが FIFO であることに拠る。main での操作 A の応答は A より前に積まれた全イベントを見た後に書かれ、A が引き起こすイベント（PTY 書込み → hook → `report_agent` → main）は必ずその後に積まれる。プロセス内で同期的に emit される経路（`report_agent` 自身）は例外で、その応答の `seq` は自分が起こした遷移を含む。

## ツール

JSON-RPC メソッド = MCP ツール名の 1:1。ただし `report_agent`・`config_*`・workspace CRUD・`focus_tab`/`close_tab`・`completion_*` は socket 専用で、MCP ブリッジには出さない（[cli](cli.md) が直に叩く）。

- `list_workspaces` → `{workspaces:[…]}` … id・name・rootPath・active・tabCount・activated・dormantAgentCount。`activated` は配下にmaterialize開始済みタブが1枚以上あるかを表す現在値で、0タブまたは全タブ未activatedならfalse。`dormantAgentCount` は現在残る未消費の復元チケット（休眠agent）タブ数で、混在workspaceでは `activated: true` と正の値が同時に成立する。0タブworkspaceを前面化した場合は `active: true, activated: false, dormantAgentCount: 0` となる。
- `list_tabs` → `{tabs:[…], seq}` … tabId・workspaceId・workspaceName・title・cwd・agentState・agentSessionId（resume 用・未設定なら null）・active（その workspace で選択中のタブ。背景 workspace でも 1 枚 true で、前面かは `list_workspaces` の `active` と合わせて分かる）。全 workspace 横断・タブ順。`seq` は snapshot 時点の履歴位置で、tab の状態と同じ瞬間の値。
- `list_agents` → `{agents:[…]}` … 検出済みエージェント CLI の command と解決済み絶対 path を列挙する（読み取り専用）。アプリ保持の検出結果をそのまま返し、新規検出（login shell 起動）は起こさない。検出未完了でもエラーにせず**空配列を返す**。`spawn_agent` / `resume_agent` に渡す command の候補源。
- `get_tab_text {tabId, scrollback?}` → `{text}` … 画面テキスト平文。scrollback 真で履歴全体、偽で可視範囲。
- `send_text {tabId, text}` … ペースト相当で PTY へ書く。bracketed paste 下では改行を含めても**自己実行せず**プロンプトに留まる。コマンド実行は別途 `send_key` の enter。
- `send_key {tabId, key}` … キー名（case-insensitive。修飾は `+` 連結）を合成キーイベント（press+release）へ解決して libghostty のキー経路へ送り、端末モード（legacy / kitty keyboard protocol / application cursor 等）に応じた符号化は libghostty に委ねる。Orbe は端末バイトを組まない——ペースト経路は制御文字を strip するため、キーはキー経路でしか届かない。名前付きキー（enter/tab/escape/space/backspace/delete/上下左右/home/end/pageup/pagedown）は実 keycode を持ち、修飾も渡す（`ctrl+enter`・`shift+tab` 等。端末自身の keybind に消費されタブへ届かないことがある）。単一文字（Unicode scalar 1 つ・制御文字以外）は keycode を持たず、生成文字・無修飾文字・修飾を添える——`ctrl+<char>` はレンジ制限なく libghostty が符号化し（`ctrl+1` は端末の標準どおり素の `1`）、`shift+<char>` は大文字化して送る（大文字化しない文字は shift を修飾のまま渡す）。キー名は小文字化して解決するので `A` は `a`、大文字は `shift+a` で指定する。`alt`/`meta`/`option+<char>` が legacy 端末で ESC 前置になるかは `macos-option-as-alt`（層 1 既定 true → [config](../platform/config.md)）に従い、kitty 下は設定に依らず Alt 修飾として届く。`cmd`/`super` 付き単一文字・未知修飾・`+`・複数 scalar の grapheme・制御文字の単一指定は `-32602`——修飾を黙殺して素の文字を注入しないため（grapheme と制御文字は `send_text` で送る）。
- `spawn {workspaceId?, cwd?, command?}` … 新タブを開く。command 省略はシェル・指定はそれを直接起動。cwd 省略は GUI の新規タブと同じフォールバック（対象 workspace の選択中タブの cwd → その workspace の rootPath）。戻り値は `{tabId}`。workspaceId が未知ならエラーにせずアクティブ workspace へフォールバックする。
- `spawn_agent {command?, workspaceId?, cwd?, timeoutMs?}` / `resume_agent {command, sessionId, workspaceId?, cwd?, timeoutMs?}` → `{tabId, workspaceId, agent:{command, path}, ready, agentSessionId?, seq}` … 検出済みエージェントを新タブで起こし、**既定で「準備できた」まで待ってから返す**。`spawn` との違いは、**GUI の起動（⌘⇧A / ⌘⇧C）と同じ組成**——検出済みの絶対パスを使い、子プロセス PATH を注入する（[agent/launch](../agent/launch.md)）。`command` を渡さない `spawn_agent` は**対象 workspace の**実効 `default-agent` を解く（アクティブ WS ではない）。`resume_agent` はエージェント自身の再開コマンド形を組み立て、セッション ID の文字集合もそこで検証する。未検出 command は `-32602`、解決できるエージェントが無ければ `-32000`。**未知 workspaceId は `-32004`**——`spawn` のフォールバックを継がないのは、新しい入口が「指定と違う対象を黙って触る」振る舞いを引き継ぐ理由がないため。
  - 「準備できた」は、起動より後にそのタブへ届く最初の `agent_state=idle`。これを起動時に報告できるのは hook に SessionStart を配線した agent（claude）だけで、どの agent が報告できるかは Orbe が持つ（[agent/plugin-package](../agent/plugin-package.md)）——呼ぶ側に agent 差を意識させない。報告できる agent は idle を待って `ready:true` と `agentSessionId`（その報告が運んだ id）を返し、`seq` はその idle イベントの seq。報告できない agent（codex / agy）は待たず `ready:false` で即返す（`agentSessionId` 無し）。`ready:false` は「続けて `prompt_agent` を送れる保証が無い」の意味。
  - 時間切れ（`timeoutMs` 既定 30 秒・上限 24 時間・不正は起動前に `-32602`）は `{…, ready:false, timedOut:true, seq}`——spawn は成功しているので宛先を捨てない。`timedOut` の有無で「報告できない agent」と区別する。待機中にそのタブが消えたら `-32000 "agent exited"`。
- `activate_workspace {workspaceId}` → `{activeWorkspaceId, tabIds}` … 背景/休眠 workspace を前面化し全タブを mount する。0 タブ WS は GUI どおり空状態（シェルは自動起動しない・tabIds 空）。未知 id は `-32004`（spawn と違いフォールバックしない）、workspaceId 欠落は `-32602`。既にアクティブな WS への activate は no-op で成功（冪等）。手元 Mac のアクティブ workspace も実際に切り替わる。
- `config_list {workspaceId?}` → `{settings:[{key, value, scope, type, domain}]}` … 全設定の実効値（global＋当該 WS 上書き＋既定を畳んだ値）・由来 scope（`global`/`workspace`/`default`）・型・ドメイン（stepper の範囲、bool/enum の候補、フォント名一覧、`tab-title-font-family` は開いた列挙〔候補は空提示・任意文字列受理〕、`default-agent` は検出済み command、`agent-state-icons` は状態別 curated symbols）を返す。設定レジストリ走査の generic 1 実装。`workspaceId` 省略はアクティブ WS（未知 id は `-32004`）。読み取り専用。socket 専用。
- `config_set {key, value, scope, workspaceId?}` → `{ok, key, value, scope}` … 設定を適用する（設定パレットと同一経路）。**全設定**が `scope` ∈ {global, workspace}。workspace は `workspaceId` 省略でアクティブ WS、指定でその WS（非アクティブ可・未知 id は `-32004`）の上書き層へ書く。**保存は常に、ライブ反映は global か対象がアクティブ WS の時だけ**（非アクティブ WS 上書きは次回 activate 時に効く）。値検証はレジストリの domain 駆動＝唯一の検証点で、`value: null` は「解除（継承へ戻す）」として受理する。未知 key・型不一致・値域外・不正 enum は `-32602`。socket 専用。
- `create_workspace {name, rootPath?}` → `{workspaceId, name, rootPath}` … `name` 空（trim 後）は `-32602`。`rootPath` を渡してそれが空（trim 後）も `-32602`（省略はアクティブタブ cwd → ホーム導出。`~` 展開あり）。socket 専用。
- `rename_workspace {workspaceId, name}` … 未知 id は `-32004`、`name` 空は `-32602`。socket 専用。
- `set_workspace_root {workspaceId, rootPath}` … GUI パレットのディレクトリ変更と同一経路（trim・`~` 展開・実在チェックなし・アクティブなら chrome 即時更新・永続化）。未知 id は `-32004`、空は `-32602`。socket 専用。
- `remove_workspace {workspaceId}` … 未知 id は `-32004`。最後の 1 つは削除不可で `-32000`（[workspace](../platform/workspace.md) の「最低 1 枚を残す」規律）。socket 専用。
- `focus_tab {tabId}` … そのタブを選択して端末へフォーカスを移す。別 workspace のタブなら activate を伴う（手元 Mac のアクティブ workspace も切り替わる）。冪等。未知 tab は `-32004`。socket 専用。
- `close_tab {tabId}` … GUI（Cmd+W）と同一——アクティブ workspace の最後のタブを閉じても 0 タブの空状態でアクティブに残る（ウィンドウは閉じない）。応答の `seq` より前にタブが消える（応答直後の `list_tabs` に出ない）。未知 tab は `-32004`。socket 専用。
- `report_agent {tabId, agent, state, sessionId?, message?, messageSource?, reason?}` … エージェント hook の状態報告を発信元タブへ適用する（[agent/notify](../agent/notify.md)）。`reason` は hook が渡す終了理由で、`state=="clear"` のとき[寿命ログ](../platform/session-log.md)の `closed` に載る（表示には出ない）。`messageSource` は文言の出所で、ツール由来かどうかだけが上書き可否を決める（表示には出ない）。`state=="clear"` で状態/コマンド/セッション ID/文言/状態変化時刻を消し、それ以外は state/command を立て、sessionId は新値があれば更新・無ければ同じ CLI からの報告のあいだだけ引き継ぎ（command が変われば捨てる）、文言は state の遷移と出所で上書き可否が決まる（状態変化時刻は state が実際に変わったときだけ進む）。**未消費（休眠）の復元タブ宛の報告・clear は破棄する**（[agent/notify](../agent/notify.md)）。
- `session_log {since?, until?, limit?, sessionId?}` → `{events:[…], truncated}` … [寿命ログ](../platform/session-log.md)の生イベント列を時刻昇順で返す。各要素は `ts`（UTC・ミリ秒・`Z`）・`event`（`opened` / `closed`）・`workspace{name, rootPath}`・`cwd`・`agent{command, sessionId}`、`closed` はさらに `origin`（`agent` / `gesture` / `process` / `controlAPI` / `unresolved`）と任意の `reason`・`title`。`since` / `until` は閉区間の ISO 8601、`limit` は既定 1000・上限 10000 で、超えた分は**古い側を落として** `truncated: true`。派生（閉じたまま戻っていないもの・時刻 T に生きていた集合）はこの API では作らず呼び出し側が組む——「戻っていない」は `sessionId` ごとの最後のイベントが `closed` で `list_tabs` の `agentSessionId` に無いもの。ウィンドウ未接続でも答え、ファイル不在は空の成功。型違い・ISO として読めない値・値域外・JSON の真偽値を数として渡した `limit` は `-32602`。
- `restore_sessions {sessionIds}` → `{results:[{sessionId, status, workspaceId?, tabId?}]}` … 閉じたセッションを休眠チケットとして戻す（[寿命ログ](../platform/session-log.md)）。id ごとにログの最後のイベントを引き、無ければ `unknown`、既に同じ id のタブ（live／休眠）があれば `already-present`、それ以外は所属 workspace（rootPath 照合。無ければログの名前・rootPath で作る）の末尾にチケットを足して `restored`。起動も選択も前面化もしない——次にそのタブが選ばれたとき resume で起きる。部分成功は成功、冪等。`sessionIds` は非空・上限 100・各 id は `resume_agent` と同じ文字集合で、違反は `-32602`。多数を一度に戻す入口はこれ（GUI の ⇧⌘T は 1 件ずつ）。
- `prompt_agent {tabId, text, timeoutMs?}` → `{state, message?, seq}` / `{timedOut:true, seq}` … エージェントに問うて答えを待つ高水準動詞。テキストを送って enter を押し、**その送信より後**で最初にターンが止まる `agent_state`（`done` / `waiting` / `clear`）で返す。`message` はその遷移の文言（done なら最終応答・waiting なら質問文。無ければキー欠落）、`seq` はそのイベントの seq。利用側は seq を扱わない——送信が引き起こす遷移は制御キューの FIFO により待機より後に積まれるので、送信直後に済んだ遷移も取りこぼさない。
  - **入力欄が空いている状態にだけ届く動詞**。対象が `working` / `waiting` なら `-32000 "agent busy"` で何も送らない——`waiting`（permission ダイアログ・AskUserQuestion）へ text＋enter を打つと既定選択の確定＝ツール実行の承認を副作用として起こすため。waiting への応答は `send_key` が担う。このガードが効くのは waiting を報告する agent（[agent/plugin-package](../agent/plugin-package.md)）だけで、報告経路の無いタブでは承認確定を防げない。報告の無いタブへは送れる（codex / agy は起動時に報告しない）。
  - 未 mount（surface 無し）は `-32000 "tab not mounted"`——send が no-op なので黙って時間切れまで待つ形を作らない。未知 tab は `-32004`。待機中にそのタブが消えたら `-32004 "tab closed"`（タブ消滅はエージェントの状態ではないので `state` に混ぜない）。`timeoutMs` 既定 1 時間・上限 24 時間・不正は送る前に `-32602`。
- `wait_for_event {tabId?, kinds?, value?, after?, timeoutMs?}` → `{event, seq}` / `{timedOut:true, seq}` … 状態変化を待つ低水準の口。`kinds` ⊆ {agent_state, title, pwd, tab_closed}、`value` は kind 固有値の完全一致、`after` は「この seq より後」（0 可）。`after` を渡すと保持中の履歴を seq 昇順に見て、フィルタ一致が既にあれば**待たずにそのイベント**（最初の一致）で返し、無ければ待つ——`list_tabs` や書き込み応答の `seq` を `after` に渡せば、snapshot と待機の隙間に済んだ変化を取りこぼさず、前ターンの古いイベントも掴まない。`after` を省くと登録後のイベントだけで起きる。1 接続に複数の待機を張れ、応答は各リクエストの `id` で返る。**params は待機を張る前に検証する**——未知 kind・空 kinds・型違いの tabId / after / value・値域外の timeoutMs は `-32602`、`after` が保持範囲より古ければ `-32006`、最新 seq より大きければ `-32602`（観測しえない値＝呼び出し側のバグ）。黙って通すと「永久に一致せずただ時間切れ」「絞り込みが外れて別タブのイベントを掴む」という、呼び出し側から何も起きなかったのと区別できない形になるため。timeoutMs に上限を置くのも同じ理由で、際限なく大きな値は待機の期限が事実上訪れなくなる。
- `completion_update` / `completion_end` / `completion_accept` … コマンド補完用（[completion](../palette/completion.md)）。前 2 つは**無応答**。`completion_` 系は宛先解決ガードより前で分岐し、無応答メソッドは宛先不在でも応答を出さない（打鍵ごとの update が accept fd に行を積まない）。読めない行にはこの分岐より前でエラー行を返すため、accept fd から読める行が accept 応答だけとは限らない——クライアントは `id` で自分の応答を選ぶ（[completion](../palette/completion.md)）。socket 専用。

## 境界

- get_tab_text / send_text / send_key は **mount 済み（surface 生存）タブにのみ作用**する。条件は surface が生きていることであって、そのタブが見えていることではない。未 mount タブは get_tab_text が空・send 系は no-op。
- **制御 API がタブを作るとき（`spawn` / `spawn_agent` / `resume_agent`）は、対象が背景 workspace でもその場で surface を起こす**——前面化はせず、実サイズで起こす。作れと言われた 1 枚をすぐ駆動できないと、返した tabId が「読めず届かない ID」になるため。前面化したいときは `focus_tab` / `activate_workspace` が明示的に担う。
- 背景workspaceで明示的に作成したタブは、その1枚だけをactivatedにするため、owner workspaceのcomputedな `activated` もtrueになる。ただし `activeWorkspace`・表示タブ・focus・MRUは変えず、同じworkspaceの既存復元タブは未materializeのまま残る。作成したタブの状態報告はAttention一覧・メニューバーのピル・通知音へ即時に出る一方、未activatedタブへ直接注入された報告は注意喚起とlive集計へ出さない。`wait_for_event` は表示集合に関係なくイベント自体を扱う。
- 既存タブの mount は従来どおり workspace 単位の keep-alive 遅延（[workspace](../platform/workspace.md)）。永続復元直後はアクティブ workspace の**全タブ**が mount され、背景 workspace のタブは ID を持つが surface 未生成で、`activate_workspace` で前面化すれば読めるようになる。復元で休眠 workspace のシェルを一斉に起こさないための遅延であり、明示的に 1 枚作れという要求には及ばない。
- 待てるのはイベント（上記 4 種）だけで、**生の PTY 出力は待てない**（エージェントの応答待ちは `prompt_agent`、シェルのコマンド完了待ちは get_tab_text ポーリングで代替する）。

## libghostty 経路

テキスト注入・キー注入・テキスト取得は libghostty の C API を直に呼ぶ。タブの変化と消滅は制御キューで seq を振られて履歴に積まれ、socket 待機者へ配信される。

## MCP ブリッジ

`orbe-mcp` 実行ターゲット（GhosttyKit/AppKit 非依存）。MCP stdio を喋りツール定義を保持し、tools/call を control.sock へ転送する薄い層——ツールの反復に Orbe 本体の再ビルド/再起動が要らない。応答はそのまま本文に出し、control のエラーは code を落として `isError` の文言に畳む（ツール説明はコード番号でなく文言で案内する）。ツール説明が導線を持つ——エージェントに問うなら `prompt_agent`、生の入力は `send_text`＋`send_key`、特殊な待ちだけ `wait_for_event`。`.mcp.json` の `Orbe` サーバは起動スクリプトが毎回 `swift build` を通してから exec する（stale バイナリが別チャネルの socket を掴まないため・[channel](../platform/channel.md)）。接続先 control.sock は app と同じ規則で `ORBE_STATE_DIR` を honor するため、隔離インスタンスと bridge を同じ `ORBE_STATE_DIR` で起こせば、その隔離インスタンスを MCP で駆動できる。

## 開発検証

制御 API の導通は `swift test` の L4（プロセス境界）が担う。テストプロセス内に実 `WindowController` を target とした `ControlServer` を立て、外部プロセスの `orbe-mcp` / `orb` / `orbe-report` から駆動して assert する。「タブで実際に実行された」ことは、コマンド行の中で 2 つのリテラルに割った目印（`echo L4D""ONE_<id>`）を送り、連結された `L4DONE_<id>` が `get_tab_text` に現れるまでポーリングして見る——連結形はシェルが引用符除去を評価した出力にしか現れないので、プロンプトの描画挙動に依らない。`.app` の起動経路と `AppDelegate` の配線はその外側で、隔離した使い捨てインスタンスを起こす `sandbox-run`（`.claude/skills/`）が同じ形の煙探知を通す。再起動の orchestration も制御 API の外側に置く——socket はアプリと心中するため、自己再起動は循環になる。

CLI は `orbe-mcp`（MCP ブリッジ）・`orbe-report`（状態報告）・`orb`（ユーザー/AI 向け操作 CLI・[cli](cli.md)）。`.app` に同梱されるのは `orbe-report` と `orb` で、`orbe-mcp` は同梱せず `.mcp.json` の起動スクリプトがビルドして exec する。
