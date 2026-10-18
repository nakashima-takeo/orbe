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

/// 見本の部品の 1 回。入力のある部品の回は、その時点の溜まりをすべて取った回にする。
struct AutomationSamplePass {
  let part: String
  let at: Date
  var trigger: AutomationPartRun.Trigger = .schedule
  let outcome: AutomationPartPass.Outcome
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

  /// 窓が開く既定の DB に見本を置き、閉じる（窓を作る前に呼ぶ）。
  static func seedAutomations(_ samples: [AutomationSample]) {
    seed(samples, into: AutomationStore())
  }

  private static func seed(_ samples: [AutomationSample], into store: AutomationStore) {
    do {
      for sample in samples {
        let id = try store.create(sample.definition, now: sample.createdAt).id
        for pass in sample.passes {
          guard let node = store.automation(id)?.graph.node(pass.part) else {
            preconditionFailure("no part \(pass.part) in the sample")
          }
          var take: AutomationInbox.Take?
          if !node.part.inputs.isEmpty {
            take = AutomationInbox.Take(
              taken: try store.inbox(of: pass.part, in: id).map(\.seq), dropped: [])
          }
          _ = try store.record(
            AutomationPassEnd(
              automationId: id, part: pass.part, trigger: pass.trigger, startedAt: pass.at,
              endedAt: pass.at.addingTimeInterval(60), take: take, outcome: pass.outcome))
        }
        if sample.paused { _ = try store.setPaused(id, true) }
        if sample.deleted { try store.delete(id) }
      }
    } catch {
      preconditionFailure("the samples are valid: \(error)")
    }
  }

  /// 番人も部品の回も止まった走らせ役。
  static func automationRunner(_ samples: [AutomationSample] = []) -> AutomationRunner {
    let scheduler = BackgroundScheduler { _, _ in BackgroundRunHandle {} }
    scheduler.now = { automationNow }
    scheduler.calendar = { taskCalendar }
    scheduler.arm = { _, _ in {} }
    let runner = AutomationRunner(
      store: automationStore(samples), scheduler: scheduler,
      run: { _, _ in BackgroundRunHandle {} },
      workspaces: { AutomationWorkspaces(listed: [], home: nil) }, recorded: { _, _ in },
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

  nonisolated static func commandPart(
    _ key: String, _ name: String, _ trigger: AutomationPart.Trigger, from inputs: [String] = [],
    script: String, directory: String? = nil, coverage: AutomationCoverage? = nil,
    deliver: AutomationPart.Destination = .nextPart
  ) -> AutomationPart {
    AutomationPart(
      key: key, name: name, trigger: trigger, inputs: inputs,
      method: .command(BackgroundCommand(script: script, directory: directory)),
      timeoutMinutes: nil, coverage: coverage, destination: deliver, inboxLimit: nil)
  }

  nonisolated static func agentPart(
    _ key: String, _ name: String, _ trigger: AutomationPart.Trigger, from inputs: [String] = [],
    model: String? = nil, tools: [String] = [], instruction: String,
    coverage: AutomationCoverage? = nil, deliver: AutomationPart.Destination = .nextPart
  ) -> AutomationPart {
    AutomationPart(
      key: key, name: name, trigger: trigger, inputs: inputs,
      method: .agent(
        AutomationPartAgent(cli: "claude", model: model, tools: tools, instruction: instruction)),
      timeoutMinutes: nil, coverage: coverage, destination: deliver, inboxLimit: nil)
  }

  /// 取得の部品 `fetch` と、届いたらタスク候補を出す判定の部品 `judge`。
  nonisolated static func candidatesDefinition(
    _ name: String, fetch: AutomationPart,
    instruction: String = "自分が何かを頼まれている・期限がある項目だけをタスクにする。",
    notify: AutomationNotify? = nil
  ) -> AutomationDefinition {
    AutomationDefinition(
      name: name, notify: notify,
      parts: [
        fetch,
        agentPart(
          "judge", "判定", .arrival, from: [fetch.key], model: "sonnet", instruction: instruction,
          deliver: .taskCandidates),
      ])
  }

  // MARK: - 回

  nonisolated static func execution(_ count: Int, ending: String = "exited 0")
    -> AutomationPartPass.Execution
  {
    AutomationPartPass.Execution(commandLine: "claude -p", ending: ending, count: count)
  }

  /// 取得の回。`fresh` を省けば全項目が新しい。
  nonisolated static func fetched(
    _ part: String, _ items: [AutomationItem], fresh: [AutomationItem]? = nil
  ) -> AutomationPartPass.Outcome {
    let rows = (fresh ?? items).map { item in
      let id = "\(part):\(item.id)"
      return AutomationPartRow(
        id: id,
        text: AutomationPrompts.row(
          AutomationItem(id: id, link: item.link, body: item.body, time: item.time)),
        origin: AutomationOrigin(part: part, item: item))
    }
    return .succeeded(
      .fetch(rows: rows, lastOutput: items.map { AutomationSeen(id: $0.id, link: $0.link) }),
      execution(items.count), breach: nil)
  }

  /// 取得の部品 `fetch` の項目への候補の案。
  nonisolated static func proposal(
    _ item: AutomationItem, _ title: String, due: TaskItem.DueDate? = nil, workspace: UUID? = nil
  ) -> AutomationPartPass.Proposal {
    AutomationPartPass.Proposal(
      origin: AutomationOrigin(part: "fetch", item: item), title: title, due: due,
      workspace: workspace)
  }

  /// 判定の回。`rows` は読めた行の数。
  nonisolated static func judged(_ proposals: [AutomationPartPass.Proposal], rows: Int)
    -> AutomationPartPass.Outcome
  {
    .succeeded(.judge(proposals: proposals, resolved: []), execution(rows), breach: nil)
  }

  nonisolated static func failed(_ reason: String, count: Int = 0) -> AutomationPartPass.Outcome {
    .failed(reason, execution(count, ending: "exited 1"), breach: nil)
  }

  nonisolated static func reported(_ text: String?) -> AutomationPartPass.Outcome {
    .succeeded(.report(text), execution(text == nil ? 0 : 1), breach: nil)
  }

  nonisolated static func worked(_ work: AutomationPartPass.Work) -> AutomationPartPass.Outcome {
    let count = if case .done(.some) = work { 1 } else { 0 }
    return .succeeded(.work(work), execution(count), breach: nil)
  }

  nonisolated static func sideEffected(_ count: Int) -> AutomationPartPass.Outcome {
    .succeeded(.sideEffect, execution(count), breach: nil)
  }

  nonisolated static func processed(_ rows: [AutomationPartRow], read: Int)
    -> AutomationPartPass.Outcome
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

  /// 取得の回と、その後の届いたらの判定の回。新しい `fresh` 項目のうち先頭の `proposed` 件を候補にする。取得が失敗した回は
  /// 判定を起こさない。
  nonisolated static func round(
    _ source: String, at time: Date, items: Int, fresh: Int, proposed: Int = 0,
    trigger: AutomationPartRun.Trigger = .schedule, failure: String? = nil
  ) -> [AutomationSamplePass] {
    if let failure {
      return [
        AutomationSamplePass(part: "fetch", at: time, trigger: trigger, outcome: failed(failure))
      ]
    }
    let all = sampleItems(source, items, at: time)
    let new = Array(all.suffix(fresh))
    var passes = [
      AutomationSamplePass(
        part: "fetch", at: time, trigger: trigger, outcome: fetched("fetch", all, fresh: new))
    ]
    if !new.isEmpty {
      passes.append(
        AutomationSamplePass(
          part: "judge", at: time.addingTimeInterval(60), trigger: .arrival,
          outcome: judged(
            new.prefix(proposed).map { proposal($0, "\($0.body)に対応する") },
            rows: new.count)))
    }
    return passes
  }
}
