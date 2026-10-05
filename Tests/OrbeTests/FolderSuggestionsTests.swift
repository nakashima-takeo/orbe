import XCTest

@testable import Orbe

/// `FolderSuggestions`（純関数のディレクトリ補完）の検証。tmp dir に実 FS を組んで
/// 前方一致・ディレクトリ限定・git 判定・隠し扱い・不在の各契約を固定する。
final class FolderSuggestionsTests: OrbeTestCase {
  private var root: URL!
  private let fm = FileManager.default

  override func setUpWithError() throws {
    try super.setUpWithError()
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("folder-suggestions-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? fm.removeItem(at: root)
    root = nil
    try super.tearDownWithError()
  }

  private func mkdir(_ name: String) throws {
    try fm.createDirectory(
      at: root.appendingPathComponent(name), withIntermediateDirectories: true)
  }
  private func mkfile(_ name: String, _ contents: String = "") throws {
    try Data(contents.utf8).write(to: root.appendingPathComponent(name))
  }
  private func compute(_ input: String) -> [FolderSuggestion] {
    FolderSuggestions.compute(input: input)
  }
  private func names(_ input: String) -> [String] {
    compute(input).map(\.name)
  }

  func testPrefixMatchesChildDirectoriesIgnoringCase() throws {
    try mkdir("api")
    try mkdir("App")
    try mkdir("web")
    try mkfile("apple.txt")  // ファイルは候補にしない
    XCTAssertEqual(names(root.path + "/ap"), ["api", "App"], "末尾 'ap' の前方一致（大小無視）・名前昇順・dir のみ")
    XCTAssertEqual(names(root.path + "/"), ["api", "App", "web"], "末尾 / はキー空＝全子")
  }

  func testAChildWithGitIsTaggedAsARepo() throws {
    try mkdir("repo")
    try mkdir("repo/.git")
    try mkdir("wt")
    try mkfile("wt/.git", "gitdir: /somewhere")  // worktree の .git はファイル
    try mkdir("plain")
    let isRepo = Dictionary(
      uniqueKeysWithValues: compute(root.path + "/").map { ($0.name, $0.isRepo) })
    XCTAssertEqual(isRepo, ["repo": true, "wt": true, "plain": false])
  }

  func testHiddenExcludedUnlessDotKey() throws {
    try mkdir(".config")
    try mkdir("visible")
    XCTAssertEqual(names(root.path + "/"), ["visible"], "キーが . 始まりでなければ隠しを除外")
    XCTAssertEqual(names(root.path + "/."), [".config"], ". 始まりキーでは隠しを含める")
  }

  func testMissingParentReturnsEmpty() {
    XCTAssertTrue(compute(root.path + "/nope/child").isEmpty, "親が存在しなければ空")
  }

  func testFullPathIsAbsolute() throws {
    try mkdir("api")
    XCTAssertEqual(
      compute(root.path + "/ap").first?.fullPath,
      (root.path as NSString).appendingPathComponent("api"), "fullPath は展開済みの絶対パス")
  }
}
