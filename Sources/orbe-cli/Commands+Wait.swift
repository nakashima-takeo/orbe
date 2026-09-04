import Foundation

// `orb wait` の実装と usage。pane ドメインの外にあるトップレベル動詞なので、pane の既定
// （`ORBE_PANE`）は継がない——ペイン内で走らせたベンチスクリプトが黙って自ペインだけを見る形に
// なると、同じコマンドが環境によって違う意味になる。自ペインを待ちたければ `orb wait $ORBE_PANE`。

// MARK: - usage

let waitUsageLines = [
  "orb wait [<pane>] [--kind <kind>]... [--value <value>] [--after <seq>] [--timeout-ms <ms>] [--json]"
]

/// help の `KINDS:` 行は control の `ControlEvent.kinds` と一致していなければならない
/// （その照合は L4 の `orb wait --help` テストが持つ）。未知 kind を弾くのは control 側で、
/// CLI は語彙を複製しない——ここは人が読むための写し。
let waitUsage = """
  orb wait — block until a state-change event arrives

  USAGE:
  \(usageBlock(waitUsageLines))

  KINDS: agent_state, pane_title, pwd, pane_closed
  <pane> limits the wait to one pane. Omitting it watches **every** pane; unlike
  the pane commands, wait never falls back to ORBE_PANE.
  --kind may be repeated; omitting it waits for any kind.
  --value matches the kind-specific value exactly (the state word for
  agent_state, the title for pane_title, the path for pwd).
  --after <seq> also returns an event that already happened after that
  history position (seq comes from any --json result, e.g. `orb pane send
  --json`); without it only events after the wait is registered count.
  --timeout-ms defaults to 30000. Timing out exits 124 (nothing on stdout,
  `timed out` on stderr; with --json, {"timedOut":true} on stdout).
  To ask an agent something and wait for its answer, use `orb agent prompt`.
  """

// MARK: - サブコマンド

func runWait(_ rest: [String]) -> Never {
  var args = rest
  // help は値の席を抜き取った後に見る（`--kind -h` の値を help と読んで exit 0 で素通りさせない）。
  let kinds = takeOptions(&args, "--kind", requires: "a <kind>")
  let value = takeOption(&args, "--value", requires: "a <value>")
  let after = takeIntOption(&args, "--after", requires: "a non-negative <seq>", atLeast: 0)
  let timeoutMs = takeIntOption(&args, "--timeout-ms", requires: "a positive <milliseconds>")
  if hasHelp(args) {
    print(waitUsage)
    exit(0)
  }
  rejectLeftovers(args, positionals: 1)

  var params: [String: Any] = [:]
  if let first = args.first {
    guard let pane = Int(first) else { usageDie("invalid pane id: \(first)") }
    params["paneId"] = pane
  }
  if !kinds.isEmpty { params["kinds"] = kinds }
  if let value { params["value"] = value }
  if let after { params["after"] = after }
  if let timeoutMs { params["timeoutMs"] = timeoutMs }

  let result = callOrExit("wait_for_event", params)
  let d = result as? [String: Any]
  // 待っていたイベントが来ていないのに exit 0 を返さない（`orb wait … && 次の処理` が
  // 時間切れで先へ進む形を作らない）。124 は GNU timeout(1) の時間切れと同じ値。
  if d?["timedOut"] as? Bool == true {
    if wantJSON { printJSON(result) } else { stderrLine("timed out") }
    exit(124)
  }
  if wantJSON {
    printJSON(result)
  } else {
    let event = d?["event"] as? [String: Any]
    print(
      "\(event?["kind"] as? String ?? "?")\t\(event?["paneId"] as? Int ?? -1)"
        + "\t\(display(event?["value"] ?? NSNull()))")
  }
  exit(0)
}
