import OrbeTestSupport
import XCTest

@testable import Orbe

/// ツリーの連なり（実ファイル・実 FSEvents）: 子がフォルダ 1 つだけのフォルダの連なりを、開いていなくても 1 行にまとめ、行は
/// いちばん深いフォルダとして働く。連なりはディスクの形だけで決まり、途中に足されれば分かれ、無くなればまとまる。見えて
/// いなかった間の変化も、見え直したときに調べ直す。
///
/// 壊れると何が起きるか。`docs/spec/editor` のような深いパスを 1 段ずつ開かされる。まとめた行を押しても中身が出ない・途中の
/// フォルダに新規ファイルが入る。途中にファイルを足しても行が分かれず、足したファイルがツリーのどこにも出ない。
extension FileTreeTests {
  /// 根に `guide/spec/editor/{files,shell}.md` を足して見せ、先読みで連なりの行になるまで待つ。
  private func chainedTree() throws -> FileTree {
    try repo.write("guide/spec/editor/shell.md", "s\n")
    try repo.write("guide/spec/editor/files.md", "f\n")
    let tree = FileTree(root: repo.root)
    tree.isLive = true
    pumpMain(until: { self.names(tree).contains("guide/spec/editor") }, "開いていないフォルダの連なりが 1 行になる")
    return tree
  }

  /// 連なりの行は 1 つのフォルダとして働く——押すと全部が開いていちばん深いフォルダの中身が 1 段下に出て、選択と新規作成の
  /// 挿し先はいちばん深いフォルダになり、選択の行へ一覧を送るときの宛先（選択を含む行）は連なりの行になる。もう 1 回押せば畳む。
  func testAChainRowActsAsItsDeepestFolder() throws {
    let tree = try chainedTree()
    XCTAssertEqual(names(tree), ["docs", "guide/spec/editor", "src", "a.txt"])

    tree.toggle("guide")
    XCTAssertEqual(
      names(tree), ["docs", "guide/spec/editor", "  files.md", "  shell.md", "src", "a.txt"])
    let selected = try XCTUnwrap(tree.rows.first { $0.id == tree.selectedRowID })
    XCTAssertEqual(selected.prefix + selected.name, "guide/spec/editor", "選択を含む行は連なりの行")
    XCTAssertTrue(selected.isSelected)

    tree.beginNew(isDirectory: false)
    XCTAssertEqual(tree.newEntry?.directory, "guide/spec/editor", "挿し先はいちばん深いフォルダ")
    XCTAssertEqual(tree.rows.firstIndex(where: \.isInput), 2, "入力行は連なりの行のすぐ下")
    tree.cancelNew()

    tree.toggle("guide")
    XCTAssertEqual(names(tree), ["docs", "guide/spec/editor", "src", "a.txt"], "もう 1 回押せば畳む")
  }

  /// 連なりの途中のフォルダに外でファイルが足されると、畳んだ行でも行はそこで分かれ、消えれば再びまとまる。まとまった行は、
  /// いちばん深いフォルダが開いていなければ畳んだ形で出て、押せば連なりの全部が開く。
  func testAChainSplitsWhenAFolderInTheMiddleGainsAnEntryAndJoinsWhenItLosesIt() throws {
    let tree = try chainedTree()

    try repo.write("guide/spec/notes.md", "n\n")
    pumpMain(
      until: { self.names(tree) == ["docs", "guide/spec", "src", "a.txt"] }, "畳んだ行も途中で分かれる")
    tree.toggle("guide")
    XCTAssertEqual(
      names(tree), ["docs", "guide/spec", "  editor", "  notes.md", "src", "a.txt"])

    try FileManager.default.removeItem(atPath: repo.root + "/guide/spec/notes.md")
    pumpMain(
      until: { self.names(tree) == ["docs", "guide/spec/editor", "src", "a.txt"] },
      "途中の子が消えればまとまり、いちばん深いフォルダは開いていないので畳んだ形")
    tree.toggle("guide")
    XCTAssertEqual(
      names(tree), ["docs", "guide/spec/editor", "  files.md", "  shell.md", "src", "a.txt"])
  }

  /// 見えていなかった間に連なりの途中へ足されたものは、見え直したときに調べ直され、覚えていた連なりのまま残らない。
  func testAChainIsCheckedAgainWhenTheTreeIsShownAgain() throws {
    let tree = try chainedTree()
    tree.isLive = false

    try repo.write("guide/spec/notes.md", "n\n")
    tree.isLive = true

    pumpMain(
      until: { self.names(tree) == ["docs", "guide/spec", "src", "a.txt"] }, "見え直したときに分かれる")
  }
}
