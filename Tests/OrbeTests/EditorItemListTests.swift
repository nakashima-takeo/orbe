import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 一覧の器——載せる側の中身と口だけで動く器そのもの。↑↓ は見出しを飛ばして端で止まり、↵・→・←・esc は載せる側の口と
/// 詳細の出入りに当たる。中身が替わっても選択は同一性で保ち、無くなれば同じ位置の行へ移る。閉じ方ごとにフォーカスを本体へ
/// 戻すかが決まる。行が数万でも、開く操作と ↑↓ で引く行は見えている行だけ。
///
/// 壊れると何が起きるか。↑↓ が見出しに止まって ↵ が効かない。× で行が消えるたびに選択が先頭へ跳ぶ。esc で閉じた後に
/// 打鍵がどこにも届かない。端末をクリックして一覧を閉じると、エディターがフォーカスを奪い返す。数万行の変更ファイルの一覧を
/// 開くたびに全行を組んで止まる。
@MainActor
final class EditorItemListTests: OrbeTestCase {
  /// 偽物の行の組。行 `i` は、`headings` に含まれれば見出し、それ以外はファイルの行（同一性は番号）。引いた行の数を数える。
  final class Rows: EditorItemListRows {
    let count: Int
    let headings: Set<Int>
    private(set) var reads = 0

    init(count: Int, headings: Set<Int> = [0]) {
      self.count = count
      self.headings = headings
    }

    func row(at index: Int) -> EditorItemListRow {
      reads += 1
      if headings.contains(index) { return .heading(title: "h", count: count, key: nil) }
      return .file(.init(chip: FileChip(glyph: "S", hue: nil), name: "r\(index)", directory: ""))
    }

    func id(at index: Int) -> AnyHashable? { headings.contains(index) ? nil : AnyHashable(index) }

    func index(of id: AnyHashable) -> Int? {
      guard let index = id.base as? Int, index < count, !headings.contains(index) else {
        return nil
      }
      return index
    }
  }

  /// 偽物の載せる側。詳細は「詳細の見出し」と操作の行 2 つ（同一性は文字列）。受けた口を記録する。
  final class Owner: EditorItemListOwner {
    var rows: Rows
    var initial: AnyHashable?
    var outcome = EditorItemListOutcome.close
    private(set) var commits: [AnyHashable] = []
    private(set) var presses: [AnyHashable] = []
    var hasDetail = true

    init(rows: Rows, initial: AnyHashable? = 2) {
      self.rows = rows
      self.initial = initial
    }

    func itemListContent() -> EditorItemListContent {
      EditorItemListContent(rows: rows, initialSelection: initial, hints: [])
    }

    func itemListDetail(of id: AnyHashable) -> EditorItemListContent? {
      guard hasDetail, rows.index(of: id) != nil else { return nil }
      return EditorItemListContent(rows: Detail(), initialSelection: "a", hints: [])
    }

    func itemListCommit(_ id: AnyHashable) -> EditorItemListOutcome {
      commits.append(id)
      return outcome
    }

    func itemListPress(_ id: AnyHashable) -> EditorItemListOutcome {
      presses.append(id)
      return .stay
    }
  }

  struct Detail: EditorItemListRows {
    let count = 3
    func row(at index: Int) -> EditorItemListRow { index == 0 ? .action("head") : .action("op") }
    func id(at index: Int) -> AnyHashable? { [nil, "a", "b"][index] }
    func index(of id: AnyHashable) -> Int? { ["a": 1, "b": 2][id.base as? String ?? ""] }
  }

  struct Hosted {
    let tab: TerminalTab
    let pane: EditorPaneView
    let window: NSWindow
    let document: EditorDocument
    var itemList: EditorItemList { pane.itemList }
  }

  /// 文書を 1 つ開いた面を窓に載せ、本文にフォーカスを置く。タブは返す値が持つ（テストの終わりまで持つ）。
  func host() throws -> Hosted {
    let tab = TerminalTab.alone(
      cwd: TestScratch.caseDir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostEditor(tab, width: 900, height: 600)
    let document = try tab.group.editor.open(try caseFile("a.txt", "a"), as: .pinned)
    window.makeFirstResponder(document.surface.responder)
    return Hosted(tab: tab, pane: tab.group.view.editor, window: window, document: document)
  }

  private func key(_ hosted: Hosted, _ action: RowListKey.Action) {
    hosted.itemList.perform(action)
  }

  // MARK: - 開く・キー

  /// 開くと行の列がフォーカスを持ち、開いたときに選ぶ行が選ばれる。↑↓ は見出しを飛ばし、端で止まる。↵ は選んでいる行を
  /// 載せる側へ渡し、「閉じる」なら閉じて本文へフォーカスが戻る。
  func testKeysMoveAmongSelectableRowsAndEnterCommits() throws {
    let hosted = try host()
    let owner = Owner(rows: Rows(count: 5, headings: [0, 3]))
    hosted.itemList.open(owner)
    XCTAssertTrue(hosted.pane.focusIsInItemList, "開くと行の列がフォーカスを持つ")
    XCTAssertFalse(hosted.pane.itemListHost.isHidden)
    XCTAssertEqual(hosted.itemList.selection, AnyHashable(2))

    key(hosted, .down)
    XCTAssertEqual(hosted.itemList.selection, AnyHashable(4), "見出しを飛ばす")
    key(hosted, .down)
    XCTAssertEqual(hosted.itemList.selection, AnyHashable(4), "下の端で止まる")
    key(hosted, .up)
    key(hosted, .up)
    XCTAssertEqual(hosted.itemList.selection, AnyHashable(1))
    key(hosted, .up)
    XCTAssertEqual(hosted.itemList.selection, AnyHashable(1), "上の端（見出しの手前）で止まる")
    XCTAssertEqual(hosted.itemList.list.list.selectedRow, 1, "選択は行の列へ写る")

    key(hosted, .enter)
    XCTAssertEqual(owner.commits, [AnyHashable(1)])
    XCTAssertFalse(hosted.itemList.isOpen)
    XCTAssertTrue(hosted.window.firstResponder === hosted.document.surface.responder, "本文へ戻る")
    XCTAssertTrue(hosted.pane.itemListHost.isHidden)
  }

  /// → で選んでいる行の詳細に入り、詳細の開いたときに選ぶ行が選ばれる。← で一覧へ戻り、詳細に入っていた行が選ばれる。
  /// 載せる側が「一覧へ戻る」と答えても戻る。詳細を作れない行では → は何もしない。
  func testRightEntersTheDetailAndLeftOrBackReturns() throws {
    let hosted = try host()
    let owner = Owner(rows: Rows(count: 6))
    hosted.itemList.open(owner)
    key(hosted, .down)
    key(hosted, .right)
    XCTAssertEqual(hosted.itemList.detail?.id, AnyHashable(3))
    XCTAssertEqual(hosted.itemList.selection, AnyHashable("a"), "詳細の開いたときに選ぶ行")
    key(hosted, .down)
    XCTAssertEqual(hosted.itemList.selection, AnyHashable("b"))
    key(hosted, .left)
    XCTAssertNil(hosted.itemList.detail)
    XCTAssertEqual(hosted.itemList.selection, AnyHashable(3), "詳細に入っていた行")

    key(hosted, .right)
    owner.outcome = .back
    key(hosted, .enter)
    XCTAssertEqual(owner.commits, [AnyHashable("a")])
    XCTAssertTrue(hosted.itemList.isOpen, "一覧へ戻り、開いたまま")
    XCTAssertNil(hosted.itemList.detail)
    XCTAssertEqual(hosted.itemList.selection, AnyHashable(3))

    owner.hasDetail = false
    key(hosted, .right)
    XCTAssertNil(hosted.itemList.detail, "詳細を作れなければ入らない")
  }

  // MARK: - 中身の差し替え

  /// 中身が替わっても選択は同一性で保ち、選んでいた行が無くなれば同じ位置の選べる行へ移る。詳細に入っている間に、その行の
  /// 詳細を作れなくなれば一覧へ戻る。行の数が変われば器の高さが行の数に合う。
  func testTheSelectionSurvivesContentChanges() throws {
    let hosted = try host()
    let owner = Owner(rows: Rows(count: 6))
    hosted.itemList.open(owner)
    let height = hosted.pane.itemListRect.height
    key(hosted, .down)
    key(hosted, .down)
    XCTAssertEqual(hosted.itemList.selection, AnyHashable(4))

    owner.rows = Rows(count: 6, headings: [0, 4])
    hosted.itemList.contentDidChange(owner.itemListContent())
    XCTAssertEqual(hosted.itemList.selection, AnyHashable(5), "無くなれば同じ位置の選べる行（下へ）")
    owner.rows = Rows(count: 5)
    hosted.itemList.contentDidChange(owner.itemListContent())
    XCTAssertEqual(hosted.itemList.selection, AnyHashable(4), "下に無ければ上へ")
    hosted.pane.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      hosted.pane.itemListRect.height, height - Theme.Layout.editorItemListRow, "高さは行の数に合う")

    key(hosted, .right)
    XCTAssertNotNil(hosted.itemList.detail)
    owner.hasDetail = false
    hosted.itemList.contentDidChange(owner.itemListContent())
    XCTAssertNil(hosted.itemList.detail, "詳細を作れなくなれば一覧へ戻る")
    XCTAssertEqual(hosted.itemList.selection, AnyHashable(4))
  }

  // MARK: - 閉じ方とフォーカス

  /// esc は閉じて本文へフォーカスを戻す。フォーカスが一覧の外へ移って閉じたときは、移った先から動かさない。
  func testEscapeReturnsTheFocusAndLeavingKeepsItWhereItWent() throws {
    let hosted = try host()
    hosted.itemList.open(Owner(rows: Rows(count: 4)))
    key(hosted, .escape)
    XCTAssertFalse(hosted.itemList.isOpen)
    XCTAssertTrue(hosted.window.firstResponder === hosted.document.surface.responder)

    let outsider = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
    hosted.tab.group.view.addSubview(outsider)
    hosted.itemList.open(Owner(rows: Rows(count: 4)))
    XCTAssertTrue(hosted.window.makeFirstResponder(outsider))
    XCTAssertFalse(hosted.itemList.isOpen, "フォーカスが外へ移れば閉じる")
    let responder = try XCTUnwrap(hosted.window.firstResponder as? NSView)
    XCTAssertTrue(responder.isDescendant(of: outsider) || responder === outsider, "移った先に残る")
    nextTurn()
    XCTAssertTrue(hosted.itemList.list.isHidden, "行の列は次のターンに隠れる")
  }

  /// 一覧の外の押下は閉じて本文へフォーカスを戻す。一覧の上の押下と、⌥ で透かしている間の押下では閉じない。
  func testAPressOutsideClosesUnlessItIsOnTheListOrWhilePeeking() throws {
    let hosted = try host()
    hosted.itemList.open(Owner(rows: Rows(count: 4)))
    let pane = hosted.pane
    let inside = pane.convert(
      NSPoint(x: pane.itemListRect.midX, y: pane.itemListRect.maxY - 4), to: nil)
    pane.pressWillArrive(.mouse(.leftMouseDown, at: inside, in: hosted.window))
    XCTAssertTrue(hosted.itemList.isOpen, "器の上（下の案内）の押下では閉じない")

    let outside = pane.convert(NSPoint(x: pane.bounds.maxX - 20, y: pane.bounds.maxY - 20), to: nil)
    pane.isPeeking = true
    pane.pressWillArrive(.mouse(.leftMouseDown, at: outside, in: hosted.window))
    XCTAssertTrue(hosted.itemList.isOpen, "透かしている間は閉じない")
    pane.isPeeking = false
    pane.pressWillArrive(.mouse(.leftMouseDown, at: outside, in: hosted.window))
    XCTAssertFalse(hosted.itemList.isOpen)
    XCTAssertTrue(hosted.window.firstResponder === hosted.document.surface.responder)
  }

  // MARK: - 性能

  /// 行が数万でも、開く操作と ↑↓ で引く行の数は、見えている行の数で決まる（行が百倍でも、引く行の数は変わらない）。
  func testOpeningAndMovingReadOnlyTheVisibleRows() throws {
    let hosted = try host()
    func reads(_ count: Int) -> (open: Int, move: Int) {
      let rows = Rows(count: count)
      hosted.itemList.open(Owner(rows: rows, initial: count / 2))
      let opened = rows.reads
      for _ in 0..<20 { key(hosted, .down) }
      hosted.itemList.close(.escape)
      return (opened, rows.reads - opened)
    }
    let small = reads(500)
    let large = reads(50_000)
    let visible = Int(hosted.pane.itemListRect.height / Theme.Layout.editorItemListRow) + 2
    XCTAssertLessThanOrEqual(large.open, small.open + visible, "開く")
    XCTAssertLessThanOrEqual(large.move, small.move + visible, "↑↓")
  }
}
