import XCTest

@testable import Orbe

/// automations.json だけが持つ「使えない」の判定（ID の重複・採番位置・提案のリンクの重複・定義の不正）で、原本を
/// `automations-broken-<日時>.json` へ退避して空で始めること。
///
/// 壊れると何が起きるか: 同じリンクの提案が 2 件ある原本をそのまま読み「提案はリンク単位で 1 つ」が崩れる。次の追加が
/// 既存の受信の ID を振り直す。取得役に組み込みのツールを渡す定義が、検証を通らずに無人で回る。
@MainActor
final class AutomationQuarantineTests: OrbeTestCase {
  private func quarantineFiles() throws -> [URL] {
    let dir = try automationsFile().deletingLastPathComponent()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasPrefix("automations-broken-") && $0.hasSuffix(".json") }
      .sorted().map { dir.appendingPathComponent($0) }
  }

  /// 検証を通さずに書いた原本が、退避されて空で始まる。
  private func assertQuarantined(
    _ reason: String, file: StaticString = #filePath, line: UInt = #line,
    _ breaking: (inout AutomationsFile) -> Void
  ) throws {
    var broken = DesignSceneFixtures.automationDesignFile()
    breaking(&broken)
    let original = try AutomationWire.encoder(pretty: true).encode(broken)
    try original.write(to: automationsFile())

    XCTAssertNil(AutomationPersistence.load(), "\(reason) は空で始める", file: file, line: line)

    let quarantined = try quarantineFiles()
    XCTAssertEqual(quarantined.count, 1, "\(reason) の原本は退避される", file: file, line: line)
    XCTAssertEqual(
      try Data(contentsOf: XCTUnwrap(quarantined.first)), original, "退避物は原本とバイト単位で一致する",
      file: file, line: line)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: try automationsFile().path), "原位置は空く", file: file,
      line: line)
  }

  /// 前提: 手を加えない見本の原本は読める（下の退避は、書き換えた規則のせいで起きている）。
  func testTheUntouchedFixtureLoads() throws {
    try AutomationWire.encoder(pretty: true).encode(DesignSceneFixtures.automationDesignFile())
      .write(to: automationsFile())
    XCTAssertNotNil(AutomationPersistence.load())
  }

  func testDuplicateAutomationIdsAreQuarantined() throws {
    try assertQuarantined("受信の ID の重複") { $0.automations.append($0.automations[0]) }
  }

  func testAutomationIdAtOrBeyondTheNextIdIsQuarantined() throws {
    try assertQuarantined("採番位置と矛盾する ID") {
      $0.nextAutomationId = $0.automations.map(\.id).max() ?? 1
    }
  }

  func testDuplicateProposalLinksAreQuarantined() throws {
    try assertQuarantined("提案のリンクの重複") { file in
      let first = file.proposals[0]
      file.proposals.append(
        AutomationProposal(
          id: file.nextProposalId, automationId: first.automationId, item: first.item,
          title: "同じリンク",
          due: nil, proposedAt: first.proposedAt, state: .open))
      file.nextProposalId += 1
    }
  }

  func testInvalidDefinitionIsQuarantined() throws {
    try assertQuarantined("取得役に組み込みのツール") {
      $0.automations[0].redefine {
        $0.source?.method = .agent(
          AutomationSourceAgent(cli: "claude", model: "haiku", tools: ["Read"], request: "DM"))
      }
    }
  }
}
