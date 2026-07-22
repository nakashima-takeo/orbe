import XCTest

@testable import Orbe

/// StatusParser（porcelain v2 --branch -z）のフィクスチャテスト。NUL 区切りを \u{00} で再現する。
final class GitStatusParserTests: XCTestCase {
  private let headOid = "3a5572b8f0e5b1c2d3e4f5a6b7c8d9e0f1a2b3c4"
  private let blob = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
  private let zero = "0000000000000000000000000000000000000000"

  private func parse(_ fixture: String) -> RepoStatus {
    StatusParser.parse(Data(fixture.utf8))
  }

  func testTypicalStatus() {
    let status = parse(
      "# branch.oid \(headOid)\u{00}"
        + "# branch.head main\u{00}"
        + "# branch.upstream origin/main\u{00}"
        + "# branch.ab +1 -0\u{00}"
        + "1 .M N... 100644 100644 100644 \(blob) \(blob) Sources/App.swift\u{00}"
        + "1 A. N... 000000 100644 100644 \(zero) \(blob) docs/読み方 メモ.md\u{00}")
    XCTAssertEqual(status.branch, "main")
    XCTAssertEqual(status.oid, headOid)
    XCTAssertEqual(status.upstream, "origin/main")
    XCTAssertEqual(status.ahead, 1)
    XCTAssertEqual(status.behind, 0)
    XCTAssertEqual(
      status.files,
      [
        FileChange(path: "Sources/App.swift", oldPath: nil, staged: nil, unstaged: .modified),
        FileChange(path: "docs/読み方 メモ.md", oldPath: nil, staged: .added, unstaged: nil),
      ])
  }

  func testRenameTakesOrigPathFromNextNulField() {
    let status = parse(
      "2 R. N... 100644 100644 100644 \(blob) \(blob) R100 new name.txt\u{00}old name.txt\u{00}"
        + "1 .D N... 100644 100644 000000 \(blob) \(blob) gone.txt\u{00}")
    XCTAssertEqual(
      status.files,
      [
        FileChange(path: "new name.txt", oldPath: "old name.txt", staged: .renamed, unstaged: nil),
        FileChange(path: "gone.txt", oldPath: nil, staged: nil, unstaged: .deleted),
      ])
  }

  func testCopyEntry() {
    let status = parse(
      "2 C. N... 100644 100644 100644 \(blob) \(blob) C075 copy.txt\u{00}orig.txt\u{00}")
    XCTAssertEqual(
      status.files,
      [FileChange(path: "copy.txt", oldPath: "orig.txt", staged: .copied, unstaged: nil)])
  }

  func testDetachedHead() {
    let status = parse("# branch.oid \(headOid)\u{00}# branch.head (detached)\u{00}")
    XCTAssertNil(status.branch)
    XCTAssertEqual(status.oid, headOid)
  }

  func testInitialCommit() {
    let status = parse("# branch.oid (initial)\u{00}# branch.head main\u{00}")
    XCTAssertEqual(status.branch, "main")
    XCTAssertNil(status.oid)
  }

  func testNoUpstreamLeavesAheadBehindNil() {
    let status = parse("# branch.oid \(headOid)\u{00}# branch.head main\u{00}")
    XCTAssertNil(status.upstream)
    XCTAssertNil(status.ahead)
    XCTAssertNil(status.behind)
  }

  func testAheadBehindBothDirections() {
    let status = parse(
      "# branch.head main\u{00}# branch.upstream origin/main\u{00}# branch.ab +3 -2\u{00}")
    XCTAssertEqual(status.ahead, 3)
    XCTAssertEqual(status.behind, 2)
  }

  func testMalformedAheadBehindIsIgnored() {
    let status = parse("# branch.head main\u{00}# branch.ab broken\u{00}")
    XCTAssertNil(status.ahead)
    XCTAssertNil(status.behind)
  }

  func testUnmergedEntry() {
    let status = parse(
      "u UU N... 100644 100644 100644 100644 \(blob) \(blob) \(blob) both modified.swift\u{00}")
    XCTAssertEqual(
      status.files,
      [
        FileChange(
          path: "both modified.swift", oldPath: nil, staged: .unmerged, unstaged: .unmerged)
      ])
    XCTAssertTrue(status.files[0].isConflicted)
  }

  func testUntrackedAndIgnored() {
    let status = parse("? new file.txt\u{00}! build/out.log\u{00}")
    XCTAssertEqual(
      status.files,
      [FileChange(path: "new file.txt", oldPath: nil, staged: nil, unstaged: .untracked)])
  }

  func testStatusLetterMapping() {
    let status = parse(
      "1 .T N... 100644 100644 120000 \(blob) \(blob) link.txt\u{00}"
        + "1 D. N... 100644 000000 000000 \(blob) \(zero) removed.txt\u{00}")
    XCTAssertEqual(status.files[0].unstaged, .typeChanged)
    XCTAssertEqual(status.files[1].staged, .deleted)
  }

  func testEmptyInput() {
    let status = StatusParser.parse(Data())
    XCTAssertNil(status.branch)
    XCTAssertNil(status.oid)
    XCTAssertEqual(status.files, [])
  }

  func testMalformedEntriesAreSkipped() {
    let status = parse(
      "garbage record\u{00}"
        + "1 tooshort\u{00}"
        + "2 R. N... 100644 100644 100644 \(blob) \(blob) R100 no-orig-path.txt\u{00}")
    // 不正レコードと origPath 欠落の rename は落ちずに読み飛ばされる。
    XCTAssertEqual(status.files, [])
  }
}
