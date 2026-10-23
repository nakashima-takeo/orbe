import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff の側の決まり方——新しい側の文書が替わったとき（並びが載るまで出さない・仮のタブとタブ行・未保存が下りたとき）、
/// 両側とも無いパス、途中のシンボリックリンク。壊れると、diff タブに編集できる面が一瞬出る・未保存の文書を
/// 使う仮のタブが黙って入れ替わる・消えたファイルの diff が古いまま残る・リンク先の別のファイルが出る・空の diff が理由
/// なしに出る。
extension EditorDiffTests {
  /// diff だけが持つファイルが消えて戻った直後は、新しい文書の行差分が届くまで本体に何も出さず、届けば読むだけで出す。
  func testADiffOnlyDocumentThatComesBackShowsNothingUntilItsRowsArrive() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, _) = tab()
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let contents = try Data(contentsOf: repo.url("a.txt"))
    try FileManager.default.removeItem(at: repo.url("a.txt"))
    pumpMain(until: { diff.document == nil && diff.content == .ready }, "消えたファイルの diff")

    try contents.write(to: repo.url("a.txt"))
    diff.rootFiles(diff.files, filesDidChange: .scanAll)
    let document = try XCTUnwrap(diff.document, "前提: 戻ったファイルの文書に替わる")
    XCTAssertEqual(diff.content, .loading, "並びが載るまで何も出さない")
    XCTAssertNil(diff.newSurface)
    waitRows(diff, "行差分が届く") { self.removedLines($0) == [1] }
    XCTAssertFalse(try engine(document.surface).isEditable, "読むだけで出す")
  }

  /// 未保存のファイルが外で消えて戻ると、それを新しい側に使うようになった仮の diff タブは普通のタブになり、未保存の印が
  /// 出る。
  func testAPreviewDiffIsPinnedWhenItSwitchesToAnUnsavedDocument() throws {
    let (tab, _) = tab()
    let document = try tab.group.editor.open(repo.url("a.txt"), as: .pinned)
    document.surface.responder.perform(Selector(("insertText:")), with: "Z")
    let contents = try Data(contentsOf: repo.url("a.txt"))
    try FileManager.default.removeItem(at: repo.url("a.txt"))
    let key = id("a.txt", .workingTree)
    let diff = try tab.group.editor.openDiff(key, as: .preview)
    XCTAssertNil(diff.document, "前提: 消えたファイルの diff")
    XCTAssertEqual(tab.group.editor.previewID, .diff(key), "前提: 仮のタブ")

    try contents.write(to: repo.url("a.txt"))
    pumpMain(until: { diff.document === document }, "戻ったファイルの未保存の文書を使う")
    XCTAssertNil(tab.group.editor.previewID, "仮のタブは普通になる")
    XCTAssertEqual(tab.group.view.editor.shell.tabs.map(\.isDirty), [true, true], "diff タブにも未保存の印")
  }

  /// 未保存の文書を使う diff を仮で開くと、今の仮のタブは残り、diff は末尾の普通のタブになる。
  func testAnUnsavedDocumentsDiffOpensAsAPinnedTabAtTheEnd() throws {
    try repo.write("b.txt", "b\n")
    let (tab, _) = tab()
    let document = try tab.group.editor.open(repo.url("a.txt"), as: .pinned)
    document.surface.responder.perform(Selector(("insertText:")), with: "Z")
    try tab.group.editor.open(repo.url("b.txt"), as: .preview)
    let preview = try XCTUnwrap(tab.group.editor.previewID)
    let key = id("a.txt", .workingTree)
    try tab.group.editor.openDiff(key, as: .preview)
    XCTAssertEqual(tab.group.editor.previewID, preview, "今の仮のタブは残る")
    XCTAssertEqual(tab.group.editor.tabs.map(\.id).last, .diff(key), "末尾の普通のタブ")
  }

  /// 未追跡のファイルの作業ツリー diff を見せている間に、未保存のままファイルが消え、保存時の本文へ戻して未保存が下りると、
  /// その時点で diff が今の作業ツリーの姿（両側とも無い）に追いつく。
  func testAnUntrackedFilesDiffCatchesUpWhenTheUnsavedMarkClearsLater() throws {
    try repo.write("u.txt", "u\n")
    let (tab, _) = tab()
    let document = try tab.group.editor.open(repo.url("u.txt"), as: .pinned)
    document.surface.responder.perform(Selector(("insertText:")), with: "Z")
    let diff = try tab.group.editor.openDiff(id("u.txt", .workingTree), as: .pinned)
    waitRows(diff, "追加が出る") { $0.style(ofLine: 0) == DiffStyle.added }
    try FileManager.default.removeItem(at: repo.url("u.txt"))
    pumpMain(until: { diff.files.status?.entries["u.txt"] == nil }, "消えた")
    XCTAssertTrue(diff.document === document, "前提: 未保存の間は手放さない")

    document.surface.replaceAll(with: "u\n")
    XCTAssertTrue(document.isDirty, "前提: 同じ長さなので、未保存は裏の比べで後から下りる")
    pumpMain(until: { diff.content == .unavailable(.nowhere) }, "未保存が下りた時点で追いつく")
  }

  /// git にも作業ツリーにも無いパス・HEAD にも index にも無いパスの diff は、種類ごとの理由の一文を出す。開いた後で両側とも
  /// 無くなったときも同じ。
  func testADiffOfAPathInNeitherSideSaysWhy() throws {
    let (tab, _) = tab()
    let pane = tab.group.view.editor
    let working = try tab.group.editor.openDiff(id("nope.txt", .workingTree), as: .pinned)
    pumpMain(until: { working.content == .unavailable(.nowhere) }, "作業ツリー")
    pumpMain(until: { pane.faceContent == .notice(.editorDiffNowhereInWorkingTree) })
    let staged = try tab.group.editor.openDiff(id("nope.txt", .staged), as: .pinned)
    pumpMain(until: { staged.content == .unavailable(.nowhere) }, "ステージ済み")
    pumpMain(until: { pane.faceContent == .notice(.editorDiffNowhereStaged) })

    try repo.write("u.txt", "u\n")
    let untracked = try tab.group.editor.openDiff(id("u.txt", .workingTree), as: .pinned)
    waitRows(untracked, "追加が出る") { $0.style(ofLine: 0) == DiffStyle.added }
    try FileManager.default.removeItem(at: repo.url("u.txt"))
    pumpMain(until: { untracked.content == .unavailable(.nowhere) }, "開いた後で両側とも無くなった")
  }

  /// 追跡中のディレクトリがシンボリックリンクに置き換わると、作業ツリー diff の新しい側は「消した」（全部の行が削除）で、
  /// リンク先のファイルを開かない。
  func testATrackedDirectoryReplacedByASymlinkShowsTheFileAsRemoved() throws {
    try repo.write("dir/f.txt", "f\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "dir"]).isSuccess)
    let outside = TestScratch.caseDir.appendingPathComponent("outside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("other\n".utf8).write(to: outside.appendingPathComponent("f.txt"))
    try FileManager.default.removeItem(at: repo.url("dir"))
    try FileManager.default.createSymbolicLink(at: repo.url("dir"), withDestinationURL: outside)
    let (tab, _) = tab()
    let diff = try tab.group.editor.openDiff(id("dir/f.txt", .workingTree), as: .pinned)
    waitRows(diff, "全部の行が削除") { self.removedLines($0) == [0, 1] }
    XCTAssertNil(diff.document, "リンク先の文書を開かない")
  }
}
