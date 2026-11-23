import XCTest

@testable import Orbe

/// Changes の変更ファイルの一覧の行の組——見出しは、ファイルのある区分にだけ出る。ファイルの行の番号と diff の識別は、出ている
/// 見出しを数えて対応づける。
///
/// 壊れると何が起きるか。ステージした変更が無いときに、空の「ステージされている変更」の見出しが出る。一覧を開いたとき、
/// 本体に出ている「変更」の区分の diff と違う行が選ばれ、そのまま ↵ を押すと、本体と別のファイルの diff が開く。
final class ChangedFilesListTests: OrbeTestCase {
  private static let root = "/r"

  private func rows(staged: [String], changes: [String]) -> ScmChangedFilesRows {
    let file = { (path: String) in
      ScmChanges.File(
        row: GitStatus.Row(path: path, originalPath: nil), badge: .modified, opensAsFile: true,
        discardMovesToTrash: false)
    }
    return ScmChangedFilesRows(
      root: Self.root,
      changes: ScmChanges(
        staged: staged.map(file), changes: changes.map(file), head: nil, stagedVersions: [:]),
      titles: [.staged: "staged", .changes: "changes"])
  }

  private func key(_ path: String, _ kind: EditorDiff.Kind) -> EditorDiff.Key {
    EditorDiff.Key(root: Self.root, path: path, kind: kind)
  }

  func testOnlySectionsWithFilesHaveAHeadingAndEachFileRowIsItsDiff() {
    let both = rows(staged: ["s.txt"], changes: ["a.txt", "b.txt"])
    XCTAssertEqual(both.count, 5)
    XCTAssertEqual(both.row(at: 0), .heading(title: "staged", count: 1, key: nil))
    XCTAssertEqual(both.row(at: 2), .heading(title: "changes", count: 2, key: nil))
    XCTAssertEqual(both.index(of: key("s.txt", .staged)), 1)
    XCTAssertEqual(both.index(of: key("b.txt", .workingTree)), 4, "2 つの見出しの後")
    XCTAssertEqual(both.id(at: 4), AnyHashable(key("b.txt", .workingTree)))
    XCTAssertNil(both.id(at: 2), "見出しの行は diff を持たない")

    let unstagedOnly = rows(staged: [], changes: ["a.txt", "b.txt"])
    XCTAssertEqual(unstagedOnly.count, 3, "空の区分は見出しごと出さない")
    XCTAssertEqual(unstagedOnly.row(at: 0), .heading(title: "changes", count: 2, key: nil))
    XCTAssertEqual(unstagedOnly.index(of: key("b.txt", .workingTree)), 2)
    XCTAssertEqual(unstagedOnly.id(at: 2), AnyHashable(key("b.txt", .workingTree)))
  }
}
