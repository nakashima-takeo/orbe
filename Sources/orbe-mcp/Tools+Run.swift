import Foundation

// 裏で動く agent に Orbe が渡すときだけ出す道具（環境の ORBE_RUN_TOKEN がその回の札、ORBE_RUN_TOOLS がその回で出す道具の
// 名前）。ほかのツールは出さない——札の回の入力を読み結果を出すだけの口にするため。札は agent に見せず、ブリッジが添える。
// 呼び出しは control の `run_tool` へ渡し、確かめと答えは Orbe 本体が持つ。

private let itemArray = { (desc: String) -> [String: Any] in
  ["type": "array", "items": ["type": "object"], "description": desc]
}

let runTools: [[String: Any]] = [
  obj([
    ("name", "read_run_rows"),
    // claude は道具の 1 回の結果が閾値を超えるとファイルに書き出し、agent には読めないパスだけを見せる。1 ページは Orbe が
    // 大きさで切り、行 1 つは書く場で上限に収めてあるので、閾値をページより十分大きくする。
    ("_meta", ["anthropic/maxResultSizeChars": 500_000]),
    (
      "description",
      "Returns a page of the input items of this run, one JSON object per line, from offset (0 is the first item). "
        + "The first block says the total, the offset, the count and next (the offset to continue from; absent "
        + "at the end). Call it again from next until there is no next."
    ),
    (
      "inputSchema",
      schema([
        "offset": intProp("where to start (0 is the first item; default 0)"),
        "limit": intProp(
          "how many items at most (1 to 100; default 50; a page also stops at about 48 KiB)"),
      ])
    ),
  ]),
  obj([
    ("name", "read_waiting_proposals"),
    (
      "description",
      "Returns the task proposals already waiting for the user, one JSON object per line ({link, title, due?}), "
        + "or (none)."
    ),
    ("inputSchema", schema([:])),
  ]),
  obj([
    ("name", "read_workspaces"),
    (
      "description",
      "Returns the workspaces a proposal can be attached to, one JSON object per line ({workspace, name, root}), "
        + "or (none). Home is not listed: omit workspace for Home."
    ),
    ("inputSchema", schema([:])),
  ]),
  obj([
    ("name", "put_items"),
    (
      "description",
      "Gives Orbe fetched items: {id, link, body, time} each (extra fields are kept; an item is at most 64 KiB). "
        + "Orbe checks every item; if any is wrong it accepts none of this call and says what to fix."
    ),
    ("inputSchema", schema(["items": itemArray("the items")], required: ["items"])),
  ]),
  obj([
    ("name", "put_rows"),
    (
      "description",
      "Gives Orbe output items, one JSON object each with a string id (an item is at most 64 KiB). Orbe checks "
        + "every item; if any is wrong it accepts none of this call and says what to fix."
    ),
    ("inputSchema", schema(["rows": itemArray("the output items")], required: ["rows"])),
  ]),
  obj([
    ("name", "propose"),
    (
      "description",
      "Proposes tasks: {id, title, due?, workspace?, reason?} each, where id is a new item's id. Orbe checks every "
        + "proposal; if any is wrong it accepts none of this call and says what to fix."
    ),
    ("inputSchema", schema(["proposals": itemArray("the proposals")], required: ["proposals"])),
  ]),
  obj([
    ("name", "resolve"),
    (
      "description",
      "Marks waiting proposals as already dealt with, by their links. If any link is not a waiting proposal, "
        + "Orbe accepts none of this call."
    ),
    (
      "inputSchema",
      schema(["links": strArrayProp("links of waiting proposals")], required: ["links"])
    ),
  ]),
  obj([
    ("name", "put_report"),
    (
      "description", "Gives Orbe the report (plain text). Giving it again replaces the earlier one."
    ),
    ("inputSchema", schema(["text": strProp("the report")], required: ["text"])),
  ]),
  obj([
    ("name", "report_nothing"),
    (
      "description",
      "Tells Orbe there is no result this time, and why. Only before giving any result."
    ),
    ("inputSchema", schema(["why": strProp("why there is nothing")], required: ["why"])),
  ]),
  obj([
    ("name", "report_error"),
    ("description", "Tells Orbe this run could not be done, and what went wrong. The run fails."),
    ("inputSchema", schema(["what": strProp("what went wrong")], required: ["what"])),
  ]),
]
