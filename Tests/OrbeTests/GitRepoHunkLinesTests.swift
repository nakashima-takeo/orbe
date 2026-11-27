import OrbeTestSupport
import XCTest

@testable import Orbe

/// 2 つのコミットの間の、1 つのファイルの diff の区間が覆う行（`GitRepo.hunkLines`）。実 git の一時リポジトリで測る。
///
/// 壊れると何が起きるか: GitHub がコメントを受ける行と、Orbe が受けると考える行が食い違う——変更から 4 行目以降にも印が出て
/// 書き込みが GitHub に断られる、前後 3 行の文脈に印が出ない。GitHub から見えない手元の値（git の設定・属性・環境変数）で
/// 答えが変わる。
@MainActor
final class GitRepoHunkLinesTests: OrbeTestCase {
  private var temp: TempGitRepo!
  private var repo: GitRepo!

  override func setUpWithError() throws {
    temp = try TempGitRepo()
    var opened: GitRepo?
    GitRepo.open(cwd: temp.root) { opened = $0 }
    pumpMain(until: { opened != nil }, "開く")
    repo = try XCTUnwrap(opened)
  }

  private func commit(_ files: [String: String?]) throws -> String {
    for (path, text) in files {
      if let text {
        try temp.write(path, text)
      } else {
        XCTAssertTrue(temp.git(["rm", "-q", path]).isSuccess)
      }
    }
    XCTAssertTrue(temp.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(temp.git(["commit", "-qm", "c"]).isSuccess)
    return temp.head()
  }

  private func hunkLines(
    _ base: String, _ head: String, _ path: String, from original: String? = nil
  ) -> GitDiffHunkLines? {
    var result: GitDiffHunkLines??
    repo.hunkLines(from: base, to: head, path: path, originalPath: original) { result = .some($0) }
    pumpMain(until: { result != nil }, "区間が読める")
    return result ?? nil
  }

  private static func lines(_ range: ClosedRange<Int>, replacing changed: [Int: String] = [:])
    -> String
  {
    range.map { changed[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
  }

  /// 変更の前後 3 行までが区間に入り、それより外は入らない。離れた 2 か所の変更は別の区間になる。
  func testTheHunksCoverThreeLinesAroundEachChange() throws {
    let base = try commit(["a.txt": Self.lines(1...40)])
    let head = try commit(["a.txt": Self.lines(1...40, replacing: [10: "changed", 30: "changed"])])

    XCTAssertEqual(
      hunkLines(base, head, "a.txt"),
      GitDiffHunkLines(hunks: [.init(old: 7..<14, new: 7..<14), .init(old: 27..<34, new: 27..<34)]))
  }

  /// 追加だけのファイルは新しい側の全行、削除だけのファイルは古い側の全行。行の追加は、新しい側だけ行が増える。
  func testAddedAndDeletedFilesCoverOneSide() throws {
    let base = try commit(["gone.txt": Self.lines(1...5), "grow.txt": Self.lines(1...10)])
    let head = try commit([
      "gone.txt": nil, "new.txt": Self.lines(1...4),
      "grow.txt": Self.lines(1...10, replacing: [5: "line 5\ninserted"]),
    ])

    XCTAssertEqual(
      hunkLines(base, head, "new.txt"), GitDiffHunkLines(hunks: [.init(old: 0..<0, new: 1..<5)]))
    XCTAssertEqual(
      hunkLines(base, head, "gone.txt"), GitDiffHunkLines(hunks: [.init(old: 1..<6, new: 0..<0)]))
    XCTAssertEqual(
      hunkLines(base, head, "grow.txt"), GitDiffHunkLines(hunks: [.init(old: 3..<9, new: 3..<10)]))
  }

  /// rename は元のパスの版と比べる。末尾に改行の無い行の変更も、行の数え方は変わらない。
  func testARenameComparesWithTheOriginalAndAMissingFinalNewlineCounts() throws {
    let base = try commit(["old.txt": Self.lines(1...20)])
    let renamed = Self.lines(1...20, replacing: [20: "line 20\ntail"]).dropLast()
    XCTAssertTrue(temp.git(["mv", "old.txt", "new.txt"]).isSuccess)
    let head = try commit(["new.txt": String(renamed)])

    XCTAssertEqual(
      hunkLines(base, head, "new.txt", from: "old.txt"),
      GitDiffHunkLines(hunks: [.init(old: 18..<21, new: 18..<22)]))
  }

  private struct ShapedChanges {
    let base: String
    let head: String
    /// パスごとの、GitHub と同じ形の答え。
    let answers: [String: GitDiffHunkLines]
  }

  /// 文脈の行数・区間をつなげる行数・インデントヒューリスティック・アルゴリズムのどれかが違えば区間が変わる 3 つのファイルを
  /// コミットし、GitHub と同じ形（前後 3 行・つなげない・myers とインデントヒューリスティック）の答えと一緒に返す。
  private func changesThatDependOnTheDiffShape() throws -> ShapedChanges {
    let before = (1...5).map { "head \($0)" }
    let after = (1...5).map { "tail \($0)" }
    func text(_ middle: [String]) -> String {
      (before + middle + after).joined(separator: "\n") + "\n"
    }
    // slide.txt はインデントヒューリスティックで、anchor.txt は patience で、足した行の置き場所が変わる中身。
    let base = try commit([
      "a.txt": Self.lines(1...40), "slide.txt": text(["  x()", "", "f() {"]),
      "anchor.txt": text(["f() {", "", ""]),
    ])
    let head = try commit([
      "a.txt": Self.lines(1...40, replacing: [10: "changed", 20: "changed"]),
      "slide.txt": text(["  x()", "", "f() {", "f() {"]),
      "anchor.txt": text(["", "f() {", "f() {", "", "", ""]),
    ])
    return ShapedChanges(
      base: base, head: head,
      answers: [
        "a.txt": GitDiffHunkLines(hunks: [
          .init(old: 7..<14, new: 7..<14), .init(old: 17..<24, new: 17..<24),
        ]),
        "slide.txt": GitDiffHunkLines(hunks: [.init(old: 5..<11, new: 5..<12)]),
        "anchor.txt": GitDiffHunkLines(hunks: [.init(old: 3..<12, new: 3..<15)]),
      ]
    )
  }

  private func answers(_ base: String, _ head: String) -> [String: GitDiffHunkLines] {
    var answers: [String: GitDiffHunkLines] = [:]
    for path in ["a.txt", "slide.txt", "anchor.txt"] { answers[path] = hunkLines(base, head, path) }
    return answers
  }

  /// 利用者の git 設定（アルゴリズム・文脈の行数・区間をつなげる行数・外部 diff・インデントヒューリスティック）が違っても、
  /// GitHub と同じ形の答え。
  func testTheUsersDiffSettingsDoNotChangeTheAnswer() throws {
    let changes = try changesThatDependOnTheDiffShape()
    for setting in [
      ["diff.algorithm", "patience"], ["diff.context", "10"], ["diff.interHunkContext", "10"],
      ["diff.external", "/usr/bin/false"], ["diff.indentHeuristic", "false"],
    ] {
      XCTAssertTrue(temp.git(["config"] + setting).isSuccess)
    }

    XCTAssertEqual(answers(changes.base, changes.head), changes.answers)
  }

  /// 手元の属性（作業ツリーの `.gitattributes`・`info/attributes`・`core.attributesFile`）で、diff を無効にされたファイル・バイナリの
  /// ファイル・別のアルゴリズムのファイルにされても、GitHub と同じ形の答え。
  func testLocalAttributesDoNotChangeTheAnswer() throws {
    let changes = try changesThatDependOnTheDiffShape()
    try temp.write(".gitattributes", "anchor.txt diff=patient\n")
    XCTAssertTrue(temp.git(["config", "diff.patient.algorithm", "patience"]).isSuccess)
    try temp.write(".git/info/attributes", "a.txt -diff\n")
    try temp.write(".git/orbe-attributes", "slide.txt diff=raw\n")
    XCTAssertTrue(
      temp.git(["config", "core.attributesFile", temp.root + "/.git/orbe-attributes"]).isSuccess)
    XCTAssertTrue(temp.git(["config", "diff.raw.binary", "true"]).isSuccess)

    XCTAssertEqual(answers(changes.base, changes.head), changes.answers)
  }

  /// Orbe の環境に `GIT_DIFF_OPTS`（文脈の行数を変える）があっても、GitHub と同じ形の答え。
  func testGitDiffOptionsInTheEnvironmentDoNotChangeTheAnswer() throws {
    let changes = try changesThatDependOnTheDiffShape()
    setenv("GIT_DIFF_OPTS", "--unified=0", 1)
    defer { unsetenv("GIT_DIFF_OPTS") }

    XCTAssertEqual(hunkLines(changes.base, changes.head, "a.txt"), changes.answers["a.txt"])
  }

  /// pathspec の記号を含むパスも、そのファイルだけを読む。
  func testPathsAreNotPathspecs() throws {
    let base = try commit(["*.txt": Self.lines(1...3), "b.txt": Self.lines(1...3)])
    let head = try commit([
      "*.txt": Self.lines(1...3, replacing: [1: "x"]),
      "b.txt": Self.lines(1...3, replacing: [3: "y"]),
    ])

    XCTAssertEqual(
      hunkLines(base, head, "*.txt"), GitDiffHunkLines(hunks: [.init(old: 1..<4, new: 1..<4)]))
  }

  /// 手元に無いコミットは読めない。
  func testAMissingCommitIsUnreadable() throws {
    XCTAssertNil(hunkLines(temp.head(), String(repeating: "0", count: 40), "a.txt"))
  }
}
