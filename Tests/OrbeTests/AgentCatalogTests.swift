import OrbeTestSupport
import XCTest

@testable import Orbe

/// AgentCatalog.resolve（PATH 文字列からの実行ファイル解決・検出の純粋部分）の検証。
/// 走査する PATH をどう得るかは `ShellPATH` の関心で、`ShellPATHTests` が持つ。
final class AgentCatalogTests: OrbeTestCase {
  private var dirA: URL!
  private var dirB: URL!

  override func setUpWithError() throws {
    let base = TestScratch.caseDir
      .appendingPathComponent("AgentCatalogTests-\(UUID().uuidString)")
    dirA = base.appendingPathComponent("a")
    dirB = base.appendingPathComponent("b")
    try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
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

  func testEmptyPathEntriesAreIgnored() throws {
    let claude = try place("claude", in: dirA)
    let found = AgentCatalog.resolve(in: "::\(dirA.path):")
    XCTAssertEqual(found.map(\.path), [claude], "PATH 中の空エントリで落ちない")
  }

  // MARK: - resume コマンド構築

  func testResumeCommandRejectsUnknownAgent() {
    XCTAssertNil(
      AgentCatalog.resumeCommand(AgentCLI(command: "bash", path: "/bin/bash"), sessionId: "abc-123")
    )
  }

  /// sessionId は安全な文字集合（UUID 等）のみ許可し、shell インジェクションを防ぐ。
  func testResumeCommandRejectsUnsafeSessionId() {
    XCTAssertNil(
      AgentCatalog.resumeCommand(AgentCLI(command: "claude", path: "/bin/claude"), sessionId: ""),
      "空は不可")
    XCTAssertNil(
      AgentCatalog.resumeCommand(
        AgentCLI(command: "claude", path: "/bin/claude"), sessionId: "a b"), "空白は不可")
    XCTAssertNil(
      AgentCatalog.resumeCommand(
        AgentCLI(command: "claude", path: "/bin/claude"), sessionId: "x; rm -rf /"), "メタ文字は不可")
    XCTAssertEqual(
      AgentCatalog.resumeCommand(
        AgentCLI(command: "claude", path: "/bin/claude"),
        sessionId: "27d05777-57b4-4baa-9532-bc4cac1375cb"),
      "/bin/claude --resume 27d05777-57b4-4baa-9532-bc4cac1375cb", "UUID は許可")
  }

  /// 会話の最初の入力は、その CLI の席に 1 つのシェルの単語として添える（位置引数ならオプションの終わり `--` の後ろ、
  /// agy は `-i` の値）。`-` で始まる入力も、CLI のオプションとしては読まれない。
  func testResumeCommandAddsTheFirstInputAtEachCLIsSeat() {
    XCTAssertEqual(
      AgentCatalog.resumeCommand(
        AgentCLI(command: "claude", path: "/bin/claude"), sessionId: "s-1", firstInput: "解けた"),
      "/bin/claude --resume s-1 -- '解けた'")
    XCTAssertEqual(
      AgentCatalog.resumeCommand(
        AgentCLI(command: "codex", path: "/bin/codex"), sessionId: "s-1", firstInput: "done"),
      "/bin/codex --no-daemon resume s-1 -- done")
    XCTAssertEqual(
      AgentCatalog.resumeCommand(
        AgentCLI(command: "agy", path: "/bin/agy"), sessionId: "s-1", firstInput: "done"),
      "/bin/agy --dangerously-skip-permissions --conversation s-1 -i done")
    XCTAssertEqual(
      AgentCatalog.startCommand(
        AgentCLI(command: "claude", path: "/bin/claude"), firstInput: "- 箇条書き"),
      "/bin/claude -- '- 箇条書き'")
  }

  /// codex は新規起動でも、デーモンを使わない引数をコマンド名の直後に置く（再開の形は上のテストが固定する）。
  func testCodexStartsWithoutTheDaemon() {
    XCTAssertEqual(
      AgentCatalog.startCommand(AgentCLI(command: "codex", path: "/bin/codex"), firstInput: "頼み"),
      "/bin/codex --no-daemon -- '頼み'")
  }

  /// agy は新規起動でも、1 手ごとの確認を出させない引数をコマンド名の直後に置く（再開の形は上のテストが固定する）。
  /// 確認の待ちは hook で報告されないので、付け忘れた入口の agy は確認で止まったまま作業中に見える。
  func testAgyStartsWithoutPerActionConfirmations() {
    let agy = AgentCLI(command: "agy", path: "/bin/agy")
    XCTAssertEqual(AgentCatalog.startCommand(agy), "/bin/agy --dangerously-skip-permissions")
    XCTAssertEqual(
      AgentCatalog.startCommand(agy, firstInput: "頼み"),
      "/bin/agy --dangerously-skip-permissions -i '頼み'")
  }

  /// 席に置けない制御文字（改行・タブ以外の C0・DEL・C1）は空白にして添える。NUL はコマンドの C 文字列をそこで切り、
  /// 起動を壊す。新規起動でも再開でも同じ。
  func testFirstInputControlCharactersOtherThanNewlineAndTabBecomeSpaces() {
    let input = "a\u{0}b\u{1B}[1mc\u{7F}d\u{85}e\nf\tg"
    let seated = "'a b [1mc d e\nf\tg'"
    XCTAssertEqual(
      AgentCatalog.startCommand(
        AgentCLI(command: "claude", path: "/bin/claude"), firstInput: input),
      "/bin/claude -- \(seated)")
    XCTAssertEqual(
      AgentCatalog.resumeCommand(
        AgentCLI(command: "claude", path: "/bin/claude"), sessionId: "s-1", firstInput: input),
      "/bin/claude --resume s-1 -- \(seated)")
  }

  /// 外の人が書いた文面（確認の出力）を含む入力でも、シェルは 1 語として読み、何も実行しない。
  func testFirstInputReachesTheCLIAsOneWordWithoutRunningAnything() throws {
    let input = "レビューが付いた\n@sato: it's $(touch pwned) `touch pwned2`; \"x\""
    let command = try XCTUnwrap(
      AgentCatalog.resumeCommand(
        AgentCLI(command: "codex", path: "/bin/codex"), sessionId: "s-1", firstInput: input))
    let dir = TestScratch.caseDir.appendingPathComponent("run")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c", "set -- " + command.dropFirst("/bin/codex ".count) + "; printf %s \"$5\"",
    ]
    process.currentDirectoryURL = dir
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()

    XCTAssertEqual(
      String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), input)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: dir.path), [],
      "入力の中のコマンドは走らない")
  }
}
