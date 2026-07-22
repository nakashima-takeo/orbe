import XCTest

@testable import Orbe

/// 行配列を末尾改行付きの diff テキストへ。
private func fixture(_ lines: String...) -> String {
  lines.joined(separator: "\n") + "\n"
}

/// hunk 機構の検証: 行種・行番号・noNewline・見出し・複数ファイル。
/// ファイルヘッダ系（rename・mode・バイナリ等）は GitDiffParserTestsFileHeaders。
final class GitDiffParserTests: XCTestCase {

  func testEmptyInput() {
    XCTAssertEqual(DiffParser.parse(""), [])
    XCTAssertEqual(DiffParser.parse("\n"), [])
  }

  func testSimpleModification() {
    let diffs = DiffParser.parse(
      fixture(
        "diff --git a/f.txt b/f.txt",
        "index de98044..7be73ce 100644",
        "--- a/f.txt", "+++ b/f.txt",
        "@@ -1,3 +1,3 @@",
        " a", "-b", "+B", " c"
      ))
    XCTAssertEqual(diffs.count, 1)
    let d = diffs[0]
    XCTAssertEqual(d.oldPath, "f.txt")
    XCTAssertEqual(d.newPath, "f.txt")
    XCTAssertFalse(d.isBinary)
    XCTAssertEqual(d.oldMode, "100644")  // index 行から
    XCTAssertEqual(d.newMode, "100644")
    XCTAssertNil(d.similarity)
    let h = d.hunks[0]
    XCTAssertEqual(h.oldStart, 1)
    XCTAssertEqual(h.oldCount, 3)
    XCTAssertEqual(h.newStart, 1)
    XCTAssertEqual(h.newCount, 3)
    XCTAssertEqual(h.sectionHeading, "")
    XCTAssertEqual(
      h.lines,
      [
        DiffLine(kind: .context, text: "a", oldLine: 1, newLine: 1),
        DiffLine(kind: .removed, text: "b", oldLine: 2),
        DiffLine(kind: .added, text: "B", newLine: 2),
        DiffLine(kind: .context, text: "c", oldLine: 3, newLine: 3),
      ])
  }

  func testMultiHunkLineNumbers() {
    let diffs = DiffParser.parse(
      fixture(
        "diff --git a/f.txt b/f.txt",
        "index 1111111..2222222 100644",
        "--- a/f.txt", "+++ b/f.txt",
        "@@ -1,3 +1,4 @@",
        " a", "+X", " b", " c",
        "@@ -10,3 +11,3 @@ section two",
        " j", "-k", "+K", " l"
      ))
    XCTAssertEqual(diffs[0].hunks.count, 2)
    let second = diffs[0].hunks[1]
    XCTAssertEqual(second.sectionHeading, "section two")
    XCTAssertEqual(
      second.lines,
      [
        DiffLine(kind: .context, text: "j", oldLine: 10, newLine: 11),
        DiffLine(kind: .removed, text: "k", oldLine: 11),
        DiffLine(kind: .added, text: "K", newLine: 12),
        DiffLine(kind: .context, text: "l", oldLine: 12, newLine: 13),
      ])
  }

  func testHunkCountOmittedDefaultsToOne() {
    let diffs = DiffParser.parse(
      fixture(
        "diff --git a/f.txt b/f.txt",
        "index 1111111..2222222 100644",
        "--- a/f.txt", "+++ b/f.txt",
        "@@ -3 +3 @@",
        "-x", "+y"
      ))
    let h = diffs[0].hunks[0]
    XCTAssertEqual(h.oldStart, 3)
    XCTAssertEqual(h.oldCount, 1)
    XCTAssertEqual(h.newStart, 3)
    XCTAssertEqual(h.newCount, 1)
    XCTAssertEqual(h.lines.count, 2)
  }

  func testNoNewlineFoldsIntoPreviousLine() {
    let diffs = DiffParser.parse(
      fixture(
        "diff --git a/f.txt b/f.txt",
        "index 1111111..2222222 100644",
        "--- a/f.txt", "+++ b/f.txt",
        "@@ -1,2 +1,2 @@",
        " a",
        "-b", "\\ No newline at end of file",
        "+B", "\\ No newline at end of file"
      ))
    let lines = diffs[0].hunks[0].lines
    XCTAssertEqual(lines.count, 3)
    XCTAssertFalse(lines[0].noNewlineAtEnd)
    XCTAssertTrue(lines[1].noNewlineAtEnd)  // -b（hunk 途中のマーカー）
    XCTAssertTrue(lines[2].noNewlineAtEnd)  // +B（hunk 末尾のマーカー）
  }

  func testSectionHeading() {
    let diffs = DiffParser.parse(
      fixture(
        "diff --git a/f.swift b/f.swift",
        "index 1111111..2222222 100644",
        "--- a/f.swift", "+++ b/f.swift",
        "@@ -10,2 +10,2 @@ func foo() {",
        " a", "-b", "+B"
      ))
    XCTAssertEqual(diffs[0].hunks[0].sectionHeading, "func foo() {")
  }

  func testMultipleFiles() {
    let diffs = DiffParser.parse(
      fixture(
        "diff --git a/f.txt b/f.txt",
        "index 1111111..2222222 100644",
        "--- a/f.txt", "+++ b/f.txt",
        "@@ -1 +1 @@",
        "-x", "+y",
        "diff --git a/mode.sh b/mode.sh",
        "old mode 100644",
        "new mode 100755",
        "diff --git a/new.txt b/new.txt",
        "new file mode 100644",
        "index 0000000..07f33c4",
        "--- /dev/null", "+++ b/new.txt",
        "@@ -0,0 +1 @@",
        "+hello"
      ))
    XCTAssertEqual(diffs.count, 3)
    XCTAssertEqual(diffs[0].newPath, "f.txt")
    XCTAssertEqual(diffs[1].newPath, "mode.sh")
    XCTAssertEqual(diffs[2].newPath, "new.txt")
    XCTAssertNil(diffs[2].oldPath)
  }
}

/// ファイルヘッダ系の検証: 新規・削除・rename・copy・mode 変更・バイナリ・パス復元。
final class GitDiffParserTestsFileHeaders: XCTestCase {

  func testNewFile() {
    let diffs = DiffParser.parse(
      fixture(
        "diff --git a/new.txt b/new.txt",
        "new file mode 100644",
        "index 0000000..07f33c4",
        "--- /dev/null", "+++ b/new.txt",
        "@@ -0,0 +1,2 @@",
        "+new", "+file"
      ))
    let d = diffs[0]
    XCTAssertNil(d.oldPath)
    XCTAssertEqual(d.newPath, "new.txt")
    XCTAssertTrue(d.isNew)
    XCTAssertNil(d.oldMode)
    XCTAssertEqual(d.newMode, "100644")
    XCTAssertEqual(
      d.hunks[0].lines,
      [
        DiffLine(kind: .added, text: "new", newLine: 1),
        DiffLine(kind: .added, text: "file", newLine: 2),
      ])
  }

  func testDeletedFile() {
    let diffs = DiffParser.parse(
      fixture(
        "diff --git a/gone.txt b/gone.txt",
        "deleted file mode 100755",
        "index 07f33c4..0000000",
        "--- a/gone.txt", "+++ /dev/null",
        "@@ -1,2 +0,0 @@",
        "-new", "-file"
      ))
    let d = diffs[0]
    XCTAssertEqual(d.oldPath, "gone.txt")
    XCTAssertNil(d.newPath)
    XCTAssertTrue(d.isDeleted)
    XCTAssertEqual(d.oldMode, "100755")
    XCTAssertNil(d.newMode)
    XCTAssertEqual(
      d.hunks[0].lines,
      [
        DiffLine(kind: .removed, text: "new", oldLine: 1),
        DiffLine(kind: .removed, text: "file", oldLine: 2),
      ])
  }

  func testPureRenameWithSpacesInPath() {
    let diffs = DiffParser.parse(
      fixture(
        "diff --git a/old name.txt b/new name.txt",
        "similarity index 100%",
        "rename from old name.txt",
        "rename to new name.txt"
      ))
    let d = diffs[0]
    XCTAssertEqual(d.oldPath, "old name.txt")
    XCTAssertEqual(d.newPath, "new name.txt")
    XCTAssertTrue(d.isRenamed)
    XCTAssertEqual(d.similarity, 100)
    XCTAssertEqual(d.hunks, [])
  }

  func testRenameWithEdits() {
    let diffs = DiffParser.parse(
      fixture(
        "diff --git a/a.txt b/b.txt",
        "similarity index 95%",
        "rename from a.txt",
        "rename to b.txt",
        "index 1111111..2222222 100644",
        "--- a/a.txt", "+++ b/b.txt",
        "@@ -1,2 +1,2 @@",
        " x", "-y", "+z"
      ))
    let d = diffs[0]
    XCTAssertEqual(d.oldPath, "a.txt")
    XCTAssertEqual(d.newPath, "b.txt")
    XCTAssertEqual(d.similarity, 95)
    XCTAssertEqual(d.hunks.count, 1)
  }

  func testCopy() {
    let diffs = DiffParser.parse(
      fixture(
        "diff --git a/a.txt b/c.txt",
        "similarity index 90%",
        "copy from a.txt",
        "copy to c.txt",
        "index 1111111..2222222 100644",
        "--- a/a.txt", "+++ b/c.txt",
        "@@ -1 +1 @@",
        "-y", "+z"
      ))
    let d = diffs[0]
    XCTAssertEqual(d.oldPath, "a.txt")
    XCTAssertEqual(d.newPath, "c.txt")
    XCTAssertEqual(d.similarity, 90)
  }

  func testModeChangeOnlyResolvesPathFromGitLine() {
    let diffs = DiffParser.parse(
      fixture(
        "diff --git a/run me.sh b/run me.sh",
        "old mode 100644",
        "new mode 100755"
      ))
    let d = diffs[0]
    XCTAssertEqual(d.oldPath, "run me.sh")  // 中点分割で復元
    XCTAssertEqual(d.newPath, "run me.sh")
    XCTAssertEqual(d.oldMode, "100644")
    XCTAssertEqual(d.newMode, "100755")
    XCTAssertEqual(d.hunks, [])
  }

  func testBinaryFile() {
    let diffs = DiffParser.parse(
      fixture(
        "diff --git a/bin.dat b/bin.dat",
        "index c5e82d7..8352675 100644",
        "Binary files a/bin.dat and b/bin.dat differ"
      ))
    let d = diffs[0]
    XCTAssertTrue(d.isBinary)
    XCTAssertEqual(d.oldPath, "bin.dat")
    XCTAssertEqual(d.newPath, "bin.dat")
    XCTAssertEqual(d.hunks, [])
  }

  func testBinaryNewFile() {
    let diffs = DiffParser.parse(
      fixture(
        "diff --git a/img.png b/img.png",
        "new file mode 100644",
        "index 0000000..1111111",
        "Binary files /dev/null and b/img.png differ"
      ))
    let d = diffs[0]
    XCTAssertTrue(d.isBinary)
    XCTAssertNil(d.oldPath)  // new file mode から /dev/null 側を確定
    XCTAssertEqual(d.newPath, "img.png")
  }

  func testGitBinaryPatchSkipsBlobUntilNextFile() {
    let diffs = DiffParser.parse(
      fixture(
        "diff --git a/bin.dat b/bin.dat",
        "index c5e82d7..8352675 100644",
        "GIT binary patch",
        "literal 3",
        "Kc$~|za~}b",
        "",
        "diff --git a/f.txt b/f.txt",
        "index 1111111..2222222 100644",
        "--- a/f.txt", "+++ b/f.txt",
        "@@ -1 +1 @@",
        "-x", "+y"
      ))
    XCTAssertEqual(diffs.count, 2)
    XCTAssertTrue(diffs[0].isBinary)
    XCTAssertEqual(diffs[0].hunks, [])
    XCTAssertFalse(diffs[1].isBinary)
    XCTAssertEqual(diffs[1].hunks.count, 1)
  }

  func testUTF8PathWithSpacesStripsTrailingTab() {
    let diffs = DiffParser.parse(
      fixture(
        "diff --git a/日本語 ファイル.txt b/日本語 ファイル.txt",
        "index b77b4eb..7061c57 100644",
        "--- a/日本語 ファイル.txt\t", "+++ b/日本語 ファイル.txt\t",
        "@@ -1,2 +1,2 @@",
        " x", "-y", "+Y"
      ))
    let d = diffs[0]
    XCTAssertEqual(d.oldPath, "日本語 ファイル.txt")
    XCTAssertEqual(d.newPath, "日本語 ファイル.txt")
  }
}
