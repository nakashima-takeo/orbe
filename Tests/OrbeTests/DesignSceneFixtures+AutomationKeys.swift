import Foundation
import XCTest

@testable import Orbe

// テストと見本が部品を今の鍵で指すための口（本番は部品を ID で指す）。

extension BoardAutomationModel {
  /// 選んでいる自動化の部品を今の鍵で選ぶ（テストと見本）。
  func tapNode(key: String) {
    guard let nodeId = selectedAutomation?.graph.node(key: key)?.id else { return }
    tapNode(nodeId)
  }

  /// 選んでいる自動化の部品の「修正を依頼」を今の鍵で（テストと見本）。
  func draftFix(key: String, l10n: LocalizationStore) {
    guard let nodeId = selectedAutomation?.graph.node(key: key)?.id else { return }
    draftFix(of: nodeId, l10n: l10n)
  }
}

extension AutomationStore {
  /// 今の鍵の部品の ID（テストと見本）。
  func nodeId(_ id: Int, _ key: String) -> AutomationNodeID {
    guard let nodeId = automation(id)?.graph.node(key: key)?.id else {
      preconditionFailure("no node \(key) in automation \(id)")
    }
    return nodeId
  }

  /// 鍵で指した部品が項目・出来事に最後に振った番号（DB から。テスト）。
  func lastSeqs(_ id: Int, _ key: String) throws -> AutomationSeqs {
    try read { try $0.lastSeqs(of: nodeId(id, key)) }
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
    try read { try $0.pendingDrops(of: nodeId(id, key)) }
  }

  /// 鍵で指した部品の 1 回を、走らせ役と同じ読み（読める行をすべて取る）で確定する（テストと見本）。
  @discardableResult func record(
    _ id: Int, nodeKey key: String, trigger: AutomationNodeRun.Trigger = .schedule, at: Date,
    endedAt: Date? = nil, outcome: AutomationNodePass.Outcome
  ) throws -> AutomationRecorded {
    let nodeId = nodeId(id, key)
    guard let node = automation(id)?.graph.node(nodeId) else { preconditionFailure("no node") }
    let ended = endedAt ?? at
    return try record(
      AutomationPassEnd(
        automationId: id, nodeId: nodeId, defId: node.entity.defId, trigger: trigger, startedAt: at,
        endedAt: ended, read: try read(nodeId, of: id, baseline: nil, now: ended), outcome: outcome)
    )
  }
}

extension WindowController {
  /// 部品を今の鍵で指す（テスト）。
  func automationNotification(_ id: Int, _ key: String) -> ChromeNotification? {
    automationNotification(id, automationStore.nodeId(id, key))
  }

  func notifyAutomationRecorded(_ id: Int, _ key: String) {
    notifyAutomationRecorded(id, automationStore.nodeId(id, key))
  }
}

extension BoardAutomationNodeValue {
  /// 部品を今の鍵で指す（テスト）。
  init?(
    _ automation: Automation, key: String, text: AutomationText, running: Bool, next: Date?,
    open: Int
  ) {
    guard let nodeId = automation.graph.node(key: key)?.id else { return nil }
    self.init(automation, nodeId: nodeId, text: text, running: running, next: next, open: open)
  }
}

extension BoardAutomationModel {
  /// 選ばれている部品の今の鍵（テスト）。
  var selectedNodeKey: String? {
    selectedNodeId.flatMap { selectedAutomation?.graph.node($0)?.key }
  }
}

extension AutomationRunner {
  /// 部品を今の鍵で指す（テスト）。
  func isRunning(_ id: Int, _ key: String) -> Bool {
    guard let nodeId = store.automation(id)?.graph.node(key: key)?.id else { return false }
    return isRunning(id, nodeId)
  }
}

extension Automation {
  /// 部品の状態を今の鍵で引く（テスト）。
  func state(key: String) -> AutomationNodeState {
    guard let node = graph.node(key: key) else { preconditionFailure("no node \(key)") }
    return state(node.id)
  }
}

extension AutomationTrial {
  /// 部品を鍵で指す（テスト）。
  func state(key: String) -> NodeState {
    guard let nodeId = range.path.first(where: { $0.key == key })?.id else { return .untouched }
    return state(of: nodeId)
  }

  func passes(key: String) -> [Pass] {
    range.path.first { $0.key == key }.flatMap { passes[$0.id] } ?? []
  }

  /// 行き先の部品の鍵。
  var targetKeys: [String] {
    range.to.compactMap { id in range.path.first { $0.id == id }?.key }
  }
}
