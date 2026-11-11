extension AutomationReference {
  /// 自動化の一覧の要素（MCP では `list_automations` の説明に載せる）。
  public static let nodeState = """
    AUTOMATIONS
    Each automation in the list has `automationId`, `version` (send it with a rewrite), \
    `definition` (as stored; each node has its `id`, `agent` is written even when it is the \
    default, an input that takes `new` and has no `maxAgeHours` is a key, and a `workspace` is \
    the stored id, also for a removed workspace), `paused`, and `nodes`, keyed by node key:
    - `running`: a run of the node is going.
    - `paused`: the node itself is paused (pausing the automation shows in the automation's \
    `paused`).
    - `nextRunAt`: the next scheduled run; absent while the node or its automation is paused, and \
    for nodes without a schedule; in the past when overdue.
    - `pending`: the number of rows the node would take now (nodes with `from`).
    - `breach`: the first run that broke the rules, kept until the node's behavior changes: `at`, \
    `lines` {`count`, `lines`, `reasons`} (the number of broken items and the first five, with \
    English `reasons`), and `passed` (whether that run still succeeded).
    - `lastRun`: the latest run, a run record without `nodeKey` (the node is its key in `nodes`) \
    and without the full `text` of a report or work result. It keeps the other fields, such as \
    `recordId`, `summary` (the first line of the text, up to 500 characters) and the `nothing` of \
    work; read the run records for the full `text`.
    - `accepted` and `dismissed` (judges): the numbers of proposals of the node's current \
    definition that people took as tasks or dismissed.
    An automation with a judge also has `taskCandidates` {`openProposals`}, the number of \
    proposals waiting for people. An automation whose definition cannot be read has only `automationId`, `version`, \
    `definition` (what could be read) and `definitionError`; fix it by rewriting it with that \
    version, or delete it.
    """

  /// 回の記録（MCP では `list_automation_runs` の説明に載せる）。
  public static let runRecord = """
    RUN RECORDS
    Each run of a node is recorded, newest first: `recordId`, `nodeKey`, `startedAt`, `endedAt` \
    (UTC), `trigger` (`schedule`, `now` for a run a flow started, or `arrival`), and:
    - `taken`: the number of rows the run took (nodes with `from`); `dropped`: the number of rows \
    dropped, by reason \
    (`expired`, `closed` for links of the judge's proposals that are not open, `replaced`, \
    `overflow`, and `lapsed` for events that passed their window before being read).
    - `execution` {`commandLine`, `end`, `ending`, `count`}: how the method ended (`ending` in \
    English) and what it gave: items for a fetch, rows for a process, proposals and resolves for a \
    judge, 1 when a report or work has text, rows passed on stdin for a side effect.
    - `breach` {`count`, `lines`, `reasons`}: output refused because it broke the rules (the count \
    and the first five).
    - `result` (absent when the run failed): `kind` `fetch` or `process` {`fresh`, `duplicates`} \
    (the numbers of new rows passed on and of events not added again), `judge` {`proposed`, `resolved`, `dismissed`, \
    `rejected`} (`dismissed` lists {`link`, `why`} proposals dropped when settling, `why` being \
    `alreadyProposed`, `noLongerCurrent` or `noOpenProposal`, and `rejected` {`count`, `reasons`} \
    gives their count and the English of the first five), `report` {`summary`, `text`} (both \
    absent when there was nothing to report), `sideEffect` {`count`}, `work` {`summary`, `text`, \
    `nothing`} (`nothing` gives the reason when there was nothing to do).
    - `withdrawn`: the number of proposals that went away with this run; on a judge, of those whose \
    events passed `retentionDays` since its last good run.
    - `failed` and `failure`: why the run failed (`failure` in English). A failed run moves \
    nothing, so read `failure` and the `reasons` to see where it broke.
    A node with no rows to take does not start its method and records no run, except a \
    `currentSet` process, which runs to copy an empty input. A record that cannot be \
    read has only `recordId`, `nodeKey`, `startedAt`, `endedAt`, `trigger`, `failed` (true or \
    false) and `unknown`. Each node keeps the runs that are among its newest N or started within D \
    days (settings, 20 runs and 7 days by default), and also its latest good run, the run of its \
    `breach`, and runs that made proposals still remembered or still in people's decision records.
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
