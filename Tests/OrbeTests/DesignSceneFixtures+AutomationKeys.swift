import Foundation
import XCTest

@testable import Orbe

// テストと見本が部品を今の鍵で指すための口（本番は部品を ID で指す）。

extension BoardAutomationModel {
  /// 選んでいる自動化の部品を今の鍵で選ぶ（テストと見本）。
  func tapPart(key: String) {
    guard let part = selectedAutomation?.graph.node(key: key)?.id else { return }
    tapPart(part)
  }

  /// 選んでいる自動化の部品の「修正を依頼」を今の鍵で（テストと見本）。
  func draftFix(key: String, l10n: LocalizationStore) {
    guard let part = selectedAutomation?.graph.node(key: key)?.id else { return }
    draftFix(of: part, l10n: l10n)
  }
}

extension AutomationStore {
  /// 今の鍵の部品の ID（テストと見本）。
  func part(_ id: Int, _ key: String) -> AutomationPartID {
    guard let part = automation(id)?.graph.node(key: key)?.id else {
      preconditionFailure("no part \(key) in automation \(id)")
    }
    return part
  }

  /// 鍵で指した部品が項目・出来事に最後に振った番号（DB から。テスト）。
  func lastSeqs(_ id: Int, _ key: String) throws -> AutomationSeqs {
    try read { try $0.lastSeqs(of: part(id, key)) }
  }

  /// 候補への人の判断（DB の判断の記録から。判断の無い候補は nil。テスト）。判断した候補は、どの自動化も持たなければその場で
  /// 忘れてメモリから外れるので、判断は記録から読む。
  func decision(of proposal: Int) throws -> AutomationProposal.State? {
    try read {
      try $0.db.select(
        "SELECT outcome, task_id FROM settlements WHERE proposal_id = ?",
        [.integer(Int64(proposal))]
      ) { s -> AutomationProposal.State in
        s.text(at: 0) == "accepted" ? .accepted(taskId: s.int(at: 1)) : .dismissed
      }.first
    }
  }

  /// 鍵で指した受け手の持ち越し（DB から。テスト）。
  func pendingDrops(_ id: Int, _ key: String) throws -> AutomationDrops {
    try read { try $0.pendingDrops(of: part(id, key)) }
  }

  /// 鍵で指した部品の 1 回を、走らせ役と同じ読み（読める行をすべて取る）で確定する（テストと見本）。
  @discardableResult func record(
    _ id: Int, part key: String, trigger: AutomationPartRun.Trigger = .schedule, at: Date,
    endedAt: Date? = nil, outcome: AutomationPartPass.Outcome
  ) throws -> AutomationRecorded {
    let part = part(id, key)
    guard let node = automation(id)?.graph.node(part) else { preconditionFailure("no part") }
    let ended = endedAt ?? at
    return try record(
      AutomationPassEnd(
        automationId: id, part: part, defId: node.part.defId, trigger: trigger, startedAt: at,
        endedAt: ended, read: try read(part, of: id, baseline: nil, now: ended), outcome: outcome))
  }
}

extension WindowController {
  /// 部品を今の鍵で指す（テスト）。
  func automationNotification(_ id: Int, _ key: String) -> ChromeNotification? {
    automationNotification(id, automationStore.part(id, key))
  }

  func notifyAutomationRecorded(_ id: Int, _ key: String) {
    notifyAutomationRecorded(id, automationStore.part(id, key))
  }
}

extension BoardAutomationPartValue {
  /// 部品を今の鍵で指す（テスト）。
  init?(
    _ automation: Automation, key: String, text: AutomationText, running: Bool, next: Date?,
    open: Int
  ) {
    guard let part = automation.graph.node(key: key)?.id else { return nil }
    self.init(automation, part: part, text: text, running: running, next: next, open: open)
  }
}

extension BoardAutomationModel {
  /// 選ばれている部品の今の鍵（テスト）。
  var selectedPartKey: String? {
    selectedPart.flatMap { selectedAutomation?.graph.node($0)?.key }
  }
}

extension AutomationRunner {
  /// 部品を今の鍵で指す（テスト）。
  func isRunning(_ id: Int, _ key: String) -> Bool {
    guard let part = store.automation(id)?.graph.node(key: key)?.id else { return false }
    return isRunning(id, part)
  }
}

extension Automation {
  /// 部品の状態を今の鍵で引く（テスト）。
  func state(key: String) -> AutomationPartState {
    guard let node = graph.node(key: key) else { preconditionFailure("no part \(key)") }
    return state(node.id)
  }
}

extension AutomationTrial {
  /// 部品を鍵で指す（テスト）。
  func state(key: String) -> PartState {
    guard let part = range.path.first(where: { $0.key == key })?.id else { return .untouched }
    return state(of: part)
  }

  func passes(key: String) -> [Pass] {
    range.path.first { $0.key == key }.flatMap { passes[$0.id] } ?? []
  }

  /// 行き先の部品の鍵。
  var targetKeys: [String] {
    range.to.compactMap { id in range.path.first { $0.id == id }?.key }
  }
}
