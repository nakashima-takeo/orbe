---
title: 制御 API（外部 → Orbe）
description: Unix socket 上の JSON-RPC でタブ/workspace/エージェント/タスク/受信を操作し、タスクから作業を始める out-of-band 制御チャネルと、イベント履歴（seq）・待機・MCP ブリッジ・ツール群・mount 境界
updated: 2026-10-10
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
- `-32601` 未知の method。method 名だけで決まり、ウィンドウの有無を見ない——「その動詞が無い」と「今は実行できない」をクライアントが状態に依らず区別できるように。
- `-32602` params の欠落・型不一致・値域外。
- `-32004` 宛先（tab / workspace / タスク / 受信）が見つからない。宛先 ID を解決へ直に渡すメソッド（`get_tab_text` / `send_text` / `send_key` / `report_agent` / `completion_accept`）は `tabId` の欠落・型不一致もここに落ちる（解決の前に検証を挟むメソッドは `-32602`）。
- `-32006` `wait_for_event` の `after` が履歴の保持範囲より古い（対処は seq を取り直す。呼び出し側のバグである `-32602` と分ける）。
- `-32000` 実行できない（ウィンドウ未接続・spawn 失敗・消せない workspace の削除・Home の root 変更・`start_task` の作業場の用意の失敗・`prompt_agent` の busy / 未 mount・ready 待ち中のエージェント消滅・回が走っている受信の `run_intake`）。

無応答契約を持つのは `completion_update` / `completion_end` の 2 つだけで、他は必ず 1 行応答を返す——読めない行にも返すことで、クライアントが応答待ちでハングしない。

## 宛先 ID

workspace / tab にプロセス内単調増加 ID。型をまたいで一意。セッション内のみ有効（永続しない・再起動で振り直し）。配列インデックスでなく ID で指す。

タスクと[受信](../platform/intake.md)（とその提案）の ID は別物で、永続する短い整数（[タスク](../platform/tasks.md)）。

## 呼び出し元タブ（`callerTabId`）

要求を出したプロセスがどのタブの中で動いているかを、params の `callerTabId` で伝えられる。宛先ではなく要求の出所の属性で、読むかどうかは動詞が決める（今読むのは `add_task` と `update_task`）。読まない動詞は無視する。MCP ブリッジは、自分の環境に `ORBE_TAB` があれば転送する**すべての**呼び出しに添え、無ければ外す——ブリッジはどの動詞が読むかを知らない薄い転送層のままで、agent が自分のタブを名乗る手間も名乗り間違いも生まれない（ツールの引数には出さず、agent が書いた値は使わない）。したがって呼び出し元タブが分かるのは、ブリッジがタブの環境の `ORBE_TAB` を受け継いで起きたときだけ。MCP サーバーへ親の環境を渡さないクライアントから呼ぶと呼び出し元は不明になり、`add_task` で workspace を省いたタスクは「なし」に付く（登録時の対処は下の MCP ブリッジ）。`orb` は読む動詞を呼ぶサブコマンド（`task add`・`task set`）だけが添える。

## イベントと履歴（seq）

制御 API が観測できる出来事は 4 種——`agent_state`（状態語の実変化）・`title`・`pwd`・`tab_closed`。イベント源はタブのタイトル・cwd・agentState の実変化とタブの消滅で、libghostty が host に出す OSC 由来シグナル（[libghostty](../terminal/libghostty.md)）とエージェントの報告（[agent/notify](../agent/notify.md)）から生まれる。**生の PTY 出力はイベントにならない**。

全イベントに、kind やタブを問わず **1 本の単調増加 `seq`**（1 始まり・プロセス内のみ・永続しない）を振り、直近の一定件数を履歴として保持する。列を 1 本にするのは、待機のフィルタが kind とタブを自由に組み合わせるため——列が分かれると「この位置より後」を 1 つの数で言えない。

イベントの形は `{kind, tabId, seq, value?, message?, sessionId?}`。`value` は kind 固有（`agent_state` は状態語で、報告が消えたときは `clear`。`title` はタイトル、`pwd` は path。`tab_closed` は持たない）。`message` / `sessionId` は `agent_state` だけが持ち、その遷移の時点でタブが持っていた文言と session id（無ければキー欠落）——配信時にタブを読み直す形にしないのは、done→idle の消費や次の遷移と競合するため。

**成功応答の最上位には常に `seq`** が載る——その操作の時点での履歴位置で、これより大きい seq のイベントはその操作より後に起きたもの。`send_text` や `spawn_agent` の応答の `seq` をそのまま次の待機の `after` に渡せる。イベントで完結する応答（`wait_for_event` の一致・`prompt_agent` の結果・spawn / resume の ready）の `seq` は**そのイベントの seq**であって応答時点の最新ではない——履歴から返した場合に、そのイベントと応答の間のイベントを次の `after` で取りこぼさないため。エラー応答には載らない。

この保証は、制御キューが FIFO であることに拠る。main での操作 A の応答は A より前に積まれた全イベントを見た後に書かれ、A が引き起こすイベント（PTY 書込み → hook → `report_agent` → main）は必ずその後に積まれる。プロセス内で同期的に emit される経路（`report_agent` 自身）は例外で、その応答の `seq` は自分が起こした遷移を含む。

## ツール

JSON-RPC メソッド = MCP ツール名の 1:1。ただし `report_agent`・`config_*`・workspace CRUD・`focus_tab`/`close_tab`/`open_file`・`completion_*` は socket 専用で、MCP ブリッジには出さない（[cli](cli.md) が直に叩く）。

- `list_workspaces` → `{workspaces:[…]}` … id・name・rootPath・active・tabCount・activated・dormantAgentCount。`activated` は配下にmaterialize開始済みタブが1枚以上あるかを表す現在値で、0タブまたは全タブ未activatedならfalse。`dormantAgentCount` は現在残る未消費の復元チケット（休眠agent）タブ数で、混在workspaceでは `activated: true` と正の値が同時に成立する。0タブworkspaceを前面化した場合は `active: true, activated: false, dormantAgentCount: 0` となる。
- `list_tabs` → `{tabs:[…], seq}` … tabId・workspaceId・workspaceName・title・cwd・agentState・agentSessionId（resume 用・未設定なら null）・active（その workspace で選択中のタブ。背景 workspace でも 1 枚 true で、前面かは `list_workspaces` の `active` と合わせて分かる）。全 workspace 横断・タブ順。`seq` は snapshot 時点の履歴位置で、tab の状態と同じ瞬間の値。
- `list_agents` → `{agents:[…]}` … 検出済みエージェント CLI の command と解決済み絶対 path を列挙する（読み取り専用）。アプリ保持の検出結果をそのまま返し、新規検出（login shell 起動）は起こさない。検出未完了でもエラーにせず**空配列を返す**。`spawn_agent` / `resume_agent` に渡す command の候補源。
- `get_tab_text {tabId, scrollback?}` → `{text}` … 画面テキスト平文。scrollback 真で履歴全体、偽で可視範囲。
- `send_text {tabId, text}` … ペースト相当で PTY へ書く。bracketed paste 下では改行を含めても**自己実行せず**プロンプトに留まる。コマンド実行は別途 `send_key` の enter。
- `send_key {tabId, key}` … キー名（case-insensitive。修飾は `+` 連結）を合成キーイベント（press+release）へ解決して libghostty のキー経路へ送り、端末モード（legacy / kitty keyboard protocol / application cursor 等）に応じた符号化は libghostty に委ねる。Orbe は端末バイトを組まない——ペースト経路は制御文字を strip するため、キーはキー経路でしか届かない。名前付きキー（enter/tab/escape/space/backspace/delete/上下左右/home/end/pageup/pagedown）は実 keycode を持ち、修飾も渡す（`ctrl+enter`・`shift+tab` 等。端末自身の keybind に消費されタブへ届かないことがある）。単一文字（Unicode scalar 1 つ・制御文字以外）は keycode を持たず、生成文字・無修飾文字・修飾を添える——`ctrl+<char>` はレンジ制限なく libghostty が符号化し（`ctrl+1` は端末の標準どおり素の `1`）、`shift+<char>` は大文字化して送る（大文字化しない文字は shift を修飾のまま渡す）。キー名は小文字化して解決するので `A` は `a`、大文字は `shift+a` で指定する。`alt`/`meta`/`option+<char>` が legacy 端末で ESC 前置になるかは `macos-option-as-alt`（層 1 既定 true → [config](../platform/config.md)）に従い、kitty 下は設定に依らず Alt 修飾として届く。`cmd`/`super` 付き単一文字・未知修飾・`+`・複数 scalar の grapheme・制御文字の単一指定は `-32602`——修飾を黙殺して素の文字を注入しないため（grapheme と制御文字は `send_text` で送る）。
- `spawn {workspaceId?, cwd?, command?}` … 新タブを開く。command 省略はシェル・指定はそれを直接起動。cwd 省略は [cwd を指定せずに起こすタブ](../chrome/layout.md#cwd-の確定)と同じフォールバック（対象 workspace の選択中タブの cwd → その workspace の rootPath）。戻り値は `{tabId}`。workspaceId が未知ならエラーにせずアクティブ workspace へフォールバックする。
- `spawn_agent {command?, workspaceId?, cwd?, timeoutMs?}` / `resume_agent {command, sessionId, workspaceId?, cwd?, timeoutMs?}` → `{tabId, workspaceId, agent:{command, path}, ready, agentSessionId?, seq}` … 検出済みエージェントを新タブで起こし、**既定で「準備できた」まで待ってから返す**。`spawn` との違いは、**GUI の起動（⌘⇧A / ⌘⇧C）と同じ組成**——検出済みの絶対パスを使い、子プロセス PATH を注入する（[agent/launch](../agent/launch.md)）。`command` を渡さない `spawn_agent` は**対象 workspace の**実効 `default-agent` を解く（アクティブ WS ではない）。`resume_agent` はセッション ID の文字集合を検証し、その会話（同じ CLI・同じセッション ID）が生きているタブで既に開いていれば、新しく起こさずそのタブを返す——同じ会話を 2 つの agent が同時に書くと記録が混ざるため。このときは待たずに返し、`ready` はそのタブの agent が今 idle / done を報告しているか。開いていなければ、休眠のタブを足して起こす形で再開する（再開のコマンドを組むのは[休眠のタブの起床の 1 か所](../agent/launch.md#会話の再開の組み立て)。[秘書](../agent/secretary.md)の会話なら秘書の役割の指示を添え、そのタブが秘書になる）。未検出 command は `-32602`、解決できるエージェントが無ければ `-32000`。**未知 workspaceId は `-32004`**——`spawn` のフォールバックを継がないのは、新しい入口が「指定と違う対象を黙って触る」振る舞いを引き継ぐ理由がないため。
  - 「準備できた」は、起動より後にそのタブへ届く最初の `agent_state=idle`。これを起動時に報告できるのは hook に SessionStart を配線した agent（claude）だけで、どの agent が報告できるかは Orbe が持つ（[agent/plugin-package](../agent/plugin-package.md)）——呼ぶ側に agent 差を意識させない。報告できる agent は idle を待って `ready:true` と `agentSessionId`（その報告が運んだ id）を返し、`seq` はその idle イベントの seq。報告できない agent（codex / agy）は待たず `ready:false` で即返す（`agentSessionId` 無し）。`ready:false` は「続けて `prompt_agent` を送れる保証が無い」の意味。
  - 時間切れ（`timeoutMs` 既定 30 秒・上限 24 時間・不正は起動前に `-32602`）は `{…, ready:false, timedOut:true, seq}`——spawn は成功しているので宛先を捨てない。`timedOut` の有無で「報告できない agent」と区別する。待機中にそのタブが消えたら `-32000 "agent exited"`。
- `activate_workspace {workspaceId}` → `{activeWorkspaceId, tabIds}` … 背景/休眠 workspace を前面化し全タブを mount する。0 タブ WS は GUI どおり空状態（シェルは自動起動しない・tabIds 空）。未知 id は `-32004`（spawn と違いフォールバックしない）、workspaceId 欠落は `-32602`。既にアクティブな WS への activate は no-op で成功（冪等）。手元 Mac のアクティブ workspace も実際に切り替わる。
- `config_list {workspaceId?}` → `{settings:[{key, value, scope, type, domain}]}` … 全設定の実効値（global＋当該 WS 上書き＋既定を畳んだ値）・由来 scope（`global`/`workspace`/`default`）・型・ドメイン（stepper の範囲、bool/enum の候補、フォント名一覧、`tab-title-font-family` は開いた列挙〔候補は空提示・任意文字列受理〕、`default-agent` は検出済み command、`agent-state-icons` は状態別 curated symbols）を返す。設定レジストリ走査の generic 1 実装。`workspaceId` 省略はアクティブ WS（未知 id は `-32004`）。読み取り専用。socket 専用。
- `config_set {key, value, scope, workspaceId?}` → `{ok, key, value, scope}` … 設定を適用する（設定パレットと同一経路）。**全設定**が `scope` ∈ {global, workspace}。workspace は `workspaceId` 省略でアクティブ WS、指定でその WS（非アクティブ可・未知 id は `-32004`）の上書き層へ書く。**保存は常に、ライブ反映は global か対象がアクティブ WS の時だけ**（非アクティブ WS 上書きは次回 activate 時に効く）。値検証はレジストリの domain 駆動＝唯一の検証点で、`value: null` は「解除（継承へ戻す）」として受理する。未知 key・型不一致・値域外・不正 enum は `-32602`。socket 専用。
- `create_workspace {name, rootPath?}` → `{workspaceId, name, rootPath}` … `name` 空（trim 後）は `-32602`。`rootPath` を渡してそれが空（trim 後）も `-32602`（省略はアクティブタブ cwd → ホームディレクトリ導出。`~` 展開あり）。socket 専用。
- `rename_workspace {workspaceId, name}` … 未知 id は `-32004`、`name` 空は `-32602`。socket 専用。
- `set_workspace_root {workspaceId, rootPath}` … GUI パレットのディレクトリ変更と同一経路（trim・`~` 展開・実在チェックなし・アクティブなら chrome 即時更新・永続化）。未知 id は `-32004`、[Home](../platform/workspace.md#home) は `-32000`、空は `-32602`。socket 専用。
- `remove_workspace {workspaceId}` … 未知 id は `-32004`。Home と最後の通常 workspace は削除不可で `-32000`（理由はメッセージで分かる。可否は [workspace](../platform/workspace.md#home) の判断に従う）。socket 専用。
- `focus_tab {tabId}` … そのタブを選択して焦点の面へフォーカスを移す（→ [chrome/layout](../chrome/layout.md) のフォーカス）。別 workspace のタブなら activate を伴う（手元 Mac のアクティブ workspace も切り替わる）。冪等。未知 tab は `-32004`。socket 専用。
- `open_file {tabId, path}` … そのタブのエディターでファイルを開き（→ [editor/code](../editor/code.md)）、エディター面が見える配置にして（隠れていれば全面、分割中は焦点だけ）、`focus_tab` と同じくタブを選んでテキスト面へフォーカスを移す。`path` は絶対か、`~` 展開の上でタブの実効 cwd からの相対——symlink は実体へ解く（別の綴りで開いても同じ文書、保存も実体へ届く）。既に開いているファイルは焦点を移すだけ。開いた文書はファイルタブ行に普通のタブとして並び（既に仮のタブで開いていれば普通のタブに変わる——人の次のクリックが入れ替えない）、タブの根の下ならエクスプローラーがその祖先を開いて選択表示する（→ [editor/shell](../editor/shell.md)）。未知 tab は `-32004`、`path` 欠落・空は `-32602`、読めない・UTF-8 でないファイルと、Metal の装置が取れずテキスト面を作れない環境では `-32000`（それぞれ `cannot read: <path>`・`not UTF-8: <path>`・`no Metal device: <path>`。面は変わらない）。socket 専用。
- `close_tab {tabId}` … GUI（Cmd+W）と同一のカスケード——アクティブ workspace の最後のタブを閉じても 0 タブの空状態でアクティブに残る（ウィンドウは閉じない）。ただしエディターの未保存の文書は確認せず黙って捨てる（無人の操作に確認は出せない → [editor/shell](../editor/shell.md)）。`remove_workspace` も同じ。応答の `seq` より前にタブが消える（応答直後の `list_tabs` に出ない）。未知 tab は `-32004`。socket 専用。
- `report_agent {tabId, agent, state, sessionId?, message?, messageSource?, reason?}` … エージェント hook の状態報告を発信元タブへ適用する（[agent/notify](../agent/notify.md)）。`reason` は hook が渡す終了理由で、`state=="clear"` のとき[寿命ログ](../platform/session-log.md)の `closed` に載る（表示には出ない）。`messageSource` は文言の出所で、ツール由来かどうかだけが上書き可否を決める（表示には出ない）。`state=="clear"` で状態/コマンド/セッション ID/文言/状態変化時刻を消し、それ以外は state/command を立て、sessionId は新値があれば更新・無ければ同じ CLI からの報告のあいだだけ引き継ぎ（command が変われば捨てる）、文言は state の遷移と出所で上書き可否が決まる（状態変化時刻は state が実際に変わったときだけ進む）。**未消費（休眠）の復元タブ宛の報告・clear は破棄する**（[agent/notify](../agent/notify.md)）。
- `session_log {since?, until?, limit?, sessionId?}` → `{events:[…], truncated}` … [寿命ログ](../platform/session-log.md)の生イベント列を時刻昇順で返す。各要素は `ts`（UTC・ミリ秒・`Z`）・`event`（`opened` / `closed`）・`workspace{name, rootPath}`・`cwd`・`agent{command, sessionId}`、`closed` はさらに `origin`（`agent` / `gesture` / `process` / `controlAPI` / `unresolved`）と任意の `reason`・`title`。`since` / `until` は閉区間の ISO 8601、`limit` は既定 1000・上限 10000 で、超えた分は**古い側を落として** `truncated: true`。派生（閉じたまま戻っていないもの・時刻 T に生きていた集合）はこの API では作らず呼び出し側が組む——「戻っていない」は `sessionId` ごとの最後のイベントが `closed` で `list_tabs` の `agentSessionId` に無いもの。ウィンドウ未接続でも答え、ファイル不在は空の成功。型違い・ISO として読めない値・値域外・JSON の真偽値を数として渡した `limit` は `-32602`。
- `restore_sessions {sessionIds}` → `{results:[{sessionId, status, workspaceId?, tabId?}]}` … 閉じたセッションを休眠チケットとして戻す（[寿命ログ](../platform/session-log.md)）。id ごとにログの最後のイベントを引き、無ければ `unknown`、既に同じ id のタブ（live／休眠）があれば `already-present`、それ以外は所属 workspace（rootPath 照合。無ければログの名前・rootPath で作る）にチケットを足して `restored`（位置は新規タブと同じ規則——同じ worktree の連の右端、無ければ末尾）。起動も選択も前面化もしない——起床は [layout](../chrome/layout.md) の mount 規律に従う（アクティブ workspace に足した分は次の選択操作で他の未 mount タブと順次、背景 workspace の分はその workspace のアクティブ化で）。部分成功は成功、冪等。`sessionIds` は非空・上限 100・各 id は `resume_agent` と同じ文字集合で、違反は `-32602`。多数を一度に戻す入口はこれ（GUI の ⇧⌘T は 1 件ずつ）。
- `prompt_agent {tabId, text, timeoutMs?}` → `{state, message?, seq}` / `{timedOut:true, seq}` … エージェントに問うて答えを待つ高水準動詞。テキストを送って enter を押し、**その送信より後**で最初にターンが止まる `agent_state`（`done` / `waiting` / `clear`）で返す。`message` はその遷移の文言（done なら最終応答・waiting なら質問文。無ければキー欠落）、`seq` はそのイベントの seq。利用側は seq を扱わない——送信が引き起こす遷移は制御キューの FIFO により待機より後に積まれるので、送信直後に済んだ遷移も取りこぼさない。
  - **入力欄が空いている状態にだけ届く動詞**。対象が `working` / `waiting` なら `-32000 "agent busy"` で何も送らない——`waiting`（permission ダイアログ・AskUserQuestion）へ text＋enter を打つと既定選択の確定＝ツール実行の承認を副作用として起こすため。waiting への応答は `send_key` が担う。このガードが効くのは waiting を報告する agent（[agent/plugin-package](../agent/plugin-package.md)）だけで、報告経路の無いタブでは承認確定を防げない。報告の無いタブへは送れる（codex / agy は起動時に報告しない）。
  - 未 mount（surface 無し）は `-32000 "tab not mounted"`——send が no-op なので黙って時間切れまで待つ形を作らない。未知 tab は `-32004`。待機中にそのタブが消えたら `-32004 "tab closed"`（タブ消滅はエージェントの状態ではないので `state` に混ぜない）。`timeoutMs` 既定 1 時間・上限 24 時間・不正は送る前に `-32602`。
- `wait_for_event {tabId?, kinds?, value?, after?, timeoutMs?}` → `{event, seq}` / `{timedOut:true, seq}` … 状態変化を待つ低水準の口。`kinds` ⊆ {agent_state, title, pwd, tab_closed}、`value` は kind 固有値の完全一致、`after` は「この seq より後」（0 可）。`after` を渡すと保持中の履歴を seq 昇順に見て、フィルタ一致が既にあれば**待たずにそのイベント**（最初の一致）で返し、無ければ待つ——`list_tabs` や書き込み応答の `seq` を `after` に渡せば、snapshot と待機の隙間に済んだ変化を取りこぼさず、前ターンの古いイベントも掴まない。`after` を省くと登録後のイベントだけで起きる。1 接続に複数の待機を張れ、応答は各リクエストの `id` で返る。**params は待機を張る前に検証する**——未知 kind・空 kinds・型違いの tabId / after / value・値域外の timeoutMs は `-32602`、`after` が保持範囲より古ければ `-32006`、最新 seq より大きければ `-32602`（観測しえない値＝呼び出し側のバグ）。黙って通すと「永久に一致せずただ時間切れ」「絞り込みが外れて別タブのイベントを掴む」という、呼び出し側から何も起きなかったのと区別できない形になるため。timeoutMs に上限を置くのも同じ理由で、際限なく大きな値は待機の期限が事実上訪れなくなる。
- `list_tasks {workspaceId?}` → `{tasks:[…], seq}` … [タスク](../platform/tasks.md)一覧を列の順で返す。各要素は `taskId`・`title`・`status`（`todo` / `in_progress` / `done`）・`priority`（`high` / `medium` / `low`）・`description`・`createdAt`（UTC・ミリ秒・`Z`）と、あれば `waiting{reason, since}`・`due`（`YYYY-MM-DD`）・`workspaceId` と `workspaceName`・`createdBy`・`links`・`worktree`（無い値はキーごと無い。結び付きの無いタスクは `links` を持たない。付き先の workspace を解決できないタスクも `workspaceId` を持たず、worktree のディレクトリが無いタスクも `worktree` を持たない）。`links` は結び付いた GitHub の Issue・PR の列 `[{kind: "issue" | "pr", repo: "owner/name", number}]` で、先頭が主、`repo` は小文字。`worktree` はタスクの作業の場所（worktree のルートの絶対パス）。人が外した項目の記録は出さない。待ちに条件があれば `waiting.condition{description, command, everyMinutes, deadline, directory?, agent?{command, sessionId}, setAt, checks, lastCheck?{startedAt, result, stdout?, stderr?}}`（`checks` は確認の回数、`result` は `success` / `exited` / `signaled` / `limited` / `stopped` / `notStarted`、`stdout` / `stderr` は記録した先頭）。条件で解けた待ちは `waiting` の代わりに `waitResolved{how: "satisfied" | "expired", at, output?, waiting}` で、`output` は確認の標準出力の先頭、`waiting` は解けた待ちと条件を同じ形で持つ（AI が同じ条件で付け直せる）。`workspaceId` を渡すとその workspace のタスクだけ（未知は `-32004`）。
- `add_task {title, status?, priority?, due?, waitingReason?, description?, workspaceId?, links?, worktree?, callerTabId?}` → `{task, seq}` … 列の末尾に足す。`workspaceId` は省略＝呼び出し元タブの workspace（タブが分からなければなし）、`null`＝なし、整数＝その workspace（未知は `-32004`）。「キーが無い」と `null` を区別するのは `config_set` の `value: null` と同じ流儀。追加の時点で `callerTabId` のタブの agent が `working` を報告していれば、その agent の名前を追加者として残す（それ以外——人がシェルから足した・終了を報告しない agent が去った後——は残さない）。呼び出し元タブが分かるのは `callerTabId` が届いたときだけ（上記。MCP 経由ではブリッジが `ORBE_TAB` を受け継いでいるとき）。`callerTabId` が未知のタブを指してもエラーにせず「呼び出し元不明」として足す——タブが閉じた直後の競合で追加そのものを落とさないため。
- `update_task {taskId, title?, status?, priority?, due?, waitingReason?, description?, workspaceId?, links?, worktree?}` → `{task, seq}` … キーの無い項目は変えず、`due` / `waitingReason` / `workspaceId` / `worktree` は `null` で外す（`waitingReason: null` は待ちと条件を外す）。完了は `status: "done"` で、待ちは自動で外れる（完了専用の動詞は無い）。変更項目が 1 つも無い・完了のタスクに待ちを入れる（同じ要求で `status` を戻さずに）・`status: "done"` と `waitingReason` の文字列を同時に渡す、はいずれも `-32602`。
- `set_wait_condition {taskId, condition, callerTabId?}` → `{task, seq}` … 待っているタスクに解ける条件を付ける。`condition: null` は条件だけを外す（待ちは残る）。`condition` を省くと `-32602`。条件のコマンドは人の承認なしに裏で繰り返し走るので、条件を付ける口はこの動詞だけで、`add_task` / `update_task` は条件を受けない——agent CLI のツール許可はツール単位なので、帳簿の動詞を常に許可しても、任意のコマンドの裏実行までは許可されない（受信の `set_intake` と同じ形）。`condition` は `{description, command, everyMinutes, deadline}` で 4 つとも必須（[待ちの条件](../platform/tasks.md)）。`deadline` は ISO 8601 の日時で、時差の無い形（`2026-10-13T09:00`）は Mac のタイムゾーンの時刻として読む（解析は control の 1 か所で行い、`orb` はそのまま送る）。条件を受けたら `callerTabId` のタブから、作業ディレクトリ（タブの今の cwd）と、そのタブの agent が `working` を報告していればその会話（CLI 名・セッション ID・タブの workspace）を入れる。形の違反、待っていないタスク・完了のタスクへ付ける・値の規則（説明が空でない 1 行・空でないコマンド・1 分以上の間隔・今より後の期限）に反する、はいずれも `-32602` で、一覧は変わらない。
- `links`（`add_task` / `update_task`）は `list_tasks` と同じ形の配列だけを受け、`update_task` では**丸ごと置き換える**（`[]` で全部外す。`null` は型の違反）。配列で「外す」が表せるので、`null`＝外す の流儀は持ち込まない。配列でない・要素の型が違う・`kind` が `issue` / `pr` 以外・`repo` が `owner/name` の形でない・`number` が 1 未満、同じタスクの中で同じ項目（`repo` と `number` が同じもの。種別は問わない）が重なる、ほかのタスクがその項目を持っている（理由に相手の taskId が入る）、はいずれも `-32602` で、一覧は変わらない（[タスク](../platform/tasks.md)）。
- `worktree`（`add_task` / `update_task`）は文字列のパスで、実在するディレクトリの絶対パスでなければ `-32602`。制御文字・改行類を含むパスも `-32602`（読み込みが拒む形の値を書かないため）。そのパスを含む worktree のルートに揃えて付ける（サブディレクトリを渡してもルートになる）。ほかのタスクが同じ worktree を持っていれば `-32602` で、理由に相手の taskId が入る（付け替えは相手から外してから）。相対パスは受けない——control は呼び出し側の作業ディレクトリを知らないので、解くのは呼び出し側（`orb` は自分の cwd から解いて送る）。
- `move_task {taskId, beforeTaskId | afterTaskId}` → `{ok, seq}` … 別のタスクの前か後ろへ移す。ちょうど 1 つが必須で、自分自身を指すと `-32602`。
- `delete_task {taskId}` → `{ok, seq}`。
  - タスクの 5 動詞に共通して、params の欠落・型違い・値域外（空のタイトル・未知のステータス／優先度・暦に無い日付・JSON の真偽値を整数として渡した値など）は `-32602`、未知のタスクと未知の workspace は `-32004`。拒否したとき一覧は変わらない。タスクの変化はイベントにならない。
- `start_task {taskId, branch?, repo?, agent?, prompt?}` → `{task, workdir, repo?, branch?, created, tabId, workspaceId, agent:{command, path}, seq}` … タスクの作業に agent を取り掛からせる。作業場を用意し、タスクを進行中にしてその作業場を付け（⌘T の ↵ と同じ 1 回の変更 → [タスク](../platform/tasks.md#worktree)）、タスクの workspace に agent のタブを選ばずに起こす（前面化も選択もしない）。MCP に出し、`orb` には無い——[秘書](../agent/secretary.md)などの agent が作業を割り振るための口。
  - **作業場はタスクの付き先で決まる。** リポジトリの workspace（Home でない workspace）のタスクは、[⌘T の「タスクから開く」](../palette/worktree.md#タスクから開く)と同じ規則で worktree を用意する——タスクの worktree → 主が Issue なら `issue/<番号>` → PR なら head のブランチ。`branch` を渡せば、主の結び付きの代わりにそのブランチ名を同じ規則に通す（worktree → ローカルブランチ → remote のブランチ → 作成行の条件を通れば作る）。手元に無いブランチは既定ブランチから作り（⌘T の「前回」のベースは人の文脈なので使わない）、遅れたローカルブランチは fast-forward してから開く（⌘T で人に問う最新化をそのまま行う）。行き先の決定と用意は ⌘T と同じ[リポジトリの事実の層](../palette/worktree.md#データ供給プログレッシブ)を通り、提示時の fetch の着地・remote の正式名・PR の head が揃うまで待って決める——規則の写しを作らないので、片方だけが直ることがない。[Home](../platform/workspace.md#home) のタスクは Home の `tasks/<ID>-<短い名前>/` を作業場にし（[Home のタスクの作業場](../platform/workspace.md#home-のタスクの作業場)。2 回目からは同じフォルダ。記録が Home の `tasks/` の下に無ければ決め直す）、`branch`・`repo` は読まない。
  - **リポジトリは人の画面の状態で決めない。** 決める順は、タスクの worktree（在れば）のリポジトリ → `repo`（リポジトリの中の絶対パス。タスクに在る worktree が無いときだけ読む）→ タスクの workspace の root で、git の中の最初のものを使う。⌘T は「その workspace でアクティブなタブ」のリポジトリを使うが、画面の無い呼び出しがそれに倣うと、人の操作次第で別のリポジトリに worktree を作ってタスクに付けてしまうため。タスク自身の worktree が今の一覧にあれば（`branch` を渡しても）それを使い、remote は照合しない。無ければ、主の結び付きがあれば（`branch` を渡しても）、そのリポジトリに主のリポジトリを指す remote があるかを先に確かめる——照合は主の結び付きから新しく決めるとき、人の操作で別のリポジトリに作らないためのもの。使ったリポジトリ（本体 worktree）を結果の `repo` に入れる。
  - `agent` は検出済みの command（省略でタスクの workspace の実効 `default-agent`）。`prompt` は agent の最初の入力になる。Home のタスクでは、Orbe が UI の言語で組んだタスク（ID・タイトル・詳細）に `prompt` を添えたものが最初の入力になる。
  - **作業場ができてタブを開いた時点で返り、agent の準備は待たない**（`spawn_agent` と違い `ready` を持たない）。worktree の作成や fetch の着地待ちで数秒かかりうるので、作業場の用意の完了で 1 度だけ応答する。`workdir` は付けた作業場、`created` は作業場を新しく作ったか、`branch` は付けた時点のブランチ（git の外・detached なら無い）、`seq` は応答時点の履歴位置。
  - 拒否と失敗。どれもタスクは変わらない（作業場を用意した後にタブを起こせなかったときだけは、タスクは進行中で作業場が付いたまま残る）。

    | 状況 | コード |
    |---|---|
    | params の欠落・型違い | `-32602` |
    | 未知のタスク（用意の間に消えたときも） | `-32004` |
    | タスクに workspace が無い（解決できない参照を含む。先に `update_task` で付ける） | `-32602` |
    | 未検出の agent・解決できる既定の agent が無い | `-32602` |
    | `repo` が実在するディレクトリの絶対パスでない | `-32602` |
    | どの候補も git の中でない（`repo` を渡す） | `-32602` |
    | 主のリポジトリを指す remote が無い（`repository mismatch`。使ったリポジトリを添える） | `-32602` |
    | ブランチが決まらない（結び付きも worktree も `branch` も無い・PR の head と同名の別のローカルブランチがある。`branch` を渡す） | `-32602` |
    | `branch` をここで作れない（名前か作成先がぶつかる・ブランチ名として不正） | `-32602` |
    | 行き着いた先がリポジトリの本体（main worktree。人の作業ツリーで agent を起こさない） | `-32602` |
    | 作業場がほかのタスクの worktree（相手のタスクを添える。付け替えは人の ⌘T だけ） | `-32602` |
    | 作業場で agent が作業中・入力待ち（そのタブを添える。2 体目を起こさず `prompt_agent` で頼む） | `-32602` |
    | Home のフォルダが決まらない・git の作業ツリーの中にある | `-32000` |
    | worktree の作成・最新化・フォルダの作成の失敗（理由を添える） | `-32000` |
    | ウィンドウ未接続・用意の間にタスクの workspace が消えた・タブを起こせない | `-32000` |
- `list_intakes` → `{intakes:[…], seq}` … [受信](../platform/intake.md)を ID 順に返す。各要素は `intakeId` と `set_intake` と同じ定義（`name`・`fetch`・`judge`・`when`。`agent` は省略時の既定も埋めて返す）に加え、`paused`・`running`（回が走っているか）・`nextRunAt`（次に予定で回る時刻。止めていれば無い。過ぎていれば今以前）・`lastRunAt`（まだ回っていなければ無い）・`openProposals`（この受信の棚にある人の判断待ちの提案の数）・`overlaps`（前回の取得結果のリンクが重なる他の受信 `[{intakeId, name, count}]`）・`runs`（回の記録。新しい順に 20 件まで。各回は `startedAt`・`endedAt`・`trigger`〔`schedule` / `now`〕・`fetch{commandLine, ending, items, rejected{count, reasons}}`・`newItems`・`judge{commandLine, ending, proposed, resolved, rejected}`〔判定を起こさなかった回は無い〕・`withdrawn`・`failure`〔失敗した回だけ〕）。時刻は UTC・ミリ秒・`Z`。
- `set_intake {intakeId?, name, fetch, judge, when}` → `{intake, seq}` … `intakeId` が無ければ作り、あれば定義を丸ごと置き換える（止めているかは変えない）。`fetch` は `{command, directory?, coverage}` か `{agent?, model, tools, request, coverage}`（`command` と `request` のどちらを持つかで決まり、両方・どちらも無いは `-32602`。`coverage` は取得の性質で `currentSet`〔今の集合〕か `newArrivals`〔新着の流れ〕）、`judge` は `{agent?, model, instruction}`、`agent` の既定は `claude`。`when` は `{everyMinutes}` か `{dailyAt: ["HH:MM", …]}`。4 つのどれかの欠落・型違い、名前が 1 行でない・コマンドが空・作業ディレクトリが絶対パスでない・裏で回せない agent（理由付き）・モデルや依頼文や指示文が空・取得役のツールが 0 個か MCP のツールの完全名（`mcp__<サーバー>__<ツール>`）でないものを含む・取得の性質が無いか知らない値・間隔が 1 分未満・`HH:MM` でない・時刻が範囲外、はいずれも `-32602` で、受信は変わらない。未知の `intakeId` は `-32004`。取得のやり方か判定が前と違えば走っている回を止め、名前・いつ・取得の性質だけなら止めない。新しく作った受信はすぐには回らない。
- `run_intake {intakeId}` → `{ok, seq}` … 今すぐ 1 回回し、回の終わりを待たずに返る（結果は `list_intakes` の `runs`）。止めた受信も受ける。回が走っていれば `-32000`。
- `pause_intake {intakeId, paused}` → `{intake, seq}` … 予定を止める（`true`）・再開する（`false`）。走っている回は止めない。`paused` は JSON の真偽値だけを受ける。
- `delete_intake {intakeId}` → `{ok, seq}` … 走っている回を止め、結果は捨てる。その受信だけが持っていた提案は忘れる。
- `list_intake_proposals {intakeId?}` → `{proposals:[…], seq}` … 覚えている提案を全状態で返す。各要素は `proposalId`・`state`（`open` / `accepted` / `dismissed` / `resolved`）・`title`・`due?`・`link`・`body`・`time`・`proposedAt`・`taskId`（`accepted` だけ）・`intakeId` と `intakeName`（棚に出す受信）。`intakeId` を渡すとその受信の棚の分だけ（未知は `-32004`）。
  - 受信の 6 動詞はいずれも MCP に出す。提案をタスクにする・捨てるは人の判断なので制御 API に無い。受信の変化はイベントにならない。
- `completion_update` / `completion_end` / `completion_accept` … コマンド補完用（[completion](../palette/completion.md)）。前 2 つは**無応答**。`completion_` 系は宛先解決ガードより前で分岐し、無応答メソッドは宛先不在でも応答を出さない（打鍵ごとの update が accept fd に行を積まない）。読めない行にはこの分岐より前でエラー行を返すため、accept fd から読める行が accept 応答だけとは限らない——クライアントは `id` で自分の応答を選ぶ（[completion](../palette/completion.md)）。socket 専用。

## 境界

- get_tab_text / send_text / send_key は **mount 済み（surface 生存）タブにのみ作用**する。条件は surface が生きていることであって、そのタブが見えていることではない。未 mount タブは get_tab_text が空・send 系は no-op。
- **制御 API がタブを作るとき（`spawn` / `spawn_agent` / `resume_agent`）は、対象が背景 workspace でもその場で surface を起こす**——前面化はせず、実サイズで起こす。作れと言われた 1 枚をすぐ駆動できないと、返した tabId が「読めず届かない ID」になるため。前面化したいときは `focus_tab` / `activate_workspace` が明示的に担う。
- `start_task` が開くタブも同じくその場で surface を起こすが、**前面の workspace でも選ばない**（隠れタブとして起こす）——人が見ているタブを、agent が割り振った作業で奪わないため（[workspace](../platform/workspace.md)）。
- 背景workspaceで明示的に作成したタブは、その1枚だけをactivatedにするため、owner workspaceのcomputedな `activated` もtrueになる。ただし `activeWorkspace`・表示タブ・focus・MRUは変えず、同じworkspaceの既存復元タブは未materializeのまま残る。作成したタブの状態報告はAttention一覧・メニューバーのピル・通知音へ即時に出る一方、未activatedタブへ直接注入された報告は注意喚起とlive集計へ出さない。`wait_for_event` は表示集合に関係なくイベント自体を扱う。
- 既存タブの mount は従来どおり workspace 単位の keep-alive 遅延（[workspace](../platform/workspace.md)）。永続復元直後はアクティブ workspace の**全タブ**が mount され、背景 workspace のタブは ID を持つが surface 未生成で、`activate_workspace` で前面化すれば読めるようになる。復元で休眠 workspace のシェルを一斉に起こさないための遅延であり、明示的に 1 枚作れという要求には及ばない。
- 待てるのはイベント（上記 4 種）だけで、**生の PTY 出力は待てない**（エージェントの応答待ちは `prompt_agent`、シェルのコマンド完了待ちは get_tab_text ポーリングで代替する）。

## libghostty 経路

テキスト注入・キー注入・テキスト取得は libghostty の C API を直に呼ぶ。タブの変化と消滅は制御キューで seq を振られて履歴に積まれ、socket 待機者へ配信される。

## MCP ブリッジ

`orbe-mcp` 実行ターゲット（GhosttyKit/AppKit 非依存）。MCP stdio を喋りツール定義を保持し、tools/call を control.sock へ転送する薄い層——ツールの反復に Orbe 本体の再ビルド/再起動が要らない。応答はそのまま本文に出し、control のエラーは code を落として `isError` の文言に畳む（ツール説明はコード番号でなく文言で案内する）。ツール説明が導線を持つ——エージェントに問うなら `prompt_agent`、生の入力は `send_text`＋`send_key`、特殊な待ちだけ `wait_for_event`。

配布は `.app` 同梱とエージェントプラグインで行う。`orbe-mcp` は `.app` に同梱され、タブには `ORBE_MCP_BIN` でその絶対パスが注入される。配布プラグインの MCP 定義が起こすシムが、自分のチャネルの Orbe のタブではこれへ exec し、それ以外ではツール 0 個の空サーバーとして応答する（[agent/plugin-package](../agent/plugin-package.md)）。したがって Orbe のタブで起こした claude / codex / agy には、利用者が何も設定しなくても Orbe のツールが出て、ブリッジはタブの `ORBE_SOCK` でそのタブの Orbe にだけつながり、`ORBE_TAB` で呼び出し元を名乗る。PATH から探さないのは、利用者の rc が PATH を並べ替えると別の `orbe-mcp` を掴むため。

[`scripts/orbe-mcp.sh`](../../../scripts/orbe-mcp.sh) は開発用の道具で、Orbe を再起動せずにツールを試すためにある。MCP クライアントへこの絶対パスを stdio サーバーの起動コマンドとして登録すると、毎回 `swift build` を通してから exec する（stale バイナリが別チャネルの socket を掴まないため・[channel](../platform/channel.md)）。接続先 control.sock は app と同じ規則で `ORBE_STATE_DIR` を honor するため、隔離インスタンスと bridge を同じ `ORBE_STATE_DIR` で起こせば、その隔離インスタンスを MCP で駆動できる。MCP サーバーへ親の環境を渡さないクライアントに登録するときは、`ORBE_TAB` を渡す環境変数として設定に加えないと、`add_task` の既定の付き先と追加者が効かない。

## 開発検証

制御 API の導通は `swift test` の L4（プロセス境界）が担う。テストプロセス内に実 `WindowController` を target とした `ControlServer` を立て、外部プロセスの `orbe-mcp` / `orb` / `orbe-report` から駆動して assert する。「タブで実際に実行された」ことは、コマンド行の中で 2 つのリテラルに割った目印（`echo L4D""ONE_<id>`）を送り、連結された `L4DONE_<id>` が `get_tab_text` に現れるまでポーリングして見る——連結形はシェルが引用符除去を評価した出力にしか現れないので、プロンプトの描画挙動に依らない。`.app` の起動経路と `AppDelegate` の配線はその外側で、隔離した使い捨てインスタンスを起こす `sandbox-run`（`.claude/skills/`）が同じ形の煙探知を通す。再起動の orchestration も制御 API の外側に置く——socket はアプリと心中するため、自己再起動は循環になる。

CLI は `orbe-mcp`（MCP ブリッジ）・`orbe-report`（状態報告）・`orb`（ユーザー/AI 向け操作 CLI・[cli](cli.md)）。3 つとも `.app` に同梱される。
