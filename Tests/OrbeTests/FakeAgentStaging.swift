import Foundation
import XCTest

@testable import Orbe

/// L4 が起こす偽 agent。`marker` はコマンドの中で 2 つの文字列リテラルに割れているので、
/// **連結された形はシェルが実際に評価した出力にしか現れない**（入力行の描き返しは目印にならない）。
struct FakeAgent {
  let path: String
  let marker: String
}

/// 偽 agent の実行体をテスト専用 dir へ置き、`ShellPATH` をそこ先頭へ差し替える支援。
/// 検出はマシン依存なので、L4 のエージェント系テストは必ずこれで固定する（開発者の Mac には本物の
/// claude / codex が居る）。
extension OrbeTestCase {
  /// 実行可能な偽 agent を置く。`body` はマーカー行の後に続くシェル本文で、既定は入力を反響しながら
  /// 起動しっぱなしになる（即終了すると surface が閉じてタブごと消える）。
  /// `AgentLauncher.init` が構築時に 1 回検出するので、**`startControlProcess()` より前に**呼ぶこと。
  /// `ShellPATH.shared` は `TestIsolation.beginCase` がテストごとに張り直すので戻しは要らない。
  func stageFakeAgent(_ command: String, body: String = "exec /bin/cat") throws -> FakeAgent {
    let caseDir = try XCTUnwrap(TestIsolation.caseDir, "テスト専用ディレクトリが配られていない")
    let dir = caseDir.appendingPathComponent("fake-bin", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let marker = "L4AGENT_" + String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    let split = marker.replacingOccurrences(of: "_", with: "\"\"_")  // L4AGENT""_xxxx
    let executable = dir.appendingPathComponent(command)
    // 引数もそのまま出す（resume が `resume <id>` を渡したことを画面で確かめるため）。
    try """
    #!/bin/sh
    echo "\(split) $*"
    \(body)
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let fakeDir = dir.path
    ShellPATH.shared = ShellPATH(probe: { "\(fakeDir):/usr/bin:/bin" })
    return FakeAgent(path: executable.path, marker: marker)
  }

  /// 偽 agent の検出完了を待つ（`AgentCatalog.refresh` は非同期）。
  func waitForDetection(
    _ control: ControlProcess, _ command: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(
      waitUntil(ControlProcess.tabSettleTimeout) {
        control.target.agentLauncher.detectedCommands.contains(command)
      }, "偽 \(command) が検出されない（ShellPATH の差し替えが効いていない）", file: file, line: line)
  }

  /// タブの画面に文字列が `times` 回以上現れるまで待つ。読むのは実バイナリの `orb tab text`。
  @discardableResult
  func waitForTabText(
    _ control: ControlProcess, tab: Int, contains needle: String, times: Int = 1,
    file: StaticString = #filePath, line: UInt = #line
  ) -> String {
    var text = ""
    let seen = waitUntil(ControlProcess.tabSettleTimeout) {
      text = control.orb(["tab", "text", "\(tab)", "--scrollback"]).stdout
      return text.components(separatedBy: needle).count - 1 >= times
    }
    XCTAssertTrue(
      seen, "タブ \(tab) に \"\(needle)\" が \(times) 回以上現れない: \(text)", file: file, line: line)
    return text
  }
}
