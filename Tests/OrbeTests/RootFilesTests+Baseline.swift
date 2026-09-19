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
    XCTAssertEqual(recorder.baselineChanges, [url])

    try repo.write("a.txt", "two\n")
    pumpMain(until: { files.status?.badge(of: "a.txt") == .modified })
    XCTAssertEqual(files.baseline(for: url), "one\n", "作業ツリーの編集では index 版は変わらない")
    XCTAssertEqual(recorder.baselineChanges.count, 1, "OID が同じなら取り直さない")

    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { files.baseline(for: url) == "two\n" }, "git add で追従")
    XCTAssertTrue(repo.git(["rm", "--cached", "-q", "a.txt"]).isSuccess)
    pumpMain(until: { files.baseline(for: url) == nil }, "index から消えれば nil")
    XCTAssertEqual(recorder.baselineChanges.count, 3)

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
    XCTAssertNil(files.baseline(for: url))
    XCTAssertEqual(recorder.baselineChanges, [])

    try Data().write(to: URL(fileURLWithPath: allow))
    try repo.write("b.txt", "b\n")
    pumpMain(until: { files.baseline(for: url) == "one\n" }, timeout: 20, "次の取り直しで取り直す")
    XCTAssertEqual(recorder.baselineChanges, [url])
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
    XCTAssertEqual(recorder.baselineChanges, [])
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

  /// 競合中（stage 0 が無い）と UTF-8 でない index 版は baseline 無し。status には競合・A として出る。
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
    XCTAssertNil(files.baseline(for: repo.url("a.txt")), "競合中は index 版が定まらない")
    XCTAssertNil(files.baseline(for: repo.url("bin.dat")), "UTF-8 でない版は使わない")
    XCTAssertEqual(recorder.baselineChanges, [], "無いものの初回取得は通知しない")
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
    XCTAssertEqual(second.baselineChanges, [url], "両方に届く")

    first = nil
    try repo.write("a.txt", "two\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { files.baseline(for: url) == "two\n" }, "残った観測者の関心で追従する")
    XCTAssertEqual(second.baselineChanges.count, 2)

    files.removeObserver(second)
    XCTAssertNil(files.baseline(for: url), "関心が無くなればキャッシュを捨てる")
  }

}
