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

    - `list_board_widgets`・`add_board_widget`・`remove_board_widget`。\
    workspaceId は Home の id（`list_workspaces` で hasBoard が true のもの）。
    - ウィジェットは `automation`（自動化の一覧と依頼の欄）。外しても自動化そのものは消えず、置けば戻る。

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

    - `list_board_widgets`, `add_board_widget`, `remove_board_widget`. workspaceId is Home's id (the one with \
    hasBoard true in `list_workspaces`).
    - The widget is `automation` (the automation list and its request field). Removing it keeps the \
    automations themselves; adding it brings the widget back.

    ## Operate tabs and agents

    - `list_tabs`, `get_tab_text`, `prompt_agent`, `wait_for_event`.
    - Without workspaceId, `spawn_agent` and `spawn` open in the active workspace.

    If MCP is unavailable, use the `orb` CLI (`orb --help`; it has no `start_task`).

    Orbe rewrites this file at every launch. Put your own additions in CLAUDE.md.

    """
  }

  /// 自動化の節。索引だけを持ち、定義の形と仕組みは MCP の `set_automation` の説明に、進め方は同梱の自動化のスキルに任せる。
  private static let automationJa = """
    ## 予定どおり外から取得し、判定してタスクの候補にする・報告する・コマンドを走らせる・agent に作業をさせる

    - 自動化（`list_automations`・`set_automation`・`try_automation`・`get_automation_trial`・`run_automation`・\
    `list_automation_runs`・`pause_automation`・`delete_automation`・`list_automation_proposals`）。
    - 自動化はノード（取得・処理・判定・報告・作業・外部操作）をつないだグラフで、ノードごとの予定で動く。判定が出した候補は、\
    人が ⌘⇧X の提案タブで受けたものだけがタスクになる。
    - 作る・直すときは、Orbe のプラグインの automation スキルの手順で進める。定義の形と仕組みは `set_automation` の説明にある。

    Orbe の中で予定どおり繰り返し動くのは、待ちの条件の確認と自動化の 2 つ。
    """

  private static let automationEn = """
    ## On a schedule, pick things up from outside and judge them into task candidates, report, run a \
    command, or have an agent do work

    - Automations (`list_automations`, `set_automation`, `try_automation`, `get_automation_trial`, \
    `run_automation`, `list_automation_runs`, `pause_automation`, `delete_automation`, \
    `list_automation_proposals`).
    - An automation is a graph of nodes (fetch, process, judge, report, work, side effect), each running \
    on its own schedule. Only proposals the user accepts in the Proposals tab of ⌘⇧X become tasks.
    - To create or edit one, follow the automation skill of Orbe's plugin. The definition and how it \
    works are in the description of `set_automation`.

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
