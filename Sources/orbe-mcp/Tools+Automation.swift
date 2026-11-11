import Foundation
import OrbeAutomationReference

// 自動化の 9 動詞の MCP ツール定義。説明は英語で、各ツールの説明は、そのツールの 1 文（呼び方・引数・返すもの）の後ろに
// 共有の節（`AutomationReference`）を 1 つ続けて組む。どの節をどのツールに載せるかは 1 対 1 に決めてある（定義の節は
// `set_automation` だけ、など）。`tools/list` は Orbe のプラグインの入ったすべての claude の文脈に載るので、同じ節を 2 つの
// ツールに載せず、ほかのツールはその節を載せたツールを名指しする。候補をタスクにする・捨てる操作は人が判断するので、その
// ツールは AI に出さない。

private func described(_ sentence: String, _ section: String) -> String {
  sentence + "\n\n" + section
}

let automationTools: [[String: Any]] = [
  obj([
    ("name", "list_automations"),
    (
      "description",
      described(
        "Lists the automations in id order as {automations}. An automation is a graph of nodes "
          + "that fetch from outside on their own schedules and process, judge into task "
          + "candidates, report, do work with tools, or run side effects; `set_automation` "
          + "describes the definition, `list_automation_runs` the run records.",
        AutomationReference.nodeState)
    ),
    ("inputSchema", schema([:])),
  ]),
  obj([
    ("name", "set_automation"),
    (
      "description",
      described(
        "Creates an automation, or replaces the whole definition of `automationId` with the "
          + "`version` read from `list_automations`, and returns it as {automation} in the "
          + "`list_automations` shape. Before writing a new or changed definition, run it with "
          + "`try_automation` and show the result to the user. A new automation runs when its "
          + "schedules come; `run_automation` runs it now. orb automation --help also shows an "
          + "example definition.",
        AutomationReference.definition)
    ),
    (
      "inputSchema",
      schema(
        [
          "automationId": intProp("The automation to rewrite (leave it out to create one)"),
          "version": intProp(
            "The version the rewrite is based on (`version` in `list_automations`; required "
              + "with `automationId`)"),
          "definition": [
            "type": "object",
            "description": "The whole definition {name, notify?, workspace?, nodes}",
          ],
        ], required: ["definition"])
    ),
  ]),
  obj([
    ("name", "list_automation_runs"),
    (
      "description",
      described(
        "Returns the run records of an automation newest first as {runs, next?}, only those of "
          + "`nodeKey` when given. Pass `next` as `before` for the next page.",
        AutomationReference.runRecord)
    ),
    (
      "inputSchema",
      schema(
        [
          "automationId": intProp("The automation to read"),
          "nodeKey": strProp("Only this node's runs (leave it out for every node)"),
          "before": intProp("Runs before this `recordId` (`next` of the previous page)"),
          "limit": intProp("How many runs (default 20, max 100)"),
        ], required: ["automationId"])
    ),
  ]),
  obj([
    ("name", "run_automation"),
    (
      "description",
      described(
        "Flows the automation now up to `nodeKey` (every end node when it is left out) and "
          + "returns at once ({ok}).",
        AutomationReference.flow)
    ),
    (
      "inputSchema",
      schema(
        [
          "automationId": intProp("The automation to run"),
          "nodeKey": strProp("The node to flow to (leave it out for every end node)"),
        ], required: ["automationId"])
    ),
  ]),
  obj([
    ("name", "try_automation"),
    (
      "description",
      described(
        "Starts a trial and returns at once as {trial}; read it with `get_automation_trial` by "
          + "`trial.trialId`. Pass `automationId` alone for the saved definition, `definition` "
          + "alone for a new one, or `automationId`, `version` and `definition` for a rewrite. "
          + "`from` and `to` give the range, `rows` the rows for the entry, and `limit` the cap on "
          + "new rows of each root fetch.",
        AutomationReference.trial)
    ),
    (
      "inputSchema",
      schema(
        [
          "automationId": intProp(
            "The automation to try (leave it out to try `definition` as a new automation)"),
          "version": intProp(
            "The version the rewrite is based on (required with `automationId` and `definition`)"),
          "definition": [
            "type": "object",
            "description": "The definition to try before writing it (the same shape as in "
              + "`set_automation`)",
          ],
          "from": strArrayProp("Entry node keys"),
          "to": strArrayProp("Target node keys"),
          "rows": [
            "type": "array", "items": ["type": "object"],
            "description": "Rows (JSON objects) to give the entry",
          ],
          "limit": intProp("The most new rows each root fetch passes on"),
        ])
    ),
  ]),
  obj([
    ("name", "get_automation_trial"),
    (
      "description",
      described(
        "Reads a trial by `trialId` as {trial, timedOut?}; while it runs, with the runs finished "
          + "so far. With `wait` true it waits until the trial ends, up to `timeoutMs` (default "
          + "3600000, max 86400000), and then returns the trial as it is with `timedOut` true. "
          + "Pass `timeoutMs` explicitly: the MCP client's tool timeout may be shorter.",
        AutomationReference.trialResult)
    ),
    (
      "inputSchema",
      schema(
        [
          "trialId": intProp("The trial to read (`trial.trialId` of `try_automation`)"),
          "wait": boolProp("true to wait until the trial ends"),
          "timeoutMs": intProp("How long to wait, in milliseconds (default 3600000)"),
        ], required: ["trialId"])
    ),
  ]),
  obj([
    ("name", "pause_automation"),
    (
      "description",
      described(
        "Pauses the automation when `paused` is true and resumes it when false, or only the node "
          + "`nodeKey`, and returns it as {automation}.",
        AutomationReference.pause)
    ),
    (
      "inputSchema",
      schema(
        [
          "automationId": intProp("The automation"),
          "nodeKey": strProp("Only this node (leave it out for the automation)"),
          "paused": boolProp("true to pause, false to resume"),
        ],
        required: ["automationId", "paused"])
    ),
  ]),
  obj([
    ("name", "delete_automation"),
    (
      "description",
      "Deletes the automation and returns {ok}. Its running runs stop and their results are "
        + "discarded, all its proposals are forgotten (other automations' proposals stay), and its "
        + "notifications are withdrawn from Notification Center."
    ),
    (
      "inputSchema",
      schema(["automationId": intProp("The automation to delete")], required: ["automationId"])
    ),
  ]),
  obj([
    ("name", "list_automation_proposals"),
    (
      "description",
      described(
        "Returns the proposals of the judges as {proposals}, only those of `automationId` when "
          + "given. Read them to tune a judge's instruction.",
        AutomationReference.proposals)
    ),
    (
      "inputSchema",
      schema(["automationId": intProp("Only the proposals of this automation")])
    ),
  ]),
]
