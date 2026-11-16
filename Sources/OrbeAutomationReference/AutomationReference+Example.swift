extension AutomationReference {
  /// 定義の節に載せる例。そのまま定義として書ける JSON（テストが定義として読み込み、検証する）。
  public static let example = """
    {"name": "Daily triage of GitHub, Backlog and Slack",
     "nodes": [
      {"key": "github", "name": "GitHub: review requests and mentions",
       "trigger": {"kind": "interval", "minutes": 10},
       "command": "gh search prs --review-requested=@me --state open \
    --json url,title,repository,updatedAt --jq '.[] | {id: .url, link: .url, \
    body: (.repository.nameWithOwner + \\" \\" + .title), time: .updatedAt}'",
       "coverage": "currentSet"},
      {"key": "backlog", "name": "Backlog: my open issues",
       "trigger": {"kind": "interval", "minutes": 30},
       "command": "~/bin/backlog-my-issues.sh", "coverage": "currentSet"},
      {"key": "slack", "name": "Slack: mentions and DMs to me",
       "trigger": {"kind": "interval", "minutes": 10},
       "model": "haiku", "tools": ["mcp__slack__slack_search_public_and_private"],
       "instruction": "Get mentions of me and DMs to me, and the later replies in their threads. \
    id: channel id and ts; link: the permalink of the thread's first message, so every message of \
    a thread shares it; body: \\"#channel / sender: text\\"; time: when it was sent.",
       "coverage": "newArrivals", "retentionDays": 14},
      {"key": "triage", "name": "Morning triage",
       "trigger": {"kind": "cron", "expression": "0 9 * * *"},
       "from": ["github", "backlog", "slack"], "model": "sonnet", "deliver": "taskCandidates",
       "instruction": "Task: something I am asked to do, answer or review. \
    Not a task: thanks, announcements, bot notices. Title: \\"<sender>: <what to do>\\". \
    Due: only when the text gives one. \
    Resolve an open proposal when a newer row with its link shows the matter is settled \
    (the sender withdrew the request or says it is solved)."},
      {"key": "digest", "name": "GitHub digest", "trigger": {"kind": "arrival"},
       "from": ["github"], "model": "haiku", "deliver": "report",
       "instruction": "Summarize the new pull requests in a few lines, the most urgent first. \
    The first line says how many there are."}
     ]}
    """
}
