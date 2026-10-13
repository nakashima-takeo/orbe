/// Home の root に置くファイルの雛形。画面の文言ではなくファイルの中身なので、UI 文言の辞書には載せない。
enum HomeTemplate {
  /// Orbe の MCP の使い方（Orbe が持ち、起動のたびに書き直す）。Home で動く claude 全員——秘書の係が起こす claude も
  /// タスクの作業場で動く claude も——が読むので、役目は書かない（役目は秘書の係が起こすときにだけ渡す）。codex・agy は読まない。
  /// `home` は Home の root。AI が `list_workspaces` から Home を一意に見分ける手掛かり（root の祖先かどうかでは、
  /// root が `~` の default workspace も当てはまる）。
  static func rules(_ language: Language, home: String) -> String {
    switch language {
    case .ja: return rulesJa(home)
    case .en: return rulesEn(home)
    }
  }

  /// 人と AI が自由に書く欄（フォルダを作るときに 1 回だけ置く）。
  static func claudeMd(_ language: Language) -> String {
    switch language {
    case .ja: return claudeMdJa
    case .en: return claudeMdEn
    }
  }

  private static func rulesJa(_ home: String) -> String {
    """
    # Orbe の操作

    Orbe の Home（workspace の 1 つで、リポジトリに属さないタスクの居場所）の root は `\(home)` です。`list_workspaces` の \
    rootPath がこのパスの workspace が Home です。`tasks/<ID>-…/` は Home のタスクの作業場です。

    「Orbe で〜できる？」と聞かれたら、まず下のやりたいことの一覧から Orbe の機能で答える。

    ## タスクを足す・直す

    - `list_tasks`・`add_task`・`update_task`。
    - `add_task` は workspaceId を省くと、呼び出し元タブの workspace（ここなら Home）に付く。

    ## タスクに作業を始めさせる

    - `start_task`（MCP だけ。orb には無い）。リポジトリの workspace のタスクは worktree を、Home のタスクは `tasks/` の下の\
    フォルダを用意し、そこで agent を開く。
    - workspace の無いタスクには、先に `update_task` で workspaceId を付ける。

    ## 何かが起きるまで待つ（レビュー・返事・ビルドなど）

    - タスクを待ちにし、解ける条件（説明・確認のコマンド・間隔・期限）を `set_wait_condition` で付ける。
    - Orbe が確認のコマンドを人の承認なしに裏で予定どおり繰り返し走らせ、満たすか期限が来たら待ちを外して人に知らせる。

    \(automationJa)

    ## Home のボード（画面）に出すものを変える

    - `list_board_parts`・`add_board_part`・`remove_board_part`。workspaceId は Home の id（`list_workspaces` で hasBoard が \
    true のもの）。
    - 部品は `automation`（自動化の一覧と依頼の欄）。外しても自動化そのものは消えず、置けば戻る。

    ## タブと agent を操作する

    - `list_tabs`・`get_tab_text`・`prompt_agent`・`wait_for_event`。
    - `spawn_agent`・`spawn` は workspaceId を省くとアクティブな workspace に開く。

    MCP が使えなければ `orb` CLI を使う（`orb --help`。`start_task` は無い）。

    このファイルは Orbe が起動のたびに書き直す。書き足したいことは CLAUDE.md に書く。

    """
  }

  private static func rulesEn(_ home: String) -> String {
    """
    # Operating Orbe

    The root of Orbe's Home (one of the workspaces; the place for tasks that belong to no repository) \
    is `\(home)`. Home is the workspace whose rootPath in `list_workspaces` is this path. \
    `tasks/<ID>-…/` are the workplaces of Home's tasks.

    When asked "can Orbe do …?", answer first with Orbe's own features from the list of things to do below.

    ## Add and edit tasks

    - `list_tasks`, `add_task`, `update_task`.
    - Without workspaceId, `add_task` attaches the task to the calling tab's workspace (Home, when called \
    from here).

    ## Have an agent start work on a task

    - `start_task` (MCP only; not in orb). For a task in a repository workspace it prepares a worktree; for \
    a Home task it prepares a folder under `tasks/`; then it opens an agent there.
    - For a task without a workspace, attach one first with `update_task` (workspaceId).

    ## Wait until something happens (a review, a reply, a build, …)

    - Put the task in waiting and attach the condition that ends the wait (description, check command, \
    interval, deadline) with `set_wait_condition`.
    - Orbe runs the check command in the background on schedule, repeatedly and without asking the user, \
    and clears the wait and notifies the user when it holds or the deadline comes.

    \(automationEn)

    ## Change what Home's board (screen) shows

    - `list_board_parts`, `add_board_part`, `remove_board_part`. workspaceId is Home's id (the one with \
    hasBoard true in `list_workspaces`).
    - The part is `automation` (the automation list and its request field). Removing it keeps the \
    automations themselves; adding it brings the part back.

    ## Operate tabs and agents

    - `list_tabs`, `get_tab_text`, `prompt_agent`, `wait_for_event`.
    - Without workspaceId, `spawn_agent` and `spawn` open in the active workspace.

    If MCP is unavailable, use the `orb` CLI (`orb --help`; it has no `start_task`).

    Orbe rewrites this file at every launch. Put your own additions in CLAUDE.md.

    """
  }

  /// 自動化の節。
  private static let automationJa = """
    ## 予定どおり何かを拾い、絞り・判断してタスクの候補にするか、コマンドを走らせるか、報告するか、agent に仕事をさせる

    - 自動化（`set_automation`・`list_automations`・`run_automation`・`pause_automation`・`delete_automation`・\
    `list_automation_proposals`）。
    - トリガー（間隔か毎日の時刻）ごとに、取得元（コマンドか軽い agent）が項目を取り、処理の段（コマンドか agent）が順に\
    絞り・判断して、出力先へ出す。出力先はタスク候補・コマンド・報告・agent の 4 つ。
    - 名前は「出どころ: 何を取るか」の 1 行（例「GitHub: 自分へのレビュー依頼」）。取得元が無ければ、何をするかの 1 行\
    （例「日報の下書き」）。
    - タスク候補: 人が ⌘⇧X の提案タブで受けた候補だけがタスクになる。Slack・メール・課題管理・GitHub などから拾うのが主な使い方。
    - コマンド: 届いた行を標準入力で受けて走る。取得元も段も無ければ、トリガーのたびに走る（例: 毎晩 23 時に \
    `~/bin/daily-note.sh` を実行する）。
    - 報告: 最後の段が書いた短い文章を、その回の結果として残す（例: 毎日 18 時に開いている PR を要約する）。1 行目がボードの\
    見出しと通知に出る。言うことが無ければ何も出さない。
    - agent: 回ごとに裏で使い捨ての claude を起こし、定義の依頼文と名指ししたツールだけで仕事をさせる（例: 毎日 9:00 に、\
    レビュー待ちの PR をまとめて Slack の自分宛てに投稿する）。取得元か段があれば届いた行が 1 行以上ある回だけ、無ければトリガーの\
    たびに起きる。ツールを使って何かをしてほしいときはこれを使い、コマンドの出力先の中で `claude -p` を起こさない（Orbe の\
    絞り込みが掛からない）。応答の 1 行目がボードの見出しと通知に出る。することが無い回は何も出さずに終わり、知らせない。
    - agent の名指しは MCP のツールの完全名か `Bash(<コマンドの接頭>:*)`（例 `Bash(gh search prs:*)`）だけで、最小にする。\
    agent は回ごとに作る空のディレクトリを作業ディレクトリにして起きる（ディレクトリに結び付く登録〔claude の local・project\
    スコープ〕の MCP サーバーは使えない）。Bash の規則だけなら、利用者の設定を読まずに走り、作業ディレクトリの外の読み取りも名指しの\
    規則に従う。MCP を混ぜると、利用者の設定を読むので、利用者が claude で「常に許可」にしたツール（MCP も Bash のコマンドも）と\
    hook も効き、設定の additionalDirectories の下も名指しなしで読める。\
    agent がツールで読んだ外の文面に仕込まれた指示で、名指しした書き込みのツールが使われうる。
    - agent には届いた行も件数も渡らない。対象が要る仕事なら、依頼文で agent 自身に調べさせる。失敗した回は次の回でもう一度\
    起きる（投稿が二重になりうる）。依頼文は automations.json に残るので秘密を書かない。
    - 通知（`notify: "menuBar"` か `"notificationCenter"`）: どの出力先にも付けられる。何かを出した回と、失敗が続くなら最初の\
    失敗の回に、メニューバーか macOS の通知センターへ名前と結果の 1 行が出る。通知センターの通知は自動化ごとに 1 つで、新しい回が\
    差し替える。`notificationCenter` を書くと、Orbe の通知の許可がまだ決まっていなければ OS が許可を問う。許可が無い回は\
    メニューバーに出る。押すと Home のボードでその自動化が開く。省略すると知らせない。

    Orbe の中で予定どおり繰り返し動くのは、待ちの条件の確認と自動化の 2 つ。
    """

  private static let automationEn = """
    ## On a schedule, pick things up into task candidates, run a command, report, or have an agent act

    - Automation (`set_automation`, `list_automations`, `run_automation`, `pause_automation`, \
    `delete_automation`, `list_automation_proposals`).
    - On each trigger (an interval or daily times), the source (a command or a light agent) gets items, the \
    steps (commands or agents) narrow and judge them in order, and the sink receives the result. There are \
    four sinks: task candidates, a command, a report, and an agent.
    - Name it in one line, "<source>: <what it gets>" (e.g. "GitHub: review requests for me"); without a \
    source, say what it does (e.g. "Daily note draft").
    - Task candidates: only candidates the user accepts in the Proposals tab of ⌘⇧X become tasks. The main use \
    is picking things up from Slack, mail, issue trackers, GitHub, and the like.
    - Command: it runs with the lines that reach it on stdin. With neither a source nor steps, it runs on every \
    trigger (e.g. run `~/bin/daily-note.sh` every night at 23:00).
    - Report: the short text the last step writes is kept as the result of the run (e.g. summarize the \
    open PRs every day at 18:00). Its first line shows on the board's heading and in the notification. With \
    nothing to report, the last step prints nothing.
    - Agent: each run starts a throwaway claude in the background that does the job with only the \
    definition's request and the tools it names (e.g. every day at 9:00, post a digest of the PRs waiting for \
    my review to myself on Slack). With a source or steps it starts only when at least one line arrives; \
    without them, on every trigger. Use it when you want something done with tools; never start `claude -p` \
    inside a command sink (Orbe's limits do not apply there). The first line of its reply shows on the \
    board's heading and in the notification. When there is nothing to do, it ends printing nothing, and \
    nobody is notified.
    - An agent may name only full MCP tool names and `Bash(<command prefix>:*)` rules (e.g. \
    `Bash(gh search prs:*)`); name as few as possible. Each run starts in a fresh empty directory (MCP \
    servers registered to a directory, in claude's local and project scopes, are unavailable). With Bash \
    rules only, it runs without reading the user's settings, and reads outside that directory follow the \
    named rules too. Once an MCP tool is named, it reads the user's settings, so the tools the user always \
    allows in claude (MCP tools and Bash commands) and their hooks apply too, and it can read under the \
    settings' additionalDirectories without naming anything. Instructions hidden in outside text the agent \
    reads with its tools can make it use a writing tool it was given.
    - The agent gets neither the lines that arrived nor their count; when the job needs targets, have the \
    agent look them up itself in the request. A failed run starts the agent again on the next run (a post \
    can be doubled). The request stays in automations.json, so never put secrets in it.
    - Notify (`notify: "menuBar"` or `"notificationCenter"`): any sink can have it. When a run delivers \
    something, or on the first of consecutive failed runs, the name and the result line show in the menu bar \
    or in macOS Notification Center. Notification Center keeps one notification per automation; a new run \
    replaces it. Setting `notificationCenter` makes macOS ask for Orbe's notification permission if it is not \
    decided yet; without permission, the run shows in the menu bar. Clicking either opens the automation on \
    Home's board. Omit it to stay silent.

    Inside Orbe, the only things that run repeatedly on schedule are waiting-condition checks and automations.
    """

  private static let claudeMdJa = """
    # Home

    Orbe の操作は `.claude/rules/orbe.md` にあり、Orbe が起動のたびに更新する。

    このファイルは人も AI も自由に書き換えてよい。Orbe は上書きしない。

    """

  private static let claudeMdEn = """
    # Home

    How to operate Orbe lives in `.claude/rules/orbe.md`, which Orbe updates at every launch.

    Both the user and AI may edit this file freely. Orbe never overwrites it.

    """
}
