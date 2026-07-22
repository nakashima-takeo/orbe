import XCTest

@testable import Orbe

/// AgentCatalog.resolve（PATH 文字列からの実行ファイル解決・検出の純粋部分）の検証。
/// ログインシェル起動（loginShellPATH）は環境依存のため対象外。
final class AgentCatalogTests: XCTestCase {
  private var base: URL!
  private var dirA: URL!
  private var dirB: URL!

  override func setUpWithError() throws {
    base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("AgentCatalogTests-\(UUID().uuidString)")
    dirA = base.appendingPathComponent("a")
    dirB = base.appendingPathComponent("b")
    try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: base)
  }

  private func place(_ name: String, in dir: URL, executable: Bool = true) throws -> String {
    let url = dir.appendingPathComponent(name)
    try Data("#!/bin/sh\n".utf8).write(to: url)
    if executable {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    return url.path
  }

  func testResolvesInSupportedOrderNotPathOrder() throws {
    let agy = try place("agy", in: dirA)
    let claude = try place("claude", in: dirB)
    let found = AgentCatalog.resolve(in: "\(dirA.path):\(dirB.path)")
    XCTAssertEqual(
      found,
      [
        AgentCLI(command: "claude", path: claude),
        AgentCLI(command: "agy", path: agy),
      ],
      "並びは PATH 順ではなく supported 順（claude > codex > agy）")
  }

  func testFirstPathHitWins() throws {
    let first = try place("claude", in: dirA)
    _ = try place("claude", in: dirB)
    let found = AgentCatalog.resolve(in: "\(dirA.path):\(dirB.path)")
    XCTAssertEqual(found.map(\.path), [first], "同名コマンドは PATH の先勝ち")
  }

  func testNonExecutableIsSkipped() throws {
    _ = try place("codex", in: dirA, executable: false)
    let exec = try place("codex", in: dirB)
    let found = AgentCatalog.resolve(in: "\(dirA.path):\(dirB.path)")
    XCTAssertEqual(found.map(\.path), [exec], "実行権の無いファイルは候補にしない")
  }

  func testEmptyWhenNothingInstalled() {
    XCTAssertEqual(AgentCatalog.resolve(in: dirA.path), [])
  }

  func testEmptyPathEntriesAreIgnored() throws {
    let claude = try place("claude", in: dirA)
    let found = AgentCatalog.resolve(in: "::\(dirA.path):")
    XCTAssertEqual(found.map(\.path), [claude], "PATH 中の空エントリで落ちない")
  }

  // MARK: - resume コマンド構築

  func testResumeCommandSyntaxPerCLI() {
    XCTAssertEqual(
      AgentCatalog.resumeCommand(forAgent: "claude", sessionId: "abc-123"),
      "claude --resume abc-123")
    XCTAssertEqual(
      AgentCatalog.resumeCommand(forAgent: "agy", sessionId: "abc-123"),
      "agy --conversation abc-123", "agy は --conversation 形式")
    XCTAssertEqual(
      AgentCatalog.resumeCommand(forAgent: "codex", sessionId: "abc-123"),
      "codex resume abc-123", "codex は resume サブコマンド形式")
  }

  func testResumeCommandRejectsUnknownAgent() {
    XCTAssertNil(AgentCatalog.resumeCommand(forAgent: "bash", sessionId: "abc-123"))
  }

  /// sessionId は安全な文字集合（UUID 等）のみ許可し、shell インジェクションを防ぐ。
  func testResumeCommandRejectsUnsafeSessionId() {
    XCTAssertNil(AgentCatalog.resumeCommand(forAgent: "claude", sessionId: ""), "空は不可")
    XCTAssertNil(AgentCatalog.resumeCommand(forAgent: "claude", sessionId: "a b"), "空白は不可")
    XCTAssertNil(
      AgentCatalog.resumeCommand(forAgent: "claude", sessionId: "x; rm -rf /"), "メタ文字は不可")
    XCTAssertEqual(
      AgentCatalog.resumeCommand(
        forAgent: "claude", sessionId: "27d05777-57b4-4baa-9532-bc4cac1375cb"),
      "claude --resume 27d05777-57b4-4baa-9532-bc4cac1375cb", "UUID は許可")
  }
}
