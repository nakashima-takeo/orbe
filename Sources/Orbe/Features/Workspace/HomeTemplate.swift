/// Home の root に置くファイルの雛形。画面の文言ではなくファイルの中身なので、UI 文言の辞書には載せない。
enum HomeTemplate {
  /// Orbe の MCP の使い方（Orbe が持ち、起動のたびに書き直す）。Home で動く claude 全員——秘書もタスクの作業場で動く
  /// claude も——が読むので、秘書の役割は書かない（秘書の役割は秘書の会話を起こすときにだけ渡す）。codex・agy は読まない。
  static func rules(_ language: Language) -> String {
    switch language {
    case .ja: return rulesJa
    case .en: return rulesEn
    }
  }

  /// 人と AI が自由に書く欄（フォルダを作るときに 1 回だけ置く）。
  static func claudeMd(_ language: Language) -> String {
    switch language {
    case .ja: return claudeMdJa
    case .en: return claudeMdEn
    }
  }

  private static let rulesJa = """
    # Orbe の操作

    このフォルダの上は Orbe の Home（workspace の 1 つで、リポジトリに属さないタスクの居場所）です。自分の作業ディレクトリかその祖先が root の workspace が Home \
    です。`tasks/<ID>-…/` は Home のタスクの作業場です。

    ## タスク

    - 読み書きは Orbe の MCP ツール `list_tasks`・`add_task`・`update_task`・`move_task` で行う。
    - `add_task` は workspaceId を省くと、呼び出し元タブの workspace（ここなら Home）に付く。

    ## 作業を始める

    - `start_task`（MCP だけ。orb には無い）。リポジトリの workspace のタスクは worktree を、Home のタスクは `tasks/` の下のフォルダを用意し、そこで \
    agent を開く。
    - workspace の無いタスクには、先に `update_task` で workspaceId を付ける。

    ## 待ちの条件と受信

    - 待っているタスクが解ける条件（説明・確認のコマンド・間隔・期限）は `set_wait_condition` で付ける。Orbe が確認のコマンドを人の承認なしに裏で\
    繰り返し走らせ、満たすか期限が来たら待ちを外す。
    - 外の出どころから定期的に拾って提案にするのは受信（`set_intake`・`list_intakes`・`run_intake`・\
    `pause_intake`・`delete_intake`・`list_intake_proposals`）。

    ## タブと agent

    - `list_tabs`・`get_tab_text`・`prompt_agent`・`wait_for_event`。
    - `spawn_agent`・`spawn` は workspaceId を省くとアクティブな workspace に開く。

    MCP が使えなければ `orb` CLI を使う（`orb --help`。`start_task` は無い）。

    このファイルは Orbe が起動のたびに書き直す。書き足したいことは CLAUDE.md に書く。

    """

  private static let rulesEn = """
    # Operating Orbe

    The folder above is Orbe's Home (one of the workspaces; the place for tasks that belong to no \
    repository). The workspace whose root is your working directory or one of its ancestors is Home. \
    `tasks/<ID>-…/` are the workplaces of Home's tasks.

    ## Tasks

    - Read and write tasks with Orbe's MCP tools `list_tasks`, `add_task`, `update_task`, and `move_task`.
    - Without workspaceId, `add_task` attaches the task to the calling tab's workspace (Home, when called \
    from here).

    ## Starting work

    - `start_task` (MCP only; not in orb). For a task in a repository workspace it prepares a worktree; for \
    a Home task it prepares a folder under `tasks/`; then it opens an agent there.
    - For a task without a workspace, attach one first with `update_task` (workspaceId).

    ## Waiting conditions and intakes

    - Attach the condition that ends a wait (description, check command, interval, deadline) with \
    `set_wait_condition`. Orbe runs the check command in the background, repeatedly and without asking the \
    user, and clears the wait when it holds or the deadline comes.
    - To pick things up from outside sources on a schedule and turn them into proposals, use intakes \
    (`set_intake`, `list_intakes`, `run_intake`, `pause_intake`, `delete_intake`, `list_intake_proposals`).

    ## Tabs and agents

    - `list_tabs`, `get_tab_text`, `prompt_agent`, `wait_for_event`.
    - Without workspaceId, `spawn_agent` and `spawn` open in the active workspace.

    If MCP is unavailable, use the `orb` CLI (`orb --help`; it has no `start_task`).

    Orbe rewrites this file at every launch. Put your own additions in CLAUDE.md.

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
