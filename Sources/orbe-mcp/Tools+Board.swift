import Foundation

// ボードの部品の 3 動詞の MCP ツール定義。宛先は list_workspaces の hasBoard で選ばせ、どの workspace がボードを持つかを
// 説明に書かない（ボードが他の workspace に広がっても説明を書き直さずに済む）。

private let boardIntro =
  "ボードは workspace の画面で、ターミナルのタブとは別の 1 枚。宛先は list_workspaces で hasBoard が true の workspace"
  + "（それ以外は断られる）。部品の種類は automation（自動化の部品: 依頼の欄・一覧・右の欄）だけ。"

private let boardChange =
  "人の選択・焦点・前面の workspace は動かさない。開いていればボードにすぐ映り、再起動しても残る。"
  + "応答は結果の部品の並び {parts: [{kind}]}。"

private func boardTarget(_ verb: String) -> [String: Any] {
  intProp("\(verb) workspace の id（list_workspaces で hasBoard が true のもの）")
}

let boardTools: [[String: Any]] = [
  obj([
    ("name", "list_board_parts"),
    (
      "description",
      boardIntro + "ボードの部品の並びを上から順に返す {parts: [{kind}]}。何も決めていないボードは automation 1 つ。"
    ),
    ("inputSchema", schema(["workspaceId": boardTarget("読む")], required: ["workspaceId"])),
  ]),
  obj([
    ("name", "add_board_part"),
    (
      "description",
      boardIntro + "部品をボードの末尾に置く。1 つのボードに同じ種類は 1 つまでで、既にあれば何も変えずに成功する。"
        + boardChange
    ),
    (
      "inputSchema",
      schema(
        ["workspaceId": boardTarget("置く"), "kind": strProp("部品の種類（automation）")],
        required: ["workspaceId", "kind"])
    ),
  ]),
  obj([
    ("name", "remove_board_part"),
    (
      "description",
      boardIntro + "部品をボードから外す。無ければ何も変えずに成功する。automation を外しても自動化そのもの"
        + "（list_automations）は消えず、add_board_part で 1 回で戻せる。" + boardChange
    ),
    (
      "inputSchema",
      schema(
        ["workspaceId": boardTarget("外す"), "kind": strProp("部品の種類（automation）")],
        required: ["workspaceId", "kind"])
    ),
  ]),
]
