import OrbeTestSupport
import XCTest

@testable import Orbe

/// 実 git のリポジトリの足場（`GitFixtureTemplate` と、それを複製する `TempGitRepo`）の契約。
///
/// 壊れると何が起きるか: 生成で起動する git が増えて、足場を複製に替えた分の短縮が黙って消える。複製が、index と作業ツリーの
/// 食い違ったまま始まり、git で組んだ直後とは違う状態でテストが走る。素の `git status` が index を書き換えるかどうかが
/// テストの実行の順序と時刻で変わり、ファイル監視に届く通知の数が揺れる。あるテストの書き込みがテンプレートに残り、
/// 後のテストが別の中身のリポジトリを受け取る。
final class GitFixtureTemplateTests: OrbeTestCase {
  /// テンプレートが在れば、基本形の生成で起動する git は index を合わせる 1 回だけで、初回コミット前の形では 0 回。
  /// 起動は git 自身の記録（`GIT_TRACE2`）で数える。基本形で 1 回と数えられることが、記録が効いている証拠になる。
  func testCreatingATempGitRepoLaunchesOneGitAndNoneBeforeTheFirstCommit() throws {
    _ = try TempGitRepo()
    _ = try TempGitRepo(initialCommit: false)

    XCTAssertEqual(try gitLaunches { _ = try TempGitRepo() }, 1, "基本形は index を合わせる 1 回")
    XCTAssertEqual(
      try gitLaunches { _ = try TempGitRepo(initialCommit: false) }, 0, "追跡ファイルが無いので合わせない")
  }

  /// 複製は、作られた時刻に依らず同じ状態で始まる: index が覚えているファイルの情報が複製の作業ツリーと一致し
  /// （`git diff-files` は index を読み直さずに比べるので、食い違えば追跡ファイルを出力する）、素の `git status` が
  /// `.git/index` を書き換えない。確かめるのは、racy git の窓がいちばん効く場合: テンプレートを作った直後の複製で、
  /// 組み方がファイルの時刻を未来へずらした場合（index を書いた時刻より後に変わったファイルとして、git は毎回読み直す）。
  func testCopyStartsWithItsIndexMatchingTheWorkingTreeEvenRightAfterTheTemplateIsBuilt() throws {
    let template = GitFixtureTemplate(name: "orbe-racy-check") { url in
      try GitFixtureTemplate.git(["init", "-q", "-b", "main"], in: url.path)
      let file = url.appendingPathComponent("a.txt")
      try Data("one\n".utf8).write(to: file)
      try GitFixtureTemplate.git(["add", "-A"], in: url.path)
      try GitFixtureTemplate.git(Self.identity + ["commit", "-qm", "init"], in: url.path)
      try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
    }
    let copy = TestScratch.caseDir.appendingPathComponent("copy")
    try template.copy(to: copy)

    let diff = git(["diff-files", "--name-only"], in: copy.path)
    XCTAssertTrue(diff.isSuccess, diff.stderrText)
    XCTAssertEqual(diff.stdoutText, "", "index が作業ツリーと食い違うファイル")

    let index = copy.appendingPathComponent(".git/index")
    let before = try indexFile(index)
    XCTAssertTrue(git(["status"], in: copy.path).isSuccess)
    XCTAssertEqual(try indexFile(index), before, "素の git status が index を書き換えた")
  }

  /// 複製を書き換えても（コミットの追加・ファイルの削除・設定の変更）、後から作った複製は元の中身のまま。
  func testRewritingACopyLeavesLaterCopiesAsTheyWere() throws {
    let first = try TempGitRepo()
    let initial = first.head()
    try first.write("b.txt", "two\n")
    XCTAssertTrue(first.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(first.git(["commit", "-qm", "second"]).isSuccess)
    try FileManager.default.removeItem(at: first.dir.appendingPathComponent("a.txt"))
    XCTAssertTrue(first.git(["config", "user.name", "changed"]).isSuccess)

    let second = try TempGitRepo()

    XCTAssertEqual(second.head(), initial, "初期コミットのまま")
    XCTAssertEqual(
      try String(contentsOf: second.dir.appendingPathComponent("a.txt"), encoding: .utf8), "one\n")
    XCTAssertEqual(second.git(["status", "--porcelain"]).stdoutText, "", "作業ツリーも初期コミットのまま")
    XCTAssertEqual(second.git(["config", "user.name"]).stdoutText, "t\n")
  }

  /// テンプレートは書き換えられない: origin を向け直していない複製の clone からの push は、テンプレートの origin に
  /// 書けずに失敗する（書ければ、後のテストの複製に黙って漏れる）。向け直した後は、複製の中の origin に届く。
  func testCloneInACopyCannotPushToTheTemplateButCanAfterRedirectingOrigin() throws {
    let template = GitFixtureTemplate(name: "orbe-template-check") { url in
      let origin = url.appendingPathComponent("origin.git").path
      let clone = url.appendingPathComponent("clone").path
      try GitFixtureTemplate.git(["init", "-q", "--bare", "-b", "main", origin], in: url.path)
      try GitFixtureTemplate.git(["clone", "-q", origin, clone], in: url.path)
      try GitFixtureTemplate.git(
        Self.identity + ["commit", "-q", "--allow-empty", "-m", "a"], in: clone)
      try GitFixtureTemplate.git(["push", "-q", "origin", "HEAD:main"], in: clone)
    }
    let copy = TestScratch.caseDir.appendingPathComponent("pair")
    try template.copy(to: copy)
    let origin = copy.appendingPathComponent("origin.git").path
    let clone = copy.appendingPathComponent("clone").path
    XCTAssertTrue(
      git(Self.identity + ["commit", "-q", "--allow-empty", "-m", "b"], in: clone).isSuccess)

    XCTAssertFalse(
      git(["push", "-q", "origin", "HEAD:main"], in: clone).isSuccess, "向け直す前は、テンプレートの origin に書けない"
    )

    XCTAssertTrue(git(["remote", "set-url", "origin", origin], in: clone).isSuccess)
    XCTAssertTrue(git(["push", "-q", "origin", "HEAD:main"], in: clone).isSuccess)
    XCTAssertEqual(
      git(["rev-parse", "main"], in: origin).stdoutText,
      git(["rev-parse", "HEAD"], in: clone).stdoutText,
      "複製の中の origin に届く")
  }

  /// `TempGitRepo` はテストの作業ディレクトリの下に置かれる（テストの終わりに消え、次のテストへ残らない）。
  func testTempGitRepoLivesUnderTheTestsWorkingDirectory() throws {
    let repo = try TempGitRepo()

    XCTAssertTrue(
      repo.dir.standardizedFileURL.path.hasPrefix(
        TestScratch.caseDir.standardizedFileURL.path + "/"),
      "\(repo.dir.path) が \(TestScratch.caseDir.path) の下に無い")
  }

  // MARK: - ヘルパ

  private static let identity = ["-c", "user.email=t@example.com", "-c", "user.name=t"]

  /// `body` の間に起動された git の数。`GIT_TRACE2` を作業ディレクトリの中のファイルへ向け、git が起動のたびに書く
  /// `start` の行を数える。`GIT_TRACE2` は終わりに元へ戻す。
  private func gitLaunches(_ body: () throws -> Void) throws -> Int {
    let trace = TestScratch.caseDir.appendingPathComponent("trace2-\(UUID().uuidString)")
    let previous = ProcessInfo.processInfo.environment["GIT_TRACE2"]
    setenv("GIT_TRACE2", trace.path, 1)
    defer {
      if let previous { setenv("GIT_TRACE2", previous, 1) } else { unsetenv("GIT_TRACE2") }
    }
    try body()
    let lines = ((try? String(contentsOf: trace, encoding: .utf8)) ?? "").split(separator: "\n")
    return lines.filter { $0.split(separator: " ").dropFirst(2).first == "start" }.count
  }

  /// index の中身と実体（git は書き換えるとき、別のファイルを作って置き換える）。
  private func indexFile(_ url: URL) throws -> IndexFile {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return IndexFile(
      contents: try Data(contentsOf: url),
      fileNumber: try XCTUnwrap(attributes[.systemFileNumber] as? Int))
  }

  private struct IndexFile: Equatable {
    let contents: Data
    let fileNumber: Int
  }

  @discardableResult
  private func git(_ args: [String], in cwd: String) -> GitRunner.Output {
    GitRunner.shared.runSync(args, cwd: cwd)
  }
}
