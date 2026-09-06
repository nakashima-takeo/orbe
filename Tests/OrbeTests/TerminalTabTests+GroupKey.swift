import XCTest

@testable import Orbe

/// タブの所属キー（`groupKey`）——cwd が属する git worktree ルート、管理外は cwd 自身（Q1）。
/// cwd が変わったときに再計算され、`onPwdChange` が呼ばれる時点で新しいキーになっている
/// （`WindowController` はその中で `regroup` を呼ぶ）。
extension TerminalTabTests {

  private func gitRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-tab-key-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    return root
  }

  /// git 管理下なら worktree ルート、サブディレクトリで開いたタブも同じキー（同 worktree のタブは 1 連）。
  func testGroupKeyIsWorktreeRootForTabsAnywhereInside() throws {
    let root = try gitRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = GitWorktreeRoot.normalizedPath(root.path)

    XCTAssertEqual(TerminalTab(cwd: root.path).groupKey, expected)
    XCTAssertEqual(
      TerminalTab(cwd: root.appendingPathComponent("src").path).groupKey, expected,
      "サブディレクトリでもルートがキー")
  }

  /// git 管理外は cwd 自身（実パス）。同じ場所を指す cwd の 2 枚は、書き方が違っても管理外でも連なる（Q1）。
  func testGroupKeyFallsBackToCwdItselfOutsideGit() throws {
    let plain = "/tmp/orbe-plain-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: plain) }

    XCTAssertEqual(
      TerminalTab(cwd: plain).groupKey, GitWorktreeRoot.normalizedPath(plain), "cwd 自身の実パス")
    XCTAssertEqual(
      TerminalTab(cwd: "/private" + plain).groupKey, TerminalTab(cwd: plain).groupKey,
      "/private/tmp と /tmp は同じ場所＝同キー")
  }

  /// 復元したタブは保存 cwd から同じ規則で導く（キーは永続しない）。
  func testRestoredTabDerivesGroupKeyFromSavedCwd() throws {
    let root = try gitRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = TabState(
      cwd: root.appendingPathComponent("src").path, agent: nil, explicitTitle: nil)

    let tab = TerminalTab(restoring: state) { _ in nil }

    XCTAssertEqual(tab.groupKey, GitWorktreeRoot.normalizedPath(root.path))
  }

  /// cwd の報告（OSC 7）でキーが再計算され、`onPwdChange` が呼ばれる時点で既に新しいキーになっている。
  func testPwdChangeRecomputesGroupKeyBeforeNotifying() throws {
    let root = try gitRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let tab = TerminalTab(cwd: "/tmp")
    var keyWhenNotified: String?
    tab.onPwdChange = { keyWhenNotified = tab.groupKey }

    tab.surface.currentPwd = root.appendingPathComponent("src").path

    XCTAssertEqual(keyWhenNotified, GitWorktreeRoot.normalizedPath(root.path), "通知時点で新キー")
    XCTAssertEqual(tab.groupKey, keyWhenNotified)
  }
}
