extension AutomationReference {
  /// 流す（MCP では `run_automation` の説明に載せる）。
  public static let flow = """
    FLOWS
    A flow points at one node, or at every end node (a node that does not pass rows on), and runs \
    once each node on its path: the node and all its ancestors. Nodes off the path go on as usual.
    - Nodes without `from` run at once. Nodes with `from` and an `interval`, `cron` or `manual` \
    trigger, and paused nodes, run once after their upstream on the path has finished. An \
    `arrival` node that is not paused is not forced: it runs by the usual rule, when its upstream \
    puts out rows for it.
    - A paused automation or node can be flowed, and paused nodes on the path run once. In a paused \
    automation, `arrival` nodes off the path do not run; their rows wait for the resume, so point \
    at the downstream node to run it too.
    - A flow is refused only while its path shares a node with a flow that has not finished; the \
    error names that node. Flows that share no node run side by side.
    - A flow runs for real: side effects and work happen. To check a definition without that, \
    use a trial. The runs show up in `lastRun` and in the run records.
    """

  /// 止める（一時停止。MCP では `pause_automation` の説明に載せる）。
  public static let pause = """
    PAUSING
    Pausing stops only what Orbe starts on its own: schedules and arriving rows. It does not stop \
    a running run or a flow. An automation and each node have their own mark: resuming the \
    automation leaves a paused node paused, and resuming a node does nothing while its \
    automation is paused. A paused node keeps its rows, and its upstream rows pile up for it. On \
    resume, an `interval` node paused past its time runs once, and a `cron` node waits for its \
    next time. Pausing does not change the `version`. To stop a node for a while, pause it rather \
    than removing it: removing it loses its rows and what it has not read.
    """
}
