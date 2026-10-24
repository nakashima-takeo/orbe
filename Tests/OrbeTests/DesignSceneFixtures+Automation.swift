import Foundation
import OrbeTestSupport

@testable import Orbe

/// 見本の自動化 1 つ。ストアの変異の口（作る・部品の回の確定・止める）を通して DB に置く——見本専用の口を本番に足さない。
struct AutomationSample {
  var definition: AutomationDefinition
  var createdAt: Date
  var paused = false
  /// 古い順に確定する部品の回。
  var passes: [AutomationSamplePass] = []
  /// 回を確定した後に消す（出した候補が、重ねて取っている別の自動化の棚に残る）。
  var deleted = false
}

/// 見本の部品の 1 回。入力のある部品の回は、その時点で読める行を（捨てる分のほかは）すべて取った回にする。判定の候補の案の
/// 出どころと、素通しの処理の出力は、読んだ行から組み直す（出どころは DB の行を指すため）。
struct AutomationSamplePass {
  let nodeKey: String
  let at: Date
  var trigger: AutomationNodeRun.Trigger = .schedule
  let outcome: AutomationNodePass.Outcome
  /// 取得の回の前から出ていた項目。見本を置くときに、見本のすべての回の分をまとめて回の記録を残さず出力へ足し、下流の受け手は
  /// 読んだものとしておく。回の出力にもまとめた分を載せる——見本が言う「新しい項目」の数を、DB の照らし合わせが同じに数えるため。
  var kept: [AutomationItem] = []
  /// 読んだ行の古い方から、古さの上限を過ぎたとして捨てる行の数。
  var expired = 0
  /// 取る行の数（新しい方から）。省けば読んだ行すべて。残りは読んだものとして流さない。
  var take: Int?
  /// 素通しの処理の回: 取った行の先頭から N 行を、id を保ったまま次へ渡す。
  var passThrough: Int?
}

/// 提案タブの fixture（見本 R3Inbox.png と同じ並び）。今日はタスク画面と同じ 2025-10-04、走らせ役の今は同じ日の 15:00 に
/// 固定し、次の時刻と回の時刻を決定論にする。部品は始まっても終わらない（実行中のまま）——実物の claude は起こさない。
extension DesignSceneFixtures {
  static func automationAt(_ hour: Int, _ minute: Int = 0, daysAgo: Int = 0) -> Date {
    let day = taskCalendar.date(byAdding: .day, value: -daysAgo, to: taskToday)!
    return taskCalendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
  }

  static var automationNow: Date { automationAt(15) }

  /// 見本を置いたストア。DB はこの呼び出しだけの新しいフォルダに作る（同じテストで見本を何度作っても、DB の排他でぶつからない）。
  static func automationStore(_ samples: [AutomationSample]) -> AutomationStore {
    let previous = AutomationPersistence.folderOverride
    AutomationPersistence.folderOverride = TestScratch.caseDir.appendingPathComponent(
      "automations-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { AutomationPersistence.folderOverride = previous }
    let store = AutomationStore()
    seed(samples, into: store)
    return store
  }

  /// 見本を置いた DB に `corrupt` で手を入れてから開き直したストア（読めない定義・不明な記録の見本）。
  static func automationStore(
    _ samples: [AutomationSample], corrupt: (SQLiteDatabase) throws -> Void
  ) -> AutomationStore {
    let previous = AutomationPersistence.folderOverride
    AutomationPersistence.folderOverride = TestScratch.caseDir.appendingPathComponent(
      "automations-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { AutomationPersistence.folderOverride = previous }
    do {
      try {
        let store = AutomationStore()
        seed(samples, into: store)
        try store.read { try corrupt($0.db) }
      }()
    } catch {
      preconditionFailure("the corruption runs: \(error)")
    }
    return AutomationStore()
  }

  /// 見本『Home 自動化』のうち、GitHub の判定の動作の定義を壊し（定義を読めない自動化）、Slack の取得の最新の成功した回の中身を
  /// 壊した（不明な記録）DB。
  static func boardUnreadableStore() -> AutomationStore {
    automationStore(boardDesignSamples()) { db in
      try db.exec(
        """
        UPDATE action_defs SET action = '{"instruction": 1}'
        WHERE id = (SELECT def_id FROM parts WHERE automation_id = 2 AND key = 'judge');
        UPDATE runs SET record = '{}' WHERE id = (
          SELECT max(r.id) FROM runs r JOIN parts p ON p.id = r.part_id
          WHERE p.automation_id = 1 AND p.key = 'fetch' AND r.failure IS NULL)
        """)
    }
  }

  /// 窓が開く既定の DB に見本を置き、閉じる（窓を作る前に呼ぶ）。
  static func seedAutomations(_ samples: [AutomationSample]) {
    seed(samples, into: AutomationStore())
  }

  private static func seed(_ samples: [AutomationSample], into store: AutomationStore) {
    do {
      for sample in samples {
        let id = try store.create(sample.definition, now: sample.createdAt).id
        var kept: [String: [AutomationItem]] = [:]
        for pass in sample.passes {
          for item in pass.kept where !(kept[pass.nodeKey] ?? []).map(\.id).contains(item.id) {
            kept[pass.nodeKey, default: []].append(item)
          }
        }
        for (key, items) in kept.sorted(by: { $0.key < $1.key }) {
          try prepare(items, as: key, of: id, in: store, at: sample.createdAt)
        }
        for pass in sample.passes {
          try record(pass, of: id, in: store, kept: kept[pass.nodeKey] ?? [])
        }
        if sample.paused { _ = try store.setPaused(id, true, now: sample.createdAt) }
        if sample.deleted { try store.delete(id, now: sample.createdAt) }
      }
    } catch {
      preconditionFailure("the samples are valid: \(error)")
    }
  }

  /// 見本の前から出ていた項目を、回の記録を残さず `key` の部品の出力へ足し、下流の受け手は読んだものとする。
  private static func prepare(
    _ items: [AutomationItem], as key: String, of id: Int, in store: AutomationStore, at: Date
  ) throws {
    let nodeId = store.nodeId(id, key)
    try store.give(items.map(row), as: nodeId, of: id, at: at)
    for receiver in store.automation(id)?.graph.downstream(of: nodeId) ?? [] {
      guard var read = try store.read(receiver.id, of: id, baseline: nil, now: at) else { continue }
      read.taken = []
      read.dropped = []
      read.lapsed = 0
      try store.discard(read, of: receiver.id, in: id, now: at)
    }
  }

  /// 見本の回 1 つを、走らせ役と同じ読みと確定で記録する。`kept` はその部品の見本の前から出ていた項目で、取得の回の出力に足す。
  static func record(
    _ pass: AutomationSamplePass, of id: Int, in store: AutomationStore,
    kept: [AutomationItem] = []
  ) throws {
    guard let automation = store.automation(id), let node = automation.graph.node(key: pass.nodeKey)
    else {
      preconditionFailure("no part \(pass.nodeKey) in the sample")
    }
    var read: AutomationIntake.Read?
    var outcome = pass.outcome
    if case .succeeded(.fetch(let rows), let execution, let breach) = outcome, !kept.isEmpty {
      let ids = Set(rows.map(\.id))
      outcome = .succeeded(
        .fetch(kept.filter { !ids.contains($0.id) }.map(row) + rows), execution, breach: breach)
    }
    if !node.inputs.isEmpty {
      var found = try readOrFail(
        store.read(node.id, of: id, baseline: nil, now: pass.at.addingTimeInterval(60)))
      let expired = found.taken.prefix(pass.expired)
      found.taken.removeFirst(expired.count)
      found.dropped += expired.map { AutomationIntake.Drop(row: $0, reason: .expired) }
      if let take = pass.take { found.taken = Array(found.taken.suffix(take)) }
      read = found
      outcome = resolved(outcome, pass, found.taken)
    }
    _ = try store.record(
      AutomationPassEnd(
        automationId: id, nodeId: node.id, defId: node.entity.defId, trigger: pass.trigger,
        startedAt: pass.at, endedAt: pass.at.addingTimeInterval(60), read: read,
        outcome: outcome))
  }

  private static func readOrFail(_ read: AutomationIntake.Read?) -> AutomationIntake.Read {
    guard let read else { preconditionFailure("a part with inputs reads") }
    return read
  }

  /// 判定の案の出どころを、読んだ行の出どころ（同じ書かれた id の項目、無ければ順に）に当て直す。素通しの処理は、取った行を
  /// 次へ渡す。
  private static func resolved(
    _ outcome: AutomationNodePass.Outcome, _ pass: AutomationSamplePass,
    _ taken: [AutomationIntake.Row]
  ) -> AutomationNodePass.Outcome {
    if let count = pass.passThrough, case .succeeded(_, let execution, let breach) = outcome {
      return .succeeded(
        .process(
          taken.prefix(count).map {
            AutomationNodeRow(id: $0.id, text: $0.text, origin: $0.origin, source: $0.source)
          }), execution, breach: breach)
    }
    guard case .succeeded(.judge(let proposals, let resolved), let execution, let breach) = outcome
    else { return outcome }
    var origins = taken.compactMap(\.origin)
    let placed = proposals.compactMap { proposal -> AutomationNodePass.Proposal? in
      let index =
        origins.firstIndex { $0.item.id == proposal.origin.item.id } ?? origins.indices.first
      guard let index else { return nil }
      let origin = origins.remove(at: index)
      return AutomationNodePass.Proposal(
        origin: origin, title: proposal.title, due: proposal.due, workspace: proposal.workspace,
        reason: proposal.reason)
    }
    return .succeeded(.judge(proposals: placed, resolved: resolved), execution, breach: breach)
  }

  /// 項目を取得が出した 1 行にする。
  nonisolated static func row(_ item: AutomationItem) -> AutomationNodeRow {
    AutomationNodeRow(
      id: item.id, text: AutomationPrompts.jsonLine(AutomationWire.object(item)), origin: nil,
      source: nil)
  }

  /// 番人も部品の回も止まった走らせ役。
  static func automationRunner(_ samples: [AutomationSample] = []) -> AutomationRunner {
    automationRunner(store: automationStore(samples))
  }

  /// `store` の上の、番人も部品の回も止まった走らせ役。
  static func automationRunner(store: AutomationStore) -> AutomationRunner {
    let scheduler = BackgroundScheduler { _, _ in BackgroundRunHandle {} }
    scheduler.now = { automationNow }
    scheduler.calendar = { taskCalendar }
    scheduler.arm = { _, _ in {} }
    let runner = AutomationRunner(
      store: store, scheduler: scheduler,
      run: { _, _ in BackgroundRunHandle {} },
      workspaces: { AutomationWorkspaces(listed: [], home: nil) }, recorded: { _ in },
      defined: { _ in }, deleted: { _ in })
    runner.now = { automationNow }
    runner.calendar = { taskCalendar }
    runner.start()
    return runner
  }

  // MARK: - 部品

  /// 見本の cron のいつ。見本には正しい式だけを書く。
  nonisolated static func cron(_ expression: String) -> BackgroundTiming {
    do {
      return .cron(try BackgroundCron(expression))
    } catch {
      preconditionFailure("\(expression): \(error.message)")
    }
  }

  nonisolated static func commandNode(
    _ key: String, _ name: String, _ trigger: AutomationNode.Trigger, from inputs: [String] = [],
    script: String, directory: String? = nil, coverage: AutomationCoverage? = nil,
    deliver: AutomationActionDef.Destination = .nextNode
  ) -> AutomationDefinition.Node {
    AutomationDefinition.Node(
      id: nil, key: key, name: name, trigger: trigger,
      from: inputs.map { AutomationDefinition.Input(part: $0) },
      action: AutomationActionDef(
        method: .command(BackgroundCommand(script: script, directory: directory)),
        timeoutMinutes: nil, coverage: coverage, destination: deliver), maxItems: nil)
  }

  nonisolated static func agentNode(
    _ key: String, _ name: String, _ trigger: AutomationNode.Trigger, from inputs: [String] = [],
    model: String? = nil, tools: [String] = [], instruction: String,
    coverage: AutomationCoverage? = nil, deliver: AutomationActionDef.Destination = .nextNode
  ) -> AutomationDefinition.Node {
    AutomationDefinition.Node(
      id: nil, key: key, name: name, trigger: trigger,
      from: inputs.map { AutomationDefinition.Input(part: $0) },
      action: AutomationActionDef(
        method: .agent(
          AutomationNodeAgent(cli: "claude", model: model, tools: tools, instruction: instruction)),
        timeoutMinutes: nil, coverage: coverage, destination: deliver), maxItems: nil)
  }

  /// 取得の部品 `fetch` と、届いたらタスク候補を出す判定の部品 `judge`。
  nonisolated static func candidatesDefinition(
    _ name: String, fetch: AutomationDefinition.Node,
    instruction: String = "自分が何かを頼まれている・期限がある項目だけをタスクにする。",
    notify: AutomationNotify? = nil
  ) -> AutomationDefinition {
    AutomationDefinition(
      name: name, notify: notify,
      parts: [
        fetch,
        agentNode(
          "judge", "判定", .arrival, from: [fetch.key], model: "sonnet", instruction: instruction,
          deliver: .taskCandidates),
      ])
  }

  // MARK: - 回

  nonisolated static func execution(_ count: Int, ending: AutomationEnding = .exited(0))
    -> AutomationNodePass.Execution
  {
    AutomationNodePass.Execution(commandLine: "claude -p", ending: ending, count: count)
  }

  /// 取得の回（取れた全項目）。
  nonisolated static func fetched(_ items: [AutomationItem]) -> AutomationNodePass.Outcome {
    .succeeded(.fetch(items.map(row)), execution(items.count), breach: nil)
  }

  /// 項目への候補の案。出どころは、記録するときに判定が読んだ行の出どころ（同じ書かれた id の項目）に当て直す。
  nonisolated static func proposal(
    _ item: AutomationItem, _ title: String, due: TaskItem.DueDate? = nil, workspace: UUID? = nil,
    reason: String? = nil
  ) -> AutomationNodePass.Proposal {
    AutomationNodePass.Proposal(
      origin: AutomationIntake.Origin(nodeId: AutomationNodeID(0), row: .event(0), item: item),
      title: title, due: due, workspace: workspace, reason: reason)
  }

  /// 判定の回。`rows` は読めた行の数。
  nonisolated static func judged(_ proposals: [AutomationNodePass.Proposal], rows: Int)
    -> AutomationNodePass.Outcome
  {
    .succeeded(.judge(proposals: proposals, resolved: []), execution(rows), breach: nil)
  }

  /// 手段が 0 以外で終わった回（`detail` は標準エラーの抜粋）。
  nonisolated static func failed(
    _ detail: String, ending: AutomationEnding = .exited(1), count: Int = 0
  ) -> AutomationNodePass.Outcome {
    failed(.ended(detail: detail), ending: ending, count: count)
  }

  nonisolated static func failed(
    _ failure: AutomationFailure, ending: AutomationEnding = .exited(1), count: Int = 0
  ) -> AutomationNodePass.Outcome {
    .failed(failure, execution(count, ending: ending), breach: nil)
  }

  nonisolated static func reported(_ text: String?) -> AutomationNodePass.Outcome {
    .succeeded(.report(text), execution(text == nil ? 0 : 1), breach: nil)
  }

  nonisolated static func worked(_ work: AutomationNodePass.Work) -> AutomationNodePass.Outcome {
    let count = if case .done = work { 1 } else { 0 }
    return .succeeded(.work(work), execution(count), breach: nil)
  }

  nonisolated static func sideEffected(_ count: Int) -> AutomationNodePass.Outcome {
    .succeeded(.sideEffect, execution(count), breach: nil)
  }

  nonisolated static func processed(_ rows: [AutomationNodeRow], read: Int)
    -> AutomationNodePass.Outcome
  {
    .succeeded(.process(rows), execution(read), breach: nil)
  }

  /// `source` の `count` 項目（id は回の時刻と番号）。リンクは出どころと id で一意。
  nonisolated static func sampleItems(_ source: String, _ count: Int, at time: Date)
    -> [AutomationItem]
  {
    let stamp = Int(time.timeIntervalSince1970)
    return (0..<count).map { n in
      AutomationItem(
        id: "\(stamp)-\(n)", link: "https://example.com/\(source)/\(stamp)-\(n)",
        body: "\(source) の項目 \(n)", time: time)
    }
  }

  /// 1 回の取得の全項目と、そのうち新しい項目。新しくない項目は回によらず同じ（id は `<出どころ>-<番号>`）、新しい項目は回の
  /// 時刻の id。
  nonisolated static func sampleRound(_ source: String, at time: Date, items: Int, fresh: Int)
    -> (all: [AutomationItem], new: [AutomationItem])
  {
    let kept = (0..<(items - fresh)).map { n in
      AutomationItem(
        id: "\(source)-\(n)", link: "https://example.com/\(source)/\(n)",
        body: "\(source) の項目 \(n)",
        time: Date(timeIntervalSince1970: 1_700_000_000))
    }
    let new = Array(sampleItems(source, items, at: time).suffix(fresh))
    return (kept + new, new)
  }

  /// 取得の回と、その後の届いたらの判定の回。新しい `fresh` 項目のうち先頭の `proposed` 件を候補にする。取得が失敗した回は
  /// 判定を起こさない。
  nonisolated static func round(
    _ source: String, at time: Date, items: Int, fresh: Int, proposed: Int = 0,
    trigger: AutomationNodeRun.Trigger = .schedule, failure: String? = nil
  ) -> [AutomationSamplePass] {
    if let failure {
      return [
        AutomationSamplePass(nodeKey: "fetch", at: time, trigger: trigger, outcome: failed(failure))
      ]
    }
    let (all, new) = sampleRound(source, at: time, items: items, fresh: fresh)
    var passes = [
      AutomationSamplePass(
        nodeKey: "fetch", at: time, trigger: trigger, outcome: fetched(all),
        kept: Array(all.prefix(items - fresh)))
    ]
    if !new.isEmpty {
      passes.append(
        AutomationSamplePass(
          nodeKey: "judge", at: time.addingTimeInterval(60), trigger: .arrival,
          outcome: judged(
            new.prefix(proposed).map { proposal($0, "\($0.body)に対応する") },
            rows: new.count), take: new.count))
    }
    return passes
  }
}
