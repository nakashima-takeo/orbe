import OrbeTestSupport
import XCTest

@testable import Orbe

/// ツリーの名前の絞り込み（実ファイル・実 git）: 名前に字を含むファイルとその祖先のフォルダだけを全部開いた形で残し、
/// 絞り込みの間の開閉は絞り込みの中だけに留め、解けば絞り込む前のツリーに戻る。対象の一覧を git が返せない間は、空の一覧と
/// みなさない。合ったファイルは上限で打ち切る。
///
/// 壊れると何が起きるか。畳んでいたフォルダの中のファイルが見つからない。絞り込みを解くと開閉が崩れている。絞り込みの間に
/// 開いたファイルが、解いたツリーに見えない。git が一時に失敗しただけで「一致するファイルがありません。」が出る。1 字で
/// 数万の行を組んで固まる。
extension FileTreeTests {
  /// 見えていて、エクスプローラーが出ているツリー。
  private func shownTree() -> FileTree {
    let tree = FileTree(root: repo.root)
    tree.isLive = true
    tree.isExplorerShown = true
    return tree
  }

  /// 欄に `text` を打ち、その字の結果が届くまで待つ。
  private func filter(_ tree: FileTree, _ text: String) {
    tree.setFilterText(text)
    pumpMain(until: { tree.filter.shown?.text == text }, "「\(text)」の結果が届く")
  }

  /// 名前（大小を区別しない）に字を含むファイルと、その祖先のフォルダだけが、全部開いた形で残る（畳んでいたフォルダの中も）。
  /// 名前が合うのがフォルダだけなら、その中のファイルは残らない。合うファイルが無ければ行は無い。
  func testFilteringKeepsFilesWhoseNameContainsTheTextAndTheirFoldersOpen() throws {
    try repo.write("src/sub/README.txt", "r\n")
    try repo.write("readers/x.txt", "x\n")
    let tree = shownTree()

    filter(tree, "rEAd")
    XCTAssertEqual(names(tree), ["docs", "  readme.md", "src/sub", "  README.txt"])

    filter(tree, "zzz")
    XCTAssertEqual(tree.rows, [], "合うファイルが無ければ行は無い（絞り込まないツリーに戻らない）")
    XCTAssertEqual(tree.filter.shown?.matchCount, 0)
  }

  /// 絞り込みの間のフォルダの開閉は絞り込みの中だけのもの——押すと畳めて選択は動かず、字を変えると全部開いた形に戻り（新しい字の
  /// 結果が届くまでは前の字の結果のまま）、すべて折りたたむも結果のフォルダだけを畳み、字を空にすると絞り込む前の開閉に戻る。
  /// 絞り込みの間に開いたファイルは、解いたツリーで祖先が開いて選択の行になる。
  func testFolderTogglesWhileFilteringStayInsideTheFilter() throws {
    let tree = shownTree()
    tree.toggle("docs")
    tree.reveal(repo.url("a.txt"))
    XCTAssertEqual(names(tree), ["docs", "  readme.md", "src", "a.txt"], "前提: docs だけ開いている")

    filter(tree, "md")
    XCTAssertEqual(names(tree), ["docs", "  readme.md", "src/sub", "  deep.md"])
    tree.toggle("docs")
    XCTAssertEqual(names(tree), ["docs", "src/sub", "  deep.md"], "押すと畳む")
    XCTAssertEqual(tree.selected, "a.txt", "選択は動かない")

    tree.setFilterText("m")
    XCTAssertEqual(
      names(tree), ["docs", "  readme.md", "src/sub", "  deep.md"],
      "新しい字の結果が届くまで、前の字の結果を全部開いた形で出したまま")
    filter(tree, "m")
    XCTAssertEqual(
      names(tree), ["docs", "  readme.md", "src", "  sub", "    deep.md", "  main.swift"],
      "字を変えると全部開いた形に戻る")
    tree.reveal(repo.url("src/sub/deep.md"))
    tree.collapseAll()
    XCTAssertEqual(names(tree), ["docs", "src"], "すべて折りたたむは、結果のフォルダだけを畳む")

    tree.setFilterText("")
    XCTAssertEqual(
      names(tree), ["docs", "  readme.md", "src", "  sub", "    deep.md", "  main.swift", "a.txt"],
      "絞り込む前の開閉に、絞り込みの間に開いたファイルの祖先を開いた形")
    XCTAssertEqual(tree.rows.first(where: \.isSelected)?.id, "src/sub/deep.md")
  }

  /// 対象の一覧を git が返せない間は、取れなかったと示し、一致 0 件の結果を出さない。git が直れば、次の変化で取り直して結果が
  /// 出る。
  func testAListGitFailsToGiveIsNotTakenAsEmpty() throws {
    let tree = shownTree()
    pumpMain(until: { tree.status != nil }, "前提: 管理下と判定して status を取る")
    let index = repo.root + "/.git/index"
    let intact = try Data(contentsOf: URL(fileURLWithPath: index))
    try Data("broken".utf8).write(to: URL(fileURLWithPath: index))

    tree.setFilterText("md")
    pumpMain(until: { tree.filter.listFailed }, "取れなかったと示す")
    XCTAssertNil(tree.filter.shown, "一致 0 件の結果を出さない")

    try intact.write(to: URL(fileURLWithPath: index))
    try repo.write("src/new.md", "n\n")
    pumpMain(until: { tree.filter.shown?.text == "md" }, "次の変化で取り直す")
    XCTAssertEqual(
      names(tree), ["docs", "  readme.md", "src", "  sub", "    deep.md", "  new.md"])
    XCTAssertFalse(tree.filter.listFailed)
  }

  /// 一覧を取れた後に git が一時的に失敗しても、前に取れた一覧での結果が残り（一致 0 件にも、取れなかったにもならない）、字を
  /// 変えても前の一覧で照合する。git が直れば、次の変化で取り直して新しい結果になる。
  func testAGitFailureAfterAListKeepsTheResultsOfThePreviousList() throws {
    let tree = shownTree()
    filter(tree, "md")
    let before = names(tree)
    XCTAssertEqual(before, ["docs", "  readme.md", "src/sub", "  deep.md"], "前提: 一覧を取れている")
    let index = repo.root + "/.git/index"
    let intact = try Data(contentsOf: URL(fileURLWithPath: index))
    try Data("broken".utf8).write(to: URL(fileURLWithPath: index))

    try repo.write("src/new.md", "n\n")
    // 失敗した取り直しは見える結果を変えないので、終わったことは内部の「古い」の印（`isStale`）で待つ。
    pumpMain(until: { tree.filter.isStale }, "変化で取り直し、git が失敗する")
    XCTAssertEqual(names(tree), before, "前に取れた一覧での結果が残る")
    XCTAssertFalse(tree.filter.listFailed, "取れなかったとは示さない")
    filter(tree, "deep")
    XCTAssertEqual(names(tree), ["src/sub", "  deep.md"], "字を変えても前の一覧で照合する")
    XCTAssertFalse(tree.filter.listFailed)

    try intact.write(to: URL(fileURLWithPath: index))
    try repo.write("src/deeper.md", "d\n")
    pumpMain(
      until: { self.names(tree) == ["src", "  sub", "    deep.md", "  deeper.md"] },
      "git が直れば、次の変化で取り直す")
  }

  /// 合ったファイルが上限を越えれば上限で打ち切り、打ち切ったと添える。上限ちょうどなら打ち切らない。
  func testMatchesBeyondTheLimitAreCutAtTheLimit() {
    let root = URL(fileURLWithPath: repo.root)
    let limit = FileTreeFilter.matchLimit
    let over = FileTreeFilter.index(
      root: root, paths: (0...limit).map { "d/m\($0).txt" }, isTruncated: false)
    let exact = FileTreeFilter.index(
      root: root, paths: (1...limit).map { "d/m\($0).txt" }, isTruncated: false)

    let cut = FileTreeFilter.result(of: over, text: "m")
    let whole = FileTreeFilter.result(of: exact, text: "m")

    XCTAssertEqual(cut.matchCount, limit)
    XCTAssertEqual(cut.children["d"]?.count, limit, "行に出すのも上限まで")
    XCTAssertTrue(cut.matchesTruncated)
    XCTAssertEqual(whole.matchCount, limit)
    XCTAssertFalse(whole.matchesTruncated)
  }
}
