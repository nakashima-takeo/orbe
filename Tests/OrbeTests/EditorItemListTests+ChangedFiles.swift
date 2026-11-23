import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 変更ファイルの一覧の行の組（Changes の 2 区分）を一覧の器に載せたとき——変更ファイルが数万でも、開く操作と ↑↓ で読み出す行は
/// 見えている行だけで、開いたときの選択（区分の途中のファイル）は正しい行に当たる。
///
/// 壊れると何が起きるか。数万件の変更があるリポジトリで、左の列を閉じた画面で上のバーのボタンを押すたびに、全行を組んで
/// 固まる。開いたときに、本体の diff と違う行が選ばれる。
extension EditorItemListTests {
  /// 行を読み出した回数を数えるラッパー。
  private final class Counting: EditorItemListRows {
    let rows: any EditorItemListRows
    private(set) var reads = 0

    init(_ rows: any EditorItemListRows) { self.rows = rows }

    var count: Int { rows.count }
    func row(at index: Int) -> EditorItemListRow {
      reads += 1
      return rows.row(at: index)
    }
    func id(at index: Int) -> AnyHashable? { rows.id(at: index) }
    func index(of id: AnyHashable) -> Int? { rows.index(of: id) }
  }

  private final class Fixed: EditorItemListOwner {
    let content: EditorItemListContent
    init(_ content: EditorItemListContent) { self.content = content }
    func itemListContent() -> EditorItemListContent { content }
    func itemListDetail(of id: AnyHashable) -> EditorItemListContent? { nil }
    func itemListCommit(_ id: AnyHashable) -> EditorItemListOutcome { .close }
    func itemListPress(_ id: AnyHashable) -> EditorItemListOutcome { .stay }
  }

  /// ステージ済み 10 件と、変更 `count` 件（パス順）の 2 区分。
  private func changes(_ count: Int) -> ScmChanges {
    let file = { (path: String, badge: GitStatus.Badge) in
      ScmChanges.File(
        row: GitStatus.Row(path: path, originalPath: nil), badge: badge, opensAsFile: true,
        discardMovesToTrash: false)
    }
    return ScmChanges(
      staged: (0..<10).map { file(String(format: "s/%05d.swift", $0), .added) },
      changes: (0..<count).map { file(String(format: "c/%05d.swift", $0), .modified) },
      head: nil, stagedVersions: [:])
  }

  func testTheChangedFilesRowsReadOnlyTheVisibleRowsAndSelectTheShownDiff() throws {
    let hosted = try host()
    func reads(_ count: Int) throws -> (open: Int, move: Int) {
      let rows = ScmChangedFilesRows(
        root: "/r", changes: changes(count), titles: [.staged: "s", .changes: "c"])
      let shown = EditorDiff.Key(
        root: "/r", path: String(format: "c/%05d.swift", count / 2), kind: .workingTree)
      XCTAssertEqual(rows.index(of: shown), 10 + 2 + count / 2, "区分の途中のファイルの行")
      XCTAssertEqual(rows.id(at: 10 + 2 + count / 2), AnyHashable(shown))
      let counting = Counting(rows)
      hosted.itemList.open(
        Fixed(EditorItemListContent(rows: counting, initialSelection: shown, hints: [])))
      XCTAssertEqual(hosted.itemList.selection, AnyHashable(shown))
      let opened = counting.reads
      for _ in 0..<20 { hosted.itemList.perform(.down) }
      hosted.itemList.close(.escape)
      return (opened, counting.reads - opened)
    }
    let small = try reads(500)
    let large = try reads(50_000)
    let visible = Int(hosted.pane.itemListRect.height / Theme.Layout.editorItemListRow) + 2
    XCTAssertLessThanOrEqual(large.open, small.open + visible, "開く")
    XCTAssertLessThanOrEqual(large.move, small.move + visible, "↑↓")
  }
}
