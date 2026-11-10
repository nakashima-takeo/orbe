extension AutomationReference {
  /// 試走の振る舞い（MCP では `try_automation` の説明に載せる）。
  public static let trial = """
    TRIALS
    A trial checks nodes without touching the real automation. Orbe copies the automation \
    database and runs the same flow as a real one on the copy: the nodes really run, read their \
    rows the real way and settle on the copy, and nothing is written to the real database (read \
    positions, rows, proposals, runs and marks stay as they were). The real downstream does not \
    wake, and nobody is notified.
    - What to try: a saved automation; a rewrite of one (the definition you would write, with the \
    version you read); or a new definition. A definition to try passes the same checks as writing \
    it and is refused with the same errors, before anything runs. A rewrite is first applied to \
    the copy the way writing it would be (added nodes, changed behavior, withdrawals). Runs that \
    writing it would start at once, such as `arrival` nodes with rows to take and schedules \
    already due, happen next and are marked `atWrite`; then the flow starts. When the real \
    version moves on while copying, the trial ends with the same version error as a rewrite.
    - Range: entry nodes and target nodes, by key. The path is the nodes that are an entry or below \
    one, and a target or above one. Without entries, it starts at the nodes without `from` among \
    the targets' ancestors; without targets, it ends at every end node the entries reach. For one \
    node, give it as both. Only path nodes run at the moment of writing; to see all that \
    writing would start, give no range.
    - Nodes on the path with no input on the path run at once, whatever their trigger; one with \
    `from` reads its upstream rows on the copy as its next real run would. The others run as in a \
    flow. Schedules do not come during a trial.
    - Fetches really run. A fetch command, or a writing tool given to a fetch agent, acts outside \
    during a trial too. Agents cost what they cost in a real run, and trials share the agent slots \
    with real runs.
    - Side effect and work nodes are held: each run that would start them takes its rows and \
    returns them as `held`, without starting the method. The rows count as read, as when a real \
    run takes them.
    - Rows to give: allowed only when the path has a single root. For a fetch entry, the rows are \
    its items and the fetch does not run (`given`); for an entry with `from`, they are the output \
    of its single upstream. Items are {"id", "body", "link"?, "time"?}; other rows need a string \
    `id`; each is at most 64 KiB. To try a judge, give rows with `link`. Given rows flow even when \
    the same ids were seen before.
    - A limit caps the new rows each root fetch adds (given rows too); receivers that take `all` \
    still read the older valid rows. Without a limit, a large fetch can make the result larger \
    than 8 MiB and drop the connection.
    - One trial per automation: starting another stops and replaces it. Trials of new definitions \
    are kept up to the newest 10. Results stay in memory until Orbe quits.
    """

  /// 試走の結果の形（MCP では `get_automation_trial` の説明に載せる）。
  public static let trialResult = """
    TRIAL RESULTS
    A trial has `trialId`, `automationId` (trials of a saved automation or a rewrite), `from` and \
    `to` (the resolved entry and target keys), `limit`, `startedAt`, `endedAt`, `running`, \
    `preparing` (while copying), `failure` (why it ended before finishing), and `nodes`, the path \
    in definition order. Each node has `key`, `state` (`waiting`, `running`, `done`, `held`, \
    `given`, or `untouched` when it ended without ever running) and `runs`, newest first. A run is \
    a run record without `recordId` and `nodeKey`, plus `rows` for a fetch or process (the rows it \
    passed on), and `proposals` {`id`, `link`, `title`, `due`, `reason`, `workspaceId`, \
    `workspaceName`} and `resolved` (links) for a judge. A held node's runs are `held` {`rows`}, one \
    per run it would have had (rows are empty for a node without `from`; how runs split may \
    differ from a real run). A given fetch has `given` {`rows`}. Runs and holds from the moment of \
    writing have `atWrite`. Runs the flow started are `now`, even for `arrival` nodes. A run that \
    took no rows is not recorded.
    """
}
