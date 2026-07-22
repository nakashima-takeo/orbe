import XCTest

@testable import Orbe

/// LogParser（%H%x1f%h%x1f%an%x1f%at%x1f%P%x1f%D%x1f%s%x1e）のフィクスチャテスト。
final class GitLogParserTests: XCTestCase {
  private let fs = "\u{1f}"
  private let rs = "\u{1e}"
  private let oidA = "8d9c35ea1b04f9a2c6d3e7f8091a2b3c4d5e6f70"
  private let oidB = "4f2a91c3b5d7e9f1a3b5c7d9e1f3a5b7c9d1e3f5"
  private let oidC = "1b2c3d4e5f60718293a4b5c6d7e8f9a0b1c2d3e4"

  /// フィールド順: oid, shortOid, author, at(epoch), parents, refs, subject。
  private func record(_ fields: String...) -> String {
    fields.joined(separator: fs) + rs
  }

  func testMultipleRecords() {
    let input =
      record(
        oidA, "8d9c35e", "Alice", "1700000000", oidB, "HEAD -> feature/hooks, origin/feature/hooks",
        "feat: 初回実装")
      + "\n"
      + record(oidB, "4f2a91c", "Bob Smith", "1700003600", "", "", "fix: handle empty input") + "\n"
    XCTAssertEqual(
      LogParser.parse(input),
      [
        Commit(
          oid: oidA, shortOid: "8d9c35e", author: "Alice",
          date: Date(timeIntervalSince1970: 1_700_000_000),
          parents: [oidB], refs: ["HEAD -> feature/hooks", "origin/feature/hooks"],
          subject: "feat: 初回実装"),
        Commit(
          oid: oidB, shortOid: "4f2a91c", author: "Bob Smith",
          date: Date(timeIntervalSince1970: 1_700_003_600),
          parents: [], refs: [], subject: "fix: handle empty input"),
      ])
  }

  func testMergeCommitHasTwoParents() {
    let input = record(
      oidA, "8d9c35e", "Alice", "1700000000", "\(oidB) \(oidC)", "tag: v0.9.0", "merge main")
    let commits = LogParser.parse(input)
    XCTAssertEqual(commits.count, 1)
    XCTAssertEqual(commits[0].parents, [oidB, oidC])
    XCTAssertEqual(commits[0].refs, ["tag: v0.9.0"])
  }

  func testSingleRecordWithoutTrailingNewline() {
    let commits = LogParser.parse(
      record(oidA, "8d9c35e", "Alice", "1700000000", "", "", "subject"))
    XCTAssertEqual(commits.count, 1)
    XCTAssertEqual(commits[0].subject, "subject")
  }

  func testEmptyInput() {
    XCTAssertEqual(LogParser.parse(""), [])
    XCTAssertEqual(LogParser.parse("\n"), [])
  }

  func testEmptySubjectIsKept() {
    let commits = LogParser.parse(
      record(oidA, "8d9c35e", "Alice", "1700000000", oidB, "", "") + "\n")
    XCTAssertEqual(commits.count, 1)
    XCTAssertEqual(commits[0].subject, "")
  }

  func testMalformedRecordIsSkipped() {
    let input =
      "broken record without separators\(rs)\n"
      + record(oidA, "8d9c35e", "Alice", "not-a-number", "", "", "bad date") + "\n"
      + record(oidB, "4f2a91c", "Bob", "1700003600", "", "", "survives") + "\n"
    let commits = LogParser.parse(input)
    XCTAssertEqual(commits.count, 1)
    XCTAssertEqual(commits[0].subject, "survives")
  }
}
