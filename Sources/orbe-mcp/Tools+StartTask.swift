import Foundation

/// タスクから作業を始める動詞（`start_task`）の MCP ツール定義。orb には出さない。
let startTaskTools: [[String: Any]] = [
  obj([
    ("name", "start_task"),
    (
      "description",
      "タスクの作業に agent を取り掛からせる。作業場を用意し、タスクを進行中にしてその作業場を付け、そこで agent の"
        + "タブを開く（前面化も選択もしない）。作業場はタスクの workspace で決まる——リポジトリの workspace のタスクは"
        + "⌘T の「タスクから開く」と同じ規則で worktree を用意する（タスクの worktree → 主が Issue なら issue/<番号>"
        + " → PR なら head のブランチ。手元に無ければ既定ブランチから作り、遅れたローカルブランチは fast-forward する）。"
        + "Home のタスクは Home の tasks/<ID>-<短い名前>/ のフォルダを作業場にする（2 回目からは同じフォルダ）。"
        + "workspace の無いタスクは拒否されるので、先に update_task で workspaceId を付ける。"
        + "ブランチが決まらなければ branch（と必要なら repo）を渡す。主の Issue・PR のリポジトリを指す remote が"
        + "無いリポジトリは「repository mismatch」で拒否される。prompt は agent の最初の入力になる"
        + "（Home のタスクではタスクの ID・タイトル・詳細に添えて渡す）。作業場ができてタブを開いた時点で返り、"
        + "agent の準備は待たない。返り値は task・workdir・created（作業場を新しく作ったか）・tabId・workspaceId・"
        + "agent{command,path}、リポジトリのタスクなら repo と branch。"
    ),
    (
      "inputSchema",
      schema(
        [
          "taskId": intProp("始めるタスク"),
          "branch": strProp("作業のブランチ（リポジトリのタスク。省略でタスクから決める）"),
          "repo": strProp(
            "リポジトリの中の絶対パス（リポジトリのタスクに worktree が無いときだけ読む。省略で workspace の root）"),
          "agent": strProp("起こす agent の command（省略でその workspace の既定）"),
          "prompt": strProp("agent への最初の入力"),
        ], required: ["taskId"])
    ),
  ])
]
