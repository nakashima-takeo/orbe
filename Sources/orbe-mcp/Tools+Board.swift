import Foundation

// ボードのウィジェットの 3 動詞の MCP ツール定義。宛先は list_workspaces の hasBoard で選ばせ、どの workspace がボードを持つかを
// 説明に書かない（ボードが他の workspace に広がっても説明を書き直さずに済む）。

private let boardIntro =
  "ボードは workspace の画面で、ターミナルのタブとは別の 1 枚。宛先は list_workspaces で hasBoard が true の workspace"
  + "（それ以外は断られる）。ウィジェットの種類は automation（自動化のウィジェット: 依頼の欄・一覧・右の欄）だけ。"

private let boardChange =
  "人の選択・焦点・前面の workspace は動かさない。開いていればボードにすぐ映り、再起動しても残る。"
  + "応答は結果のウィジェットの並び {widgets: [{kind}]}。"

private func boardTarget(_ verb: String) -> [String: Any] {
  intProp("\(verb) workspace の id（list_workspaces で hasBoard が true のもの）")
}

let boardTools: [[String: Any]] = [
  obj([
    ("name", "list_board_widgets"),
    (
      "description",
      boardIntro + "ボードのウィジェットの並びを上から順に返す {widgets: [{kind}]}。何も決めていないボードは automation 1 つ。"
    ),
    ("inputSchema", schema(["workspaceId": boardTarget("読む")], required: ["workspaceId"])),
  ]),
  obj([
    ("name", "add_board_widget"),
    (
      "description",
      boardIntro + "ウィジェットをボードの末尾に置く。1 つのボードに同じ種類は 1 つまでで、既にあれば何も変えずに成功する。"
        + boardChange
    ),
    (
      "inputSchema",
      schema(
        ["workspaceId": boardTarget("置く"), "kind": strProp("ウィジェットの種類（automation）")],
        required: ["workspaceId", "kind"])
    ),
  ]),
  obj([
    ("name", "remove_board_widget"),
    (
      "description",
      boardIntro + "ウィジェットをボードから外す。無ければ何も変えずに成功する。automation を外しても自動化そのもの"
        + "（list_automations）は消えず、add_board_widget で 1 回で戻せる。" + boardChange
    ),
    (
      "inputSchema",
      schema(
        ["workspaceId": boardTarget("外す"), "kind": strProp("ウィジェットの種類（automation）")],
        required: ["workspaceId", "kind"])
    ),
  ]),
]
