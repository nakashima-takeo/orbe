import XCTest

@testable import Orbe

/// 行配列を末尾改行付きのパッチ文字列へ。
private func patch(_ lines: String...) -> String {
  lines.joined(separator: "\n") + "\n"
}

/// 変更行（added/removed）のうち述語に合うものの LineRef 集合。
private func changeRefs(
  in diff: FileDiff, where include: (DiffLine) -> Bool = { _ in true }
) -> Set<LineRef> {
  var result: Set<LineRef> = []
  for (h, hunk) in diff.hunks.enumerated() {
    for (l, line) in hunk.lines.enumerated() where line.kind != .context && include(line) {
      result.insert(LineRef(h, l))
    }
  }
  return result
}

/// ユニット層: 手組みの FileDiff から build() の出力文字列を厳密検証する。
/// 実 git に通す層は GitPatchBuilderTestsRoundtrip。
final class GitPatchBuilderTests: XCTestCase {

  private func fileDiff(
    oldPath: String? = "f.txt", newPath: String? = "f.txt",
    isBinary: Bool = false, oldMode: String? = nil, newMode: String? = nil,
    hunks: [Hunk]
  ) -> FileDiff {
    FileDiff(
      oldPath: oldPath, newPath: newPath, isBinary: isBinary,
      oldMode: oldMode, newMode: newMode, similarity: nil, hunks: hunks
    )
  }

  /// diff 本文表記（"+x"・"-x"・" x"・"\ No newline..."）から Hunk を手組みする。
  /// 行番号は build() が参照しないので省略する。
  private func hunk(
    old: (Int, Int), new: (Int, Int), heading: String = "", _ body: String...
  ) -> Hunk {
    var lines: [DiffLine] = []
    for raw in body {
      if raw.hasPrefix("\\"), let last = lines.popLast() {
        lines.append(DiffLine(kind: last.kind, text: last.text, noNewlineAtEnd: true))
        continue
      }
      let kind: DiffLine.Kind =
        raw.hasPrefix("+") ? .added : raw.hasPrefix("-") ? .removed : .context
      lines.append(DiffLine(kind: kind, text: String(raw.dropFirst())))
    }
    return Hunk(
      oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1,
      sectionHeading: heading, lines: lines
    )
  }

  private func build(_ d: FileDiff, _ sel: Set<LineRef>, _ dir: PatchDirection) -> String? {
    PatchBuilder.build(diff: d, selection: sel, direction: dir)
  }

  /// 通常変更（a/f.txt → b/f.txt）ヘッダ + hunk 行を末尾改行付きパッチへ。
  private func modPatch(_ body: String...) -> String {
    (["diff --git a/f.txt b/f.txt", "--- a/f.txt", "+++ b/f.txt"] + body)
      .joined(separator: "\n") + "\n"
  }

  func testNilCases() {
    XCTAssertNil(build(fileDiff(isBinary: true, hunks: []), [LineRef(0, 0)], .stage), "バイナリ")
    let renamed = fileDiff(
      oldPath: "a.txt", newPath: "b.txt", hunks: [hunk(old: (1, 1), new: (1, 1), "-x", "+y")])
    XCTAssertNil(build(renamed, [LineRef(0, 0)], .stage), "rename")
    XCTAssertNil(build(fileDiff(hunks: []), [LineRef(0, 0)], .stage), "hunks 空")
    let normal = fileDiff(hunks: [hunk(old: (1, 1), new: (1, 2), " a", "+x")])
    XCTAssertNil(build(normal, [], .stage), "選択空")
    XCTAssertNil(build(normal, [LineRef(0, 0)], .stage), "context 行の選択は変更を含まない")
  }

  // MARK: - 正規化規則

  func testStageDropsUnselectedAdded() {
    let diff = fileDiff(hunks: [hunk(old: (1, 2), new: (1, 4), " a", "+x", "+y", " b")])
    XCTAssertEqual(
      build(diff, [LineRef(0, 1)], .stage),
      modPatch("@@ -1,2 +1,3 @@", " a", "+x", " b"))
  }

  func testStageConvertsUnselectedRemovedToContext() {
    let diff = fileDiff(hunks: [hunk(old: (1, 4), new: (1, 2), " a", "-x", "-y", " b")])
    XCTAssertEqual(
      build(diff, [LineRef(0, 1)], .stage),
      modPatch("@@ -1,4 +1,3 @@", " a", "-x", " y", " b"))
  }

  func testUnstageConvertsUnselectedAddedToContext() {
    let diff = fileDiff(hunks: [hunk(old: (1, 2), new: (1, 4), " a", "+x", "+y", " b")])
    XCTAssertEqual(
      build(diff, [LineRef(0, 1)], .unstage),
      modPatch("@@ -1,3 +1,4 @@", " a", "+x", " y", " b"))
  }

  func testUnstageDropsUnselectedRemoved() {
    let diff = fileDiff(hunks: [hunk(old: (1, 4), new: (1, 2), " a", "-x", "-y", " b")])
    XCTAssertEqual(
      build(diff, [LineRef(0, 1)], .unstage),
      modPatch("@@ -1,3 +1,2 @@", " a", "-x", " b"))
  }

  // MARK: - hunk 脱落と行番号

  /// 2 hunk 目が元 diff で +1 ずれている（hunk1 が 1 行追加する）フィクスチャ。
  private var twoHunkDiff: FileDiff {
    fileDiff(hunks: [
      hunk(old: (1, 2), new: (1, 3), " a", "+X", " b"),
      hunk(old: (10, 2), new: (11, 3), " j", "+Z", " k"),
    ])
  }

  func testUnselectedHunkOmittedAndCounterpartStartDerived() {
    // hunk1 は非選択 → 出力されない。stage は hunk2 の oldStart 10 を保持し、
    // newStart = 10 + デルタ 0（index は hunk1 をまだ受けていない）。
    XCTAssertEqual(
      build(twoHunkDiff, [LineRef(1, 1)], .stage),
      modPatch("@@ -10,2 +10,3 @@", " j", "+Z", " k"))
    // unstage は newStart 11 を保持し、oldStart = 11 - デルタ 0。
    XCTAssertEqual(
      build(twoHunkDiff, [LineRef(1, 1)], .unstage),
      modPatch("@@ -11,2 +11,3 @@", " j", "+Z", " k"))
  }

  func testStageDeltaAccumulatesAcrossEmittedHunks() {
    XCTAssertEqual(
      build(twoHunkDiff, changeRefs(in: twoHunkDiff), .stage),
      modPatch(
        "@@ -1,2 +1,3 @@", " a", "+X", " b",
        "@@ -10,2 +11,3 @@", " j", "+Z", " k"))
  }

  // MARK: - 新規・削除ファイルのヘッダ

  func testNewFileStageAndUnstage() {
    let custom = fileDiff(
      oldPath: nil, newPath: "new.txt", newMode: "100755",
      hunks: [hunk(old: (0, 0), new: (1, 2), "+a", "+b")])
    // 全選択 stage → new file ヘッダ + 指定 mode
    XCTAssertEqual(
      build(custom, changeRefs(in: custom), .stage),
      patch(
        "diff --git a/new.txt b/new.txt", "new file mode 100755",
        "--- /dev/null", "+++ b/new.txt",
        "@@ -0,0 +1,2 @@", "+a", "+b"))
    let plain = fileDiff(
      oldPath: nil, newPath: "new.txt", hunks: [hunk(old: (0, 0), new: (1, 2), "+a", "+b")])
    // 部分 stage → 非選択 added は落ちるので /dev/null のまま。mode 未指定は 100644
    XCTAssertEqual(
      build(plain, [LineRef(0, 0)], .stage),
      patch(
        "diff --git a/new.txt b/new.txt", "new file mode 100644",
        "--- /dev/null", "+++ b/new.txt",
        "@@ -0,0 +1,1 @@", "+a"))
    // 部分 unstage → 非選択 added が context として旧側に残るため通常変更になる
    XCTAssertEqual(
      build(plain, [LineRef(0, 0)], .unstage),
      patch(
        "diff --git a/new.txt b/new.txt", "--- a/new.txt", "+++ b/new.txt",
        "@@ -1,1 +1,2 @@", "+a", " b"))
  }

  func testDeletedFileStage() {
    let diff = fileDiff(
      oldPath: "gone.txt", newPath: nil, oldMode: "100644",
      hunks: [hunk(old: (1, 2), new: (0, 0), "-a", "-b")])
    // 全選択 → 削除ファイルヘッダ
    XCTAssertEqual(
      build(diff, changeRefs(in: diff), .stage),
      patch(
        "diff --git a/gone.txt b/gone.txt", "deleted file mode 100644",
        "--- a/gone.txt", "+++ /dev/null",
        "@@ -1,2 +0,0 @@", "-a", "-b"))
    // 部分選択 → 非選択 removed が context として新側に残るため通常変更になる
    XCTAssertEqual(
      build(diff, [LineRef(0, 0)], .stage),
      patch(
        "diff --git a/gone.txt b/gone.txt", "--- a/gone.txt", "+++ b/gone.txt",
        "@@ -1,2 +1,1 @@", "-a", " b"))
  }

  // MARK: - noNewline と見出し

  func testNoNewlineMarkerReemitted() {
    let diff = fileDiff(hunks: [
      hunk(
        old: (1, 2), new: (1, 2),
        " a", "-b", "\\ No newline at end of file", "+B", "\\ No newline at end of file")
    ])
    XCTAssertEqual(
      build(diff, changeRefs(in: diff), .stage),
      modPatch(
        "@@ -1,2 +1,2 @@", " a",
        "-b", "\\ No newline at end of file",
        "+B", "\\ No newline at end of file"))
  }

  func testSectionHeadingReemitted() {
    let diff = fileDiff(hunks: [
      hunk(old: (1, 1), new: (1, 1), heading: "func foo() {", "-x", "+y")
    ])
    XCTAssertEqual(
      build(diff, changeRefs(in: diff), .stage),
      modPatch("@@ -1,1 +1,1 @@ func foo() {", "-x", "+y"))
  }
}

/// ラウンドトリップ層: 一時リポジトリで実 git に diff 生成と apply をさせ、
/// index の中身が期待通りかを文字列比較で検証する。
final class GitPatchBuilderTestsRoundtrip: XCTestCase {

  private var repo: URL!

  override func setUpWithError() throws {
    repo = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-patch-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try git(["init", "-q", "-b", "main"])
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: repo)
  }

  // MARK: - git ヘルパ

  private struct GitError: Error, CustomStringConvertible { let description: String }

  @discardableResult
  private func git(_ args: [String], stdin: String? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = repo
    let stdout = Pipe()
    let stderr = Pipe()
    let input = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = input
    try process.run()
    if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
    input.fileHandleForWriting.closeFile()
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    let err = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let message = String(data: err, encoding: .utf8) ?? ""
      throw GitError(description: "git \(args.joined(separator: " ")): \(message)")
    }
    return String(data: out, encoding: .utf8) ?? ""
  }

  private func write(_ name: String, _ content: String) throws {
    try content.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  /// ファイルを書いて add + commit する。
  private func commitFile(_ name: String, _ content: String) throws {
    try write(name, content)
    try git(["add", name])
    try git([
      "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
      "commit", "-qm", "c",
    ])
  }

  private func diff(cached: Bool = false) throws -> [FileDiff] {
    var args = [
      "-c", "core.quotepath=false", "diff", "--no-color", "--no-ext-diff", "--find-renames", "-U3",
    ]
    if cached { args.append("--cached") }
    return DiffParser.parse(try git(args))
  }

  private func applyCached(_ patch: String, reverse: Bool = false) throws {
    var args = ["apply", "--cached", "--whitespace=nowarn"]
    if reverse { args.append("--reverse") }
    args.append("-")
    try git(args, stdin: patch)
  }

  private func indexContent(_ path: String) throws -> String {
    try git(["show", ":\(path)"])
  }

  private func stage(_ diff: FileDiff, _ selection: Set<LineRef>) throws {
    let built = try XCTUnwrap(
      PatchBuilder.build(diff: diff, selection: selection, direction: .stage))
    try applyCached(built)
  }

  private func unstage(_ diff: FileDiff, _ selection: Set<LineRef>) throws {
    let built = try XCTUnwrap(
      PatchBuilder.build(diff: diff, selection: selection, direction: .unstage))
    try applyCached(built, reverse: true)
  }

  // MARK: - テスト

  func testStagePartialAddedThenUnstageAll() throws {
    try commitFile("f.txt", "a\nb\nc\n")
    try write("f.txt", "a\nx\nb\ny\nc\n")

    let d = try diff()[0]
    XCTAssertNil(PatchBuilder.build(diff: d, selection: [], direction: .stage), "選択空は nil")
    try stage(d, changeRefs(in: d) { $0.text == "x" })
    XCTAssertEqual(try indexContent("f.txt"), "a\nx\nb\nc\n")

    // staged diff の全選択 unstage で元へ戻る
    let staged = try diff(cached: true)[0]
    try unstage(staged, changeRefs(in: staged))
    XCTAssertEqual(try indexContent("f.txt"), "a\nb\nc\n")
  }

  func testStagePartialRemoved() throws {
    try commitFile("f.txt", "a\nb\nc\nd\n")
    try write("f.txt", "a\nd\n")

    let d = try diff()[0]
    try stage(d, changeRefs(in: d) { $0.text == "b" })
    XCTAssertEqual(try indexContent("f.txt"), "a\nc\nd\n")
  }

  func testStageMixed() throws {
    try commitFile("f.txt", "one\ntwo\nthree\nfour\n")
    try write("f.txt", "one\nTWO\nthree\nfive\nfour\n")

    // 置換ペア（-two/+TWO）だけ stage し、+five は worktree に残す
    let d = try diff()[0]
    try stage(d, changeRefs(in: d) { $0.text == "two" || $0.text == "TWO" })
    XCTAssertEqual(try indexContent("f.txt"), "one\nTWO\nthree\nfour\n")
  }

  func testStageSecondHunkOnly() throws {
    let base = (1...30).map { "l\($0)" }.joined(separator: "\n") + "\n"
    try commitFile("f.txt", base)
    try write(
      "f.txt",
      base
        .replacingOccurrences(of: "l2\n", with: "L2\n")
        .replacingOccurrences(of: "l28\n", with: "L28\n"))

    let d = try diff()[0]
    XCTAssertEqual(d.hunks.count, 2, "-U3 で 2 hunk に分かれる前提")
    try stage(d, changeRefs(in: d).filter { $0.hunk == 1 })
    XCTAssertEqual(try indexContent("f.txt"), base.replacingOccurrences(of: "l28\n", with: "L28\n"))
  }

  func testStageNoTrailingNewline() throws {
    try commitFile("f.txt", "a\nb")
    try write("f.txt", "a\nc")

    let d = try diff()[0]
    try stage(d, changeRefs(in: d))
    XCTAssertEqual(try indexContent("f.txt"), "a\nc")
  }

  func testStageNewFilePartial() throws {
    try commitFile("base.txt", "base\n")
    try write("new.txt", "1\n2\n3\n")
    try git(["add", "-N", "new.txt"])

    let d = try XCTUnwrap(try diff().first { $0.newPath == "new.txt" })
    XCTAssertNil(d.oldPath, "add -N 後の diff は新規ファイル")
    try stage(d, changeRefs(in: d) { $0.text != "2" })
    XCTAssertEqual(try indexContent("new.txt"), "1\n3\n")
  }

  func testStageAllThenUnstageAll() throws {
    try commitFile("f.txt", "a\nb\nc\n")
    try write("f.txt", "A\nb\nx\nc\n")

    let d = try diff()[0]
    try stage(d, changeRefs(in: d))
    XCTAssertEqual(try indexContent("f.txt"), "A\nb\nx\nc\n", "全選択 = 全 stage")

    let staged = try diff(cached: true)[0]
    try unstage(staged, changeRefs(in: staged))
    XCTAssertEqual(try indexContent("f.txt"), "a\nb\nc\n")
  }

  func testUnstagePartial() throws {
    try commitFile("f.txt", "a\nb\n")
    try write("f.txt", "a\nx\ny\nb\n")
    try git(["add", "f.txt"])  // 全部 stage してから一部だけ unstage する

    let staged = try diff(cached: true)[0]
    try unstage(staged, changeRefs(in: staged) { $0.text == "x" })
    XCTAssertEqual(try indexContent("f.txt"), "a\ny\nb\n")
  }
}
