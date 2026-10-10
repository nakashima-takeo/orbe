import XCTest

@testable import Orbe

/// intakes.json だけが持つ「使えない」の判定（ID の重複・採番位置・提案のリンクの重複・定義の不正）で、原本を
/// `intakes-broken-<日時>.json` へ退避して空で始めること。
///
/// 壊れると何が起きるか: 同じリンクの提案が 2 件ある原本をそのまま読み「提案はリンク単位で 1 つ」が崩れる。次の追加が
/// 既存の受信の ID を振り直す。取得役に組み込みのツールを渡す定義が、検証を通らずに無人で回る。
@MainActor
final class IntakeQuarantineTests: OrbeTestCase {
  private func quarantineFiles() throws -> [URL] {
    let dir = try intakesFile().deletingLastPathComponent()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasPrefix("intakes-broken-") && $0.hasSuffix(".json") }
      .sorted().map { dir.appendingPathComponent($0) }
  }

  /// 検証を通さずに書いた原本が、退避されて空で始まる。
  private func assertQuarantined(
    _ reason: String, file: StaticString = #filePath, line: UInt = #line,
    _ breaking: (inout IntakesFile) -> Void
  ) throws {
    var broken = DesignSceneFixtures.intakeDesignFile()
    breaking(&broken)
    let original = try IntakeWire.encoder(pretty: true).encode(broken)
    try original.write(to: intakesFile())

    XCTAssertNil(IntakePersistence.load(), "\(reason) は空で始める", file: file, line: line)

    let quarantined = try quarantineFiles()
    XCTAssertEqual(quarantined.count, 1, "\(reason) の原本は退避される", file: file, line: line)
    XCTAssertEqual(
      try Data(contentsOf: XCTUnwrap(quarantined.first)), original, "退避物は原本とバイト単位で一致する",
      file: file, line: line)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: try intakesFile().path), "原位置は空く", file: file,
      line: line)
  }

  /// 前提: 手を加えない見本の原本は読める（下の退避は、書き換えた規則のせいで起きている）。
  func testTheUntouchedFixtureLoads() throws {
    try IntakeWire.encoder(pretty: true).encode(DesignSceneFixtures.intakeDesignFile())
      .write(to: intakesFile())
    XCTAssertNotNil(IntakePersistence.load())
  }

  func testDuplicateIntakeIdsAreQuarantined() throws {
    try assertQuarantined("受信の ID の重複") { $0.intakes.append($0.intakes[0]) }
  }

  func testIntakeIdAtOrBeyondTheNextIdIsQuarantined() throws {
    try assertQuarantined("採番位置と矛盾する ID") {
      $0.nextIntakeId = $0.intakes.map(\.id).max() ?? 1
    }
  }

  func testDuplicateProposalLinksAreQuarantined() throws {
    try assertQuarantined("提案のリンクの重複") { file in
      let first = file.proposals[0]
      file.proposals.append(
        IntakeProposal(
          id: file.nextProposalId, intakeId: first.intakeId, item: first.item, title: "同じリンク",
          due: nil, proposedAt: first.proposedAt, state: .open))
      file.nextProposalId += 1
    }
  }

  func testInvalidDefinitionIsQuarantined() throws {
    try assertQuarantined("取得役に組み込みのツール") {
      $0.intakes[0].definition.fetch.method = .agent(
        IntakeAgentFetch(cli: "claude", model: "haiku", tools: ["Read"], request: "DM"))
    }
  }
}
