import OrbeTestSupport
import XCTest

@testable import Orbe

/// 根のサービスの baseline（index の版を作業ツリーに出した中身）——index への追従・関心の和集合・filter と eol・
/// 取得失敗の扱い・status との順序。
extension RootFilesTests {
  func testBaselineFollowsTheIndexAndDropsWhenRemovedFromIt() throws {
    let files = RootFiles(root: repo.root)
    let recorder = Recorder()
    let url = repo.url("a.txt")
    files.addObserver(recorder, interest: url)
    pumpMain(until: { files.baseline(for: url) == "one\n" }, "初回取得")
    XCTAssertEqual(recorder.versionChanges, [files.version(of: url, at: .index)])

    try repo.write("a.txt", "two\n")
    pumpMain(until: { files.status?.badge(of: "a.txt") == .modified })
    XCTAssertEqual(files.baseline(for: url), "one\n", "作業ツリーの編集では index 版は変わらない")
    XCTAssertEqual(recorder.versionChanges.count, 1, "OID が同じなら取り直さない")

    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { files.baseline(for: url) == "two\n" }, "git add で追従")
    XCTAssertTrue(repo.git(["rm", "--cached", "-q", "a.txt"]).isSuccess)
    pumpMain(until: { files.baseline(for: url) == nil }, "index から消えれば nil")
    XCTAssertEqual(recorder.versionChanges.count, 3)

    let untracked = repo.url("nope.txt")
    try repo.write("nope.txt", "u\n")
    let untrackedObserver = Recorder()
    files.addObserver(untrackedObserver, interest: untracked)
    pumpMain(until: { files.status?.badge(of: "nope.txt") == .untracked })
    XCTAssertNil(files.baseline(for: untracked), "未追跡は baseline 無し")
  }

  /// baseline は index の版を作業ツリーに出した中身——`eol=crlf` のリポジトリで clean なファイルは、作業ツリーの
  /// バイト列と同じ baseline を持つ（生の blob なら全行が違う）。
  func testBaselineIsTheCheckedOutFormOfTheIndexVersion() throws {
    try repo.write(".gitattributes", "*.txt text eol=crlf\n")
    try repo.write("a.txt", "one\r\ntwo\r\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "crlf"]).isSuccess)
    XCTAssertEqual(repo.git(["status", "--porcelain"]).stdout.count, 0, "前提: clean")

    let files = RootFiles(root: repo.root)
    let recorder = Recorder()
    let url = repo.url("a.txt")
    files.addObserver(recorder, interest: url)
    pumpMain(until: { files.baseline(for: url) != nil }, "初回取得")
    XCTAssertEqual(files.baseline(for: url), "one\r\ntwo\r\n", "作業ツリーと同じ姿")
    XCTAssertNil(files.status?.badge(of: "a.txt"))
  }

  /// blob の取得が git の失敗で落ちても OID は焼き付かず、次の取り直しで取り直す——smudge filter の一時失敗
  /// （git-lfs のネットワーク等）で、そのファイルのガターが閉じ直すまで無言で死なない。
  func testATransientBlobFailureIsRetriedOnTheNextRefresh() throws {
    let allow = repo.dir.appendingPathComponent("smudge-allowed").path
    let tried = repo.dir.appendingPathComponent("smudge-tried").path
    try repo.write(".gitattributes", "*.txt filter=flaky\n")
    XCTAssertTrue(
      repo.git([
        "config", "filter.flaky.smudge",
        "test -e '\(allow)' && cat || { touch '\(tried)'; exit 1; }",
      ]).isSuccess)
    XCTAssertTrue(repo.git(["config", "filter.flaky.clean", "cat"]).isSuccess)
    XCTAssertTrue(repo.git(["config", "filter.flaky.required", "true"]).isSuccess)
    let files = RootFiles(root: repo.root)
    let recorder = Recorder()
    let url = repo.url("a.txt")
    files.addObserver(recorder, interest: url)
    pumpMain(until: { FileManager.default.fileExists(atPath: tried) }, "smudge が 1 回失敗した")
    pumpMain(until: { files.status != nil })
    XCTAssertNil(files.state(of: try XCTUnwrap(files.version(of: url, at: .index))), "一時失敗は焼かない")
    XCTAssertEqual(recorder.versionChanges, [])

    try Data().write(to: URL(fileURLWithPath: allow))
    try repo.write("b.txt", "b\n")
    pumpMain(until: { files.baseline(for: url) == "one\n" }, timeout: 20, "次の取り直しで取り直す")
    XCTAssertEqual(recorder.versionChanges, [files.version(of: url, at: .index)])
  }

  /// 版の OID の一覧を git から取れなければ、まだ状態の無い版は「取れない」に決まって知らせが届く（関心を申告した者が、
  /// 決まらない状態のまま待ち続けない）。
  func testAVersionWhoseOIDsCannotBeListedIsSettledAsFailed() throws {
    let index = repo.dir.appendingPathComponent(".git/index").path
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: index)
    addTeardownBlock {
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: index)
    }
    let files = RootFiles(root: repo.root)
    let recorder = Recorder()
    let url = repo.url("a.txt")
    files.addObserver(recorder, interest: url)
    let version = try XCTUnwrap(files.version(of: url, at: .index))
    pumpMain(until: { files.state(of: version) == .failed }, "取れないに決まる")
    XCTAssertEqual(recorder.versionChanges, [version])
  }

  /// 同じ OID の取得が上限の回数失敗すれば諦めて取り直さず（恒久失敗で毎バッチ回さない）、index が別の OID へ
  /// 動けばまた挑む。
  func testRepeatedBlobFailuresGiveUpUntilTheOIDChanges() throws {
    let outside = TestScratch.caseDir.appendingPathComponent(
      "orbe-smudge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let tries = outside.appendingPathComponent("tries").path
    try repo.write(".gitattributes", "*.txt filter=broken\n")
    XCTAssertTrue(
      repo.git(["config", "filter.broken.smudge", "echo x >> '\(tries)'; exit 1"]).isSuccess)
    XCTAssertTrue(repo.git(["config", "filter.broken.clean", "cat"]).isSuccess)
    XCTAssertTrue(repo.git(["config", "filter.broken.required", "true"]).isSuccess)
    func count() -> Int {
      (try? String(contentsOfFile: tries, encoding: .utf8))?.filter { $0 == "x" }.count ?? 0
    }
    let files = RootFiles(root: repo.root)
    let recorder = Recorder()
    let url = repo.url("a.txt")
    files.addObserver(recorder, interest: url)
    pumpMain(until: { count() >= 1 }, "1 回目の失敗")
    for n in 2...RootFiles.blobFailureBudget {
      try repo.write("touch\(n).txt", "\(n)\n")
      pumpMain(until: { count() >= n }, timeout: 20, "\(n) 回目の失敗")
    }
    XCTAssertNil(files.baseline(for: url))

    try repo.write("after.txt", "a\n")
    pumpMain(until: { files.status?.badge(of: "after.txt") == .untracked }, timeout: 20, "その後の取り直し")
    XCTAssertEqual(count(), RootFiles.blobFailureBudget, "上限に達した OID は取り直さない")
    let version = try XCTUnwrap(files.version(of: url, at: .index))
    XCTAssertEqual(files.state(of: version), .failed)
    XCTAssertEqual(recorder.versionChanges, [version], "取れないと決まったときに 1 回知らせる")

    try repo.write("a.txt", "two\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { count() > RootFiles.blobFailureBudget }, timeout: 20, "OID が変わればまた挑む")
  }

  /// status の通知は status が返った時点で出る——baseline の取得（smudge filter で遅くなりうる）の後ろに
  /// バッジを並べない。
  func testStatusIsPublishedBeforeBaselinesAreFetched() throws {
    try repo.write(".gitattributes", "*.txt filter=slow\n")
    XCTAssertTrue(repo.git(["config", "filter.slow.smudge", "sleep 1; cat"]).isSuccess)
    let files = RootFiles(root: repo.root)
    let recorder = Recorder()
    let url = repo.url("a.txt")
    files.addObserver(recorder, interest: url)
    pumpMain(until: { files.status != nil }, "status")
    XCTAssertNil(files.baseline(for: url), "smudge が終わる前に status が届く")
    XCTAssertEqual(recorder.versionChanges, [])
    pumpMain(until: { files.baseline(for: url) == "one\n" }, timeout: 20, "その後 baseline が届く")
  }

  /// 観測者が消えれば関心も消える——次に観測者が出入りしたときに刈られ、baseline のキャッシュも捨てる。
  func testADeadObserversInterestIsPruned() throws {
    let files = RootFiles(root: repo.root)
    let url = repo.url("a.txt")
    var only: Recorder? = Recorder()
    files.addObserver(only!, interest: url)
    pumpMain(until: { files.baseline(for: url) == "one\n" })

    only = nil
    let bystander = Recorder()
    files.addObserver(bystander)
    XCTAssertNil(files.baseline(for: url), "死んだ観測者の関心は刈られる")

    var another: Recorder? = Recorder()
    files.addObserver(another!, interest: url)
    pumpMain(until: { files.baseline(for: url) == "one\n" })
    another = nil
    try repo.write("b.txt", "b\n")
    pumpMain(until: { files.baseline(for: url) == nil }, "観測者の出入りが無くても、次の取り直しで消える")
  }

  /// 競合中（stage 0 が無い）の index 版は「無い」、UTF-8 でない index 版は「読めない」で、どちらも baseline 無し。状態が
  /// 決まったときに知らせる。status には競合・A として出る。
  func testConflictedAndNonUTF8FilesHaveNoBaseline() throws {
    XCTAssertTrue(repo.git(["checkout", "-qb", "other"]).isSuccess)
    try repo.write("a.txt", "other\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "other"]).isSuccess)
    XCTAssertTrue(repo.git(["checkout", "-q", "main"]).isSuccess)
    try repo.write("a.txt", "main\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "main"]).isSuccess)
    XCTAssertFalse(repo.git(["merge", "other"]).isSuccess, "前提: 競合する")
    try Data([0xFF, 0xFE, 0x00]).write(to: repo.url("bin.dat"))
    XCTAssertTrue(repo.git(["add", "bin.dat"]).isSuccess)

    let files = RootFiles(root: repo.root)
    let recorder = Recorder()
    files.addObserver(recorder, interest: repo.url("a.txt"))
    files.addObserver(recorder, interest: repo.url("bin.dat"))
    pumpMain(until: { files.status != nil })
    XCTAssertEqual(files.status?.badge(of: "a.txt"), .conflicted)
    XCTAssertEqual(files.status?.badge(of: "bin.dat"), .added)
    let conflicted = try XCTUnwrap(files.version(of: repo.url("a.txt"), at: .index))
    let binary = try XCTUnwrap(files.version(of: repo.url("bin.dat"), at: .index))
    pumpMain(until: { files.state(of: binary) != nil && files.state(of: conflicted) != nil })
    XCTAssertEqual(files.state(of: conflicted), .absent, "競合中は index 版が定まらない")
    XCTAssertEqual(files.state(of: binary), .notText, "UTF-8 でない版は本文にしない")
    XCTAssertNil(files.baseline(for: repo.url("a.txt")))
    XCTAssertNil(files.baseline(for: repo.url("bin.dat")))
    XCTAssertEqual(Set(recorder.versionChanges), [conflicted, binary], "状態が決まったときに知らせる")
    XCTAssertEqual(recorder.versionChanges.count, 2)
  }

  /// 関心は観測者に紐づく——同じファイルを 2 つが追い、片方が消えても残った方の baseline は追従し続ける。
  func testInterestIsTheUnionOfLivingObservers() throws {
    let files = RootFiles(root: repo.root)
    let url = repo.url("a.txt")
    var first: Recorder? = Recorder()
    let second = Recorder()
    files.addObserver(first!, interest: url)
    files.addObserver(second, interest: url)
    pumpMain(until: { files.baseline(for: url) == "one\n" })
    XCTAssertEqual(second.versionChanges, [files.version(of: url, at: .index)], "両方に届く")

    first = nil
    try repo.write("a.txt", "two\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { files.baseline(for: url) == "two\n" }, "残った観測者の関心で追従する")
    XCTAssertEqual(second.versionChanges.count, 2)

    files.removeObserver(second)
    XCTAssertNil(files.baseline(for: url), "関心が無くなればキャッシュを捨てる")
  }

  /// HEAD の版も同じ 1 か所で取る——コミットで追従し、index の版とは別の関心。初回コミット前の HEAD・HEAD に無いパスは
  /// 「無い」。関心を置き換えれば、増えた版を取り直し、消えた版を捨てる。
  func testHeadVersionsFollowCommitsAndInterestsCanBeReplaced() throws {
    let files = RootFiles(root: repo.root)
    let recorder = Recorder()
    let head = RootFiles.Version(path: "a.txt", revision: .head)
    let index = RootFiles.Version(path: "a.txt", revision: .index)
    let missing = RootFiles.Version(path: "dir/new line\n.txt", revision: .head)
    files.addObserver(recorder, versions: [head, missing])
    pumpMain(until: { files.state(of: head) == .text("one\n") }, "初回取得")
    XCTAssertEqual(files.state(of: missing), .absent, "HEAD に無いパス（改行を含む名前でも）")
    XCTAssertNil(files.state(of: index), "関心の無い版は取らない")

    try repo.write("a.txt", "two\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    files.setVersions([head, index], for: recorder)
    pumpMain(until: { files.state(of: index) == .text("two\n") }, "増えた関心を取る")
    XCTAssertEqual(files.state(of: head), .text("one\n"), "ステージしても HEAD の版は変わらない")
    XCTAssertNil(files.state(of: missing), "消えた関心は捨てる")
    XCTAssertTrue(repo.git(["commit", "-qm", "two"]).isSuccess)
    pumpMain(until: { files.state(of: head) == .text("two\n") }, "コミットで追従")
  }

  /// 初回コミット前の HEAD は、どのパスも「無い」（git の失敗にしない）。
  func testAnUnbornHeadHasNoVersions() throws {
    let empty = try TempGitRepo(initialCommit: false)
    let files = RootFiles(root: empty.root)
    let recorder = Recorder()
    let head = RootFiles.Version(path: "a.txt", revision: .head)
    files.addObserver(recorder, versions: [head])
    pumpMain(until: { files.state(of: head) != nil }, "状態が決まる")
    XCTAssertEqual(files.state(of: head), .absent)
  }
}
