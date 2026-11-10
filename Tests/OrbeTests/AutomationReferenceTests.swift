import OrbeAutomationReference
import XCTest

@testable import Orbe

/// AI が読む自動化の説明（共有の英文 `AutomationReference` と同梱のスキルの型）が、今の Orbe と食い違わないこと——載せた定義の例が
/// そのまま定義として保存でき、コピーした既定と上限が Orbe 本体の値と一致する。
///
/// 壊れると何が起きるか: AI が説明の例をコピーして組んだ定義が `set_automation` でエラーになる。AI が古い上限や既定で定義を組み、
/// エラーになるか、上限時間・出来事を残す日数・ノードごとに残る回の記録の数を見誤る。
final class AutomationReferenceTests: OrbeTestCase {
  /// 説明の例（`AutomationReference.example`）と `patterns.md` のどの JSON も、`set_automation` と同じ読みと検証を通って保存できる。
  func testEveryDefinitionShownToTheAIIsAccepted() throws {
    let patterns = try String(contentsOf: Self.patterns, encoding: .utf8)
    let block = try NSRegularExpression(
      pattern: "```json\\n(.*?)\\n```", options: .dotMatchesLineSeparators)
    let blocks = block.matches(in: patterns, range: NSRange(patterns.startIndex..., in: patterns))
      .compactMap { Range($0.range(at: 1), in: patterns).map { String(patterns[$0]) } }
    XCTAssertFalse(blocks.isEmpty, "patterns.md に JSON の型が無い")
    let store = AutomationStore()

    for (label, json) in [("AutomationReference.example", AutomationReference.example)]
      + blocks.enumerated().map({ ("patterns.md の \($0.offset + 1) つ目の JSON", $0.element) })
    {
      do {
        let object = try XCTUnwrap(
          try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
          "\(label) が JSON のオブジェクトでない")
        _ = try store.create(try AutomationDefinition.decode(object), now: Date())
      } catch {
        XCTFail("\(label) が定義としてエラーになった: \(error)")
      }
    }
  }

  /// 共有の英文がコピーしている既定と上限は、Orbe 本体の正本と同じ値。
  func testTheLimitsTheReferenceCopiesMatchOrbe() {
    let text = AutomationReference.sections.joined(separator: "\n\n")
    let timeout = AutomationActionDef.timeoutRange
    let retention = AutomationRetention.standard
    let output = BackgroundLimits.command
    let copies = [
      "`key`: \(AutomationNode.keyLength.lowerBound)-\(AutomationNode.keyLength.upperBound) letters",
      "`minutes` (\(Int(BackgroundTiming.minimumInterval) / 60)-"
        + "\(Int(BackgroundTiming.maximumInterval) / 60))",
      "`timeoutMinutes`: \(timeout.lowerBound)-\(timeout.upperBound); the default is "
        + "\(AutomationActionDef.commandTimeoutMinutes) for a command and "
        + "\(AutomationActionDef.agentTimeoutMinutes) for an agent.",
      "\(AutomationNode.retentionDaysRange.lowerBound)-\(AutomationNode.retentionDaysRange.upperBound) "
        + "(by default the setting, \(retention.eventDays) days)",
      "A row may be at most \(AutomationOutputs.rowKiB) KiB",
      "up to \(AutomationOutputs.rowKiB) KiB; a larger report",
      "over \(output.output >> 20) MiB of stdout or \(output.stderr >> 10) KiB of stderr",
      "(settings, \(retention.runCount) runs and \(retention.runDays) days by default)",
      "each is at most \(AutomationOutputs.rowKiB) KiB.",
      "kept up to the newest \(AutomationTrials.newDefinitionTrials).",
    ]
    for copy in copies {
      XCTAssertTrue(text.contains(copy), "共有の英文のコピーが本体の値と食い違っている: \(copy)")
    }
  }

  /// 同梱の自動化のスキルの型（`skills/automation/references/patterns.md`）。
  static let patterns = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(
      "app/agent-plugin/plugins/orbe-agent/skills/automation/references/patterns.md")
}
