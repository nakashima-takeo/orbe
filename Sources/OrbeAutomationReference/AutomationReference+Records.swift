extension AutomationReference {
  /// 自動化の一覧の要素（MCP では `list_automations` の説明に載せる）。
  public static let nodeState = """
    AUTOMATIONS
    Each automation in the list has `automationId`, `version` (send it with a rewrite), \
    `definition` (as written; each node has its `id`, `agent` is written even when it is the \
    default, an input with neither `take` nor `maxAgeHours` is a key, and a `workspace` is the \
    stored id, also for a removed workspace), `paused`, and `nodes`, keyed by node key:
    - `running`: a run of the node is going.
    - `paused`: the node itself is paused (pausing the automation shows in the automation's \
    `paused`).
    - `nextRunAt`: the next scheduled run; absent while the node or its automation is paused, and \
    for nodes without a schedule; in the past when overdue.
    - `pending`: the rows the node would take now (nodes with `from`).
    - `breach`: the first run that broke the rules, kept until the node's behavior changes: `at`, \
    `lines` {`count`, `lines`, `reasons`} (the number of broken items and the first five, with \
    English `reasons`), and `passed` (whether that run still succeeded).
    - `lastRun`: the latest run, in the run record shape, except that a report or work result has \
    only `summary`, its first line; read the run records for the full `text`.
    - `accepted` and `dismissed` (judges): proposals of the node's current definition that people \
    took as tasks or dismissed.
    An automation with a judge also has `taskCandidates` {`openProposals`}, the proposals waiting \
    for people. An automation whose definition cannot be read has only `automationId`, `version`, \
    `definition` (what could be read) and `definitionError`; fix it by rewriting it with that \
    version, or delete it.
    """

  /// 回の記録（MCP では `list_automation_runs` の説明に載せる）。
  public static let runRecord = """
    RUN RECORDS
    Each run of a node is recorded, newest first: `recordId`, `nodeKey`, `startedAt`, `endedAt` \
    (UTC), `trigger` (`schedule`, `now` for a run a flow started, or `arrival`), and:
    - `taken`: rows the run took (nodes with `from`); `dropped`: rows dropped, by reason \
    (`expired`, `closed` for links the judge settled, `replaced`, `overflow`, and `lapsed` for \
    events that passed their window before being read).
    - `execution` {`commandLine`, `end`, `ending`, `count`}: how the method ended (`ending` in \
    English) and what it gave: items for a fetch, rows for a process or judge, 1 when a report or \
    work has text, rows passed on stdin for a side effect.
    - `breach` {`count`, `lines`, `reasons`}: output refused because it broke the rules.
    - `result` (absent when the run failed): `kind` `fetch` or `process` {`fresh`, `duplicates`} \
    (new rows passed on, events not added again), `judge` {`proposed`, `resolved`, `dismissed`, \
    `rejected`} (`dismissed` lists {`link`, `why`} proposals dropped when settling, `why` being \
    `alreadyProposed`, `noLongerCurrent` or `noOpenProposal`, and `rejected` {`count`, `reasons`} \
    says the same in English), `report` {`summary`, `text`} (absent when there was nothing to \
    report), `sideEffect` {`count`}, `work` {`summary`, `text`, `nothing`} (`nothing` gives the \
    reason when there was nothing to do).
    - `withdrawn`: proposals that went away with this run.
    - `failed` and `failure`: why the run failed (`failure` in English). A failed run moves \
    nothing, so read `failure` and the `reasons` to see where it broke.
    A run that took no rows does not start the method and is not recorded. A record that cannot be \
    read has only `recordId`, `nodeKey`, `startedAt`, `endedAt`, `trigger`, `failed` (true or \
    false) and `unknown`. Each node keeps the runs that are among its newest N or started within D \
    days (settings, 20 runs and 7 days by default), and also its latest good run, the run of its \
    `breach`, and runs that made proposals still remembered.
    """

  /// 候補（MCP では `list_automation_proposals` の説明に載せる）。
  public static let proposals = """
    PROPOSALS
    Every proposal Orbe remembers, in any state: `proposalId`, `state` (`open` waits for people, \
    `accepted` became the task `taskId`, `dismissed`, `resolved` by its judge), `title`, `due`, \
    `reason`, `link`, `body` and `time` (from the row the judge read), `proposedAt`, `nodeKey` (the \
    judge), `originNodeKey` (the node the row came from), `automationId` and `automationName`, and \
    `workspaceId` and `workspaceName` when it is attached to a current workspace (otherwise the \
    task goes to Home). A proposal whose values cannot be read has only `proposalId`, `link` and \
    `unreadable`. People take or dismiss proposals in Orbe; AI cannot.
    """
}
