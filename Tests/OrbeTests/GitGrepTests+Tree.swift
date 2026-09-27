import OrbeEditorCore
import XCTest

@testable import Orbe

/// 本物の git で、プロジェクト検索のディスク側が何を探すか——根が git 管理下でも管理外でも同じ形で、`.gitignore`（入れ子も）・
/// `.git/info/exclude`・既定の除外・バイナリ・`.git` は出ず、入れ子のリポジトリの中は探し、パスは引用されずに読める。開いている
/// 文書をメモリで探すかの判定（`isExcluded`）は git に渡す除外と同じ規則。大小無視はロケールの無い環境（Finder から起動した
/// アプリ）でも ASCII の外に効く。
///
/// 壊れると何が起きるか。`node_modules` や無視したビルド成果物が結果を埋める。git 管理外の根では `.gitignore` が効かない。
/// 開いている `node_modules` の文書だけ結果に出る。日本語や改行を含む名前のファイルが結果から消える・別のパスになる。
/// Finder から起動したときだけ `ärger` が `ÄRGER` に当たらない。
extension GitGrepTests {
  /// 検索語 `needle` の問いで根を探し、一致したパスの集合と終わりを返す。
  private func grep(_ root: String, _ query: SearchQuery = SearchQuery(pattern: "needle")) throws
    -> (paths: Set<String>, output: GitRunner.Output)
  {
    let lock = NSLock()
    var parser = GitGrep.Parser()
    var paths: Set<String> = []
    var ended: GitRunner.Output?
    _ = GitRunner.shared.stream(
      GitGrep.arguments(pattern: try query.compiled().pcre), cwd: root,
      environment: GitGrep.environment,
      onOutput: { data in lock.withLock { paths.formUnion(parser.feed(data).map(\.path)) } },
      completion: { output in lock.withLock { ended = output } })
    let deadline = Date().addingTimeInterval(20)
    while lock.withLock({ ended == nil }), Date() < deadline { usleep(10_000) }
    return try lock.withLock { (paths, try XCTUnwrap(ended, "git grep が終わらない")) }
  }

  /// 探されるファイルと、出ないファイル（既定の除外に当たるものは `defaultExcluded`）を根の下に置く。
  private func layTree(at root: String) throws -> (found: Set<String>, defaultExcluded: [String]) {
    let found: Set<String> = [
      "src/tracked.txt", "new.txt", "sub/keep.txt", "inner/in.txt", "日本/ファイル.txt", "we\nird.txt",
    ]
    let defaultExcluded = [
      "node_modules/pkg/i.js", "deep/bower_components/x.js", ".DS_Store", "q.code-search",
    ]
    for path in found.union(defaultExcluded).union(["ignored.txt", "sub/x.log", "inner/secret.txt"])
    {
      try write(root, path, "a needle here\n")
    }
    try write(root, ".gitignore", "ignored.txt\n")
    try write(root, "sub/.gitignore", "*.log\n")
    try write(root, "inner/.gitignore", "secret.txt\n")
    let binary = URL(fileURLWithPath: root).appendingPathComponent("bin.dat")
    try (Data("needle".utf8) + Data([0, 1, 2])).write(to: binary)
    XCTAssertTrue(
      GitRunner.shared.runSync(["init", "-q"], cwd: root + "/inner").isSuccess, "入れ子のリポジトリ")
    try write(root, "inner/.git/needle.txt", "needle\n")
    return (found, defaultExcluded)
  }

  private func write(_ root: String, _ path: String, _ text: String) throws {
    let url = URL(fileURLWithPath: root).appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  func testAManagedRootSearchesTheWorkingTreeMinusWhatIsIgnoredOrExcluded() throws {
    let repo = try TempGitRepo()
    addTeardownBlock { repo.cleanup() }
    let tree = try layTree(at: repo.root)
    try write(repo.root, "excluded.txt", "needle\n")
    try write(repo.root, ".git/info/exclude", "excluded.txt\n")
    XCTAssertTrue(repo.git(["add", "src/tracked.txt"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "tracked"]).isSuccess)

    let result = try grep(repo.root)
    XCTAssertEqual(result.paths, tree.found)
    XCTAssertEqual(result.output.status, 0)
    for path in tree.defaultExcluded { XCTAssertTrue(GitGrep.isExcluded(path), path) }
    for path in tree.found { XCTAssertFalse(GitGrep.isExcluded(path), path) }
  }

  /// git 管理外の根でも同じ形で探し、`.gitignore` と既定の除外が効く。
  func testAnUnmanagedRootIsSearchedTheSameWay() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbe-plain-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    let root = GitWorktreeRoot.normalizedPath(dir.path)
    let tree = try layTree(at: root)

    XCTAssertEqual(try grep(root).paths, tree.found)
  }

  /// 大小無視は ASCII の外にも効く——アプリの環境にロケールが無くても（Finder から起動したとき）。
  func testIgnoringCaseReachesBeyondAsciiWithoutALocaleInTheAppEnvironment() throws {
    let repo = try TempGitRepo()
    addTeardownBlock { repo.cleanup() }
    try write(repo.root, "de.txt", "ÄRGER\n")
    let saved = ["LANG", "LC_ALL", "LC_CTYPE"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
    for (key, _) in saved { unsetenv(key) }
    defer {
      for (key, value) in saved {
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
      }
    }

    XCTAssertEqual(try grep(repo.root, SearchQuery(pattern: "ärger")).paths, ["de.txt"])
  }

  /// 一致が無いのはエラーではない。ICU は通すが git（PCRE2）が断る式は、git の断った理由がエラーになる。
  func testNoMatchIsNotAnErrorButARefusedPatternIs() throws {
    let repo = try TempGitRepo()
    addTeardownBlock { repo.cleanup() }

    let none = try grep(repo.root, SearchQuery(pattern: "absent"))
    XCTAssertEqual(none.paths, [])
    XCTAssertNil(GitGrep.failure(of: none.output))

    let refused = try grep(repo.root, SearchQuery(pattern: "(?w)one", isRegex: true))
    guard case .refused(let reason) = GitGrep.failure(of: refused.output) else {
      return XCTFail("git が断った式はエラーになる: \(refused.output)")
    }
    XCTAssertTrue(reason.hasPrefix("fatal:"), reason)
  }
}
