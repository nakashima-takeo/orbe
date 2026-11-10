extension AutomationReference {
  /// 定義・役割・行・判定・報告と仕事と副作用・通知・書き換え（MCP では `set_automation` の説明に載せる）。
  public static let definition = """
    DEFINITION
    An automation is a graph of nodes. Each node runs on its own schedule and, at the start of each \
    run, reads the rows its upstream nodes put out, in its own way. Orbe runs the nodes in the \
    background and settles each run on its own. A definition is {name, notify?, workspace?, nodes} \
    and is always replaced whole; unknown keys anywhere in it are refused with their place (such as \
    "unknown nodes[1].inboxLimit").
    - `name`: one line saying what the automation does.
    - `notify`: `menuBar` or `notificationCenter`; leave it out to stay silent (see NOTIFICATIONS).
    - `workspace`: a workspace id that command nodes without their own `workspace` run in. Write it \
    only when such a command node exists.
    - `nodes`: one or more nodes.

    A node is one object holding its own fields, exactly one method (a command or an agent) and \
    what it does with its output.
    - `id`: given by Orbe. Send it back to keep the node; a node without `id` is a new node, and it \
    cannot take the key of a node the same rewrite removes.
    - `key`: 1-32 letters, digits, _ or -, unique in the automation (case-sensitive). It names the \
    node in `from` and when you point at a node. Changing it keeps the node.
    - `name`: one line.
    - `trigger`: `kind` `interval` with `minutes` (1-10080), `cron` with `expression` ("minute hour \
    day month weekday", in the Mac's time zone), `manual` (runs only when a flow points at it or at \
    a node below it), or `arrival` (runs when its inputs have rows to take; needs `from`). An \
    interval node runs that many minutes after its last run, or after it was added, and runs once \
    on waking for a time missed while the Mac slept or Orbe was not running. A cron node runs only \
    at its times and skips missed ones. Cron fields take *, numbers, ranges a-b, step values */n, a-b/n \
    and a/n, and lists with commas; months and weekdays also take names (JAN, MON; weekday 0 and 7 \
    are Sunday). No @daily shorthands and no L W # ?. Leave the day or the weekday as *. An \
    expression that never matches is refused. Weekdays at 9:00 is "0 9 * * 1-5".
    - `from`: the upstream nodes. Each is a key, or an object with `node` (the key), `take` and \
    `maxAgeHours`. `take` is `new` (the default: only rows this node has not received) or `all` \
    (every valid row of that upstream, every run). `maxAgeHours` (at least 1) drops older rows. \
    Both belong to the receiver; the upstream's rows do not change. An input with neither comes \
    back as a key.
    - A command: `command` runs with /bin/sh -c. `directory` is relative to the workspace root \
    ("." for the root) and required when the node runs in a workspace (its own `workspace`, or the \
    automation's); otherwise it is absolute, or left out for the home folder. The root is resolved \
    at the start of each run, and a run whose workspace was removed fails without starting.
    - An agent: `agent` is the CLI (`claude`, the default; no other CLI runs in the background). \
    `model` is required and used as written (a claude alias such as haiku or sonnet works); pick \
    one that fits the work, and a light one for nodes that run often. `instruction` says what to \
    do. `tools` is described in TOOLS. An agent has no `workspace` or `directory`: each run starts \
    in a fresh empty directory, so MCP servers registered to a directory (claude's local and \
    project scopes) are unavailable.
    - `timeoutMinutes`: 1-60; the default is 2 for a command and 10 for an agent. Only the elapsed \
    time counts, not time without output. Estimate heavy nodes (a large fetch, a long job) and \
    write it.
    - `deliver`: left out to pass rows to the next node, or `taskCandidates`, `report`, or `none` \
    (side effects only).
    - `coverage`: what the rows of a fetch or process node are. `currentSet`: each result is the \
    whole set at that time (my open issues). `newArrivals`: a record that only grows (new DMs to \
    me). Required on a fetch; a process node defaults to `newArrivals`; other roles have none. \
    Orbe cannot tell what the outside service returns, so choose by how it behaves.
    - `maxItems`: nodes with `from` only; the most rows one run takes (the newest).
    - `retentionDays`: nodes whose rows are `newArrivals` only; 1-365 (by default the setting, \
    30 days). Within it the same id counts as the same event; older events are no longer \
    delivered. Write it on fetches a judge reads over a long window.

    ROLES
    Orbe derives each node's role from its fields. A node reads rows when it has `from` and no \
    `tools`.
    - fetch: reads no rows (no `from`, or an agent with `tools`) and passes rows on; puts out items.
    - process: reads rows and passes rows on.
    - judge: reads rows and delivers `taskCandidates`; proposes tasks and resolves its proposals.
    - report: has no `tools` and delivers `report`; writes text for people.
    - work: an agent with `tools` that delivers `report`; does a job and reports what it did.
    - side effect: a command that delivers `none`.
    An agent with `tools` never receives upstream rows; with `from`, arriving rows only decide \
    whether it starts. An agent that reads rows gets no `tools`, only Orbe's own tools for reading \
    its input and giving its result. So outside text never reaches an agent that holds tools.
    Also refused: an `arrival` trigger without `from`; a node passing rows on that no `from` \
    names; `from` naming a node that does not pass rows on, an unknown key, or the same key twice; \
    duplicate keys; cycles; `taskCandidates` on a node that does not read rows; `none` on an agent; \
    `coverage` missing on a fetch or written on another role; `retentionDays` on a node whose rows \
    are not `newArrivals`; a `currentSet` process with a `new` input or `maxItems` (it copies its \
    whole input, so it takes `all`); `maxItems` without `from`; a relative `directory` without a \
    workspace, or an absolute one with it; an automation `workspace` no command node uses.

    TOOLS
    Only fetch and work agents have `tools`: full MCP tool names (mcp__<server>__<tool>) and \
    Bash(<command prefix>:*) rules, where the prefix has no , ( ) * or control characters. Bare \
    built-in tools (Bash, Read, Write, Edit and so on), whole servers and wildcards are refused. \
    Name as few as possible.
    - With Bash rules only, claude runs without the user's settings, hooks and MCP servers, and \
    refuses commands that read a file outside its directory given as an argument, even when they \
    match a rule; to read such a file, name a command that reads it, such as a script.
    - Once an MCP tool is named, claude reads the user's settings to reach their MCP servers, so \
    the tools the user always allows in claude (MCP tools and Bash commands) and their hooks apply \
    too, and it can read under the settings' additionalDirectories.
    - Instructions hidden in outside text the agent reads with its tools can make it use any \
    writing tool it was given. Give a fetch agent only tools that read from the service, never ones \
    that send, update or delete, nor Orbe's own tools: the name is checked, not what the tool does.

    ROWS
    A fetch puts out one item per row: {"id", "body", "link"?, "time"?}. `id` stays the same for \
    the same thing in that service, `body` is the text, `link` an http(s) URL, `time` ISO 8601; \
    other fields are kept and passed on. A command prints one JSON object per line, prints nothing \
    when there is nothing, and exits non-zero when it fails; Orbe tells an agent how to give its \
    items. Proposals are made only from rows with `link`, so a fetch that feeds a judge writes \
    `link` on items that may become tasks.
    Downstream, an item's id becomes "<node id>:<written id>", so rows from several fetches never \
    collide. A process row that keeps the `id` of its input row passes on with that row's id. \
    Commands that receive rows see this form; strip the prefix before handing an id to an outside \
    API.
    A process node puts out rows that each have a string `id`, never the same `id` twice. Keep the \
    `id` of each row it passes on, give a new row the same `id` for the same thing on every run, \
    and keep `link` on rows that may become tasks. Orbe tells a process agent how to read its rows \
    and give its output.
    A row may be at most 64 KiB in the form passed downstream; a larger one breaks the rules.

    WHAT A RECEIVER READS
    An upstream keeps its rows once, and each receiver reads them at the start of its own run.
    - `currentSet` rows are items. An item whose content changes stays the same item and is not \
    delivered again to `new` receivers. An item that leaves the result is no longer valid, and \
    one that comes back later is a new item.
    - `newArrivals` rows are events that are only added. The same id within `retentionDays` is not \
    added again (counted as `duplicates`).
    - With `take` `new`, a receiver gets the items and events added since it last read; with `all`, \
    every valid item and every event in the window, on every run (`all` with `maxAgeHours` sums up \
    a recent window each time).
    - Rows are dropped for the first of: older than `maxAgeHours`; for a judge, rows whose `link` it \
    already settled (accepted, dismissed or resolved); an older row with the same downstream id; \
    beyond `maxItems`. Rows with the same `link` are all kept.
    - A receiver takes all its rows in one run, whatever their number and size. Without limits \
    nothing is dropped: while a node keeps failing its unread rows grow, and the next good run \
    takes them all. Write `maxItems` and `maxAgeHours` where cost or freshness matters.
    - A node added later reads every current item of its upstream, but only events created after \
    it was added.
    - A `newArrivals` fetch gets the start of its last successful run: a command as `ORBE_SINCE` \
    (ISO 8601, UTC), an agent as a sentence. Fetch what came after it; overlap is fine (Orbe drops \
    ids it has seen). The first run gets none.
    - A failed run moves nothing: the same rows are read again next time.

    JUDGE
    Orbe gives a judge agent its rows, its own open proposals and the workspaces other than Home \
    through its tools, and tells it the output form. Its `instruction` says what becomes a task \
    and what does not, how to title and date it, and how to choose the workspace (none means \
    Home). When it reads `newArrivals`, also tell it to resolve open proposals that are finished \
    (I replied, the PR was merged).
    A judge command reads rows on stdin and prints lines of {"propose": "<row id>", "title": "...", \
    "due": "YYYY-MM-DD", "workspace": "<workspace id>", "reason": "..."} (`due`, `workspace` and \
    `reason` optional). It gets neither its open proposals nor the workspaces, so it cannot resolve.
    A proposal points at a row with `link`. `title` is one non-empty line, `due` a real date, \
    `workspace` a current workspace id (Home's id, or none, means Home), `reason` a sentence or two \
    on why.
    Proposals belong to each judge: the same `link` from two judges is two proposals. For one \
    proposal from several fetches, feed them into one judge. Besides people taking or dismissing \
    it, an open proposal goes away in three ways: its judge resolves it; the item it was based on \
    leaves its `currentSet` result; or, when it was based only on events, the event it read passes \
    `retentionDays`. The last two wait while a direct input of the judge still has a row with the \
    `link`.

    REPORT, WORK, SIDE EFFECT
    - A report is text for people, in the language of the instruction. Its first line is the \
    summary that notifications and lists show. An agent gives it through Orbe's tool or says there \
    is nothing to report; a command prints it on stdout, and empty stdout is nothing to report. \
    The text is kept whole, trimmed of surrounding white space, up to 64 KiB; a larger report \
    breaks the rules.
    - A work agent starts in the background (no tab) with only the tools it names. Rows and their \
    count never reach it, so have the `instruction` make it look up its targets itself. It reports \
    what it did (the first line is the summary), says there is nothing to do, or reports an error. \
    A run that fails, or that Orbe did not finish, starts it again next time, so a post can be \
    doubled.
    - A side-effect command gets its rows on stdin, one JSON object per line, and `ORBE_RUN_ID`. \
    Only its exit code is read; over 1 MiB of stdout or 64 KiB of stderr cuts it off. \
    `ORBE_RUN_ID` stays the same when Orbe retries a run that did not finish, so record it at the \
    end, not the start. Rows of a failed run come again in the next run mixed with new ones, so \
    skip done work by each row's `id`.
    - Rows a command receives are outside text, or made from it, and instructions hidden in them \
    can reshape them. Never evaluate their values as shell, and never pass them to an agent \
    (claude -p and the like). To have an agent read them, use a process node; to have something \
    done with tools, use a work node (Orbe's limits do not apply to claude -p inside a command).
    - The definition is kept in the automation database; never put secrets in it.

    NOTIFICATIONS
    With `notify`, a node's run shows the automation's name and one line with a sound: the first \
    run that breaks the rules, the first of consecutive failures, and runs that deliver (a judge's \
    proposal taken in, a report with text, a side effect that ran, work that did something). \
    Fetch and process nodes notify only failures and broken rules. `notificationCenter` keeps one \
    notification per node, replaced by that node's next run; writing it makes macOS ask for \
    permission if it is undecided, and without permission the menu bar shows it. Clicking opens \
    the automation on Home's board, where people can also switch `notify`.

    REWRITING
    Each automation has a `version`, raised by every change to its definition (not by pausing). A \
    rewrite sends the whole definition with the version it was read at, and is refused when the \
    automation changed since; read it again. Nodes match by `id`, so a kept node keeps its read \
    positions, rows, runs and proposals even when its key changes.
    - A node whose behavior changes (method, `command` or `instruction`, `directory`, `workspace`, \
    `model`, `tools`, `deliver`, `timeoutMinutes`, `coverage` or `from`) stops its running run, \
    discards its result and clears its broken-rules mark. A new `coverage` invalidates its current \
    items; a judge checks its open proposals for withdrawal again.
    - Changing only `key`, `name`, `trigger`, `maxItems`, `retentionDays` or `notify` stops nothing.
    - A removed node stops and its current items become invalid; a removed judge forgets its \
    proposals. To stop a node for a while, pause it instead.
    - A new automation and an added node do not run at once; an interval counts from when they \
    were added.
    - Orbe never goes back over rows a node already took because its definition changed. To judge \
    seen items again by a new standard, or to keep a new node from taking what exists now, prepare \
    the inputs yourself before writing.

    EXAMPLE
    GitHub every 10 minutes, Backlog every 30 minutes and Slack every 10 minutes feed a judge that \
    proposes tasks daily at 9:00; the GitHub items are also summarized into a report as they \
    arrive.
    \(example)
    """
}
