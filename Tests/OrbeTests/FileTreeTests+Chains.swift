import OrbeTestSupport
import XCTest

@testable import Orbe

/// ツリーの連なり（実ファイル・実 FSEvents）: 子がフォルダ 1 つだけのフォルダの連なりを、開いていなくても 1 行にまとめ、行は
/// いちばん深いフォルダとして働く。連なりはディスクの形だけで決まり、途中に足されれば分かれ、無くなればまとまる。見えて
/// いなかった間の変化も、見え直したときに調べ直す。開いたフォルダの中の、開いていないフォルダも先読みする。先読みは根の git の
/// 作業ツリーのフォルダだけを読み、入れ子のリポジトリの中と、git の外の根の下は読まない。
///
/// 壊れると何が起きるか。`docs/spec/editor` のような深いパスを 1 段ずつ開かされる。まとめた行を押しても中身が出ない・途中の
/// フォルダに新規ファイルが入る。途中にファイルを足しても行が分かれず、足したファイルがツリーのどこにも出ない。根がホームの
/// とき、エクスプローラーを出しただけで、書類フォルダなどの中を利用者の操作なしに読む。
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

  /// 開いたフォルダの中の、開いていないフォルダの連なりも、先読みで 1 行になる。
  func testAChainInsideAnOpenedFolderIsJoinedByTheLookahead() throws {
    // 連なりのファイルは、ツリーを作る前に置く（後から置くと、監視の通知の側でも連なりになる）。
    try repo.write("src/gen/proto/x.pb", "p\n")
    // 根の直下の連なりが出るまで待つ（git 管理下かの判定と、根の直下の先読みが済む）。
    let tree = try chainedTree()

    tree.toggle("src")

    pumpMain(until: { self.names(tree).contains("  gen/proto") }, "開いたフォルダの中の連なりが 1 行になる")
  }

  /// 入れ子のリポジトリの中は先読みで読まず、連なりにしない。同じ先読みで調べた、隣の連なりは 1 行になる。
  func testTheLookaheadDoesNotReadInsideANestedRepository() throws {
    XCTAssertTrue(repo.git(["init", "-q", "nested"]).isSuccess)
    try repo.write("nested/inner/x.txt", "x\n")
    try repo.write("guide/spec/editor/shell.md", "s\n")
    let tree = FileTree(root: repo.root)
    tree.isLive = true

    // 2 つのフォルダは、同じ 1 回の先読みで調べて返る（隣の連なりが出た時点で、入れ子の分も届いている）。
    pumpMain(until: { self.names(tree).contains("guide/spec/editor") }, "前提: 隣の連なりが 1 行になる")
    XCTAssertTrue(self.names(tree).contains("nested"), "入れ子のリポジトリは連なりにしない")
  }

  /// 根が git の作業ツリーでなければ、開いていないフォルダの中を読まず、連なりにしない。
  ///
  /// 先読みの結果は裏の直列の 1 本から main のキューへ届く。テストからその経路に目印を積めないので、1 秒の間、連なりに
  /// ならないことを見張る（先読みは数 ms で届く）。先読みの届け方を変えたら、先読みを git の外の根でも走らせるとこのテストが落ちることを
  /// 確かめ直す。
  func testTheLookaheadDoesNotReadFoldersUnderARootOutsideGit() throws {
    let plain = TestScratch.caseDir.appendingPathComponent(
      "orbe-plain-\(UUID().uuidString)", isDirectory: true)
    let root = GitWorktreeRoot.normalizedPath(plain.path)
    try repo.write("outer/inner/x.txt", "x\n", in: root)
    try repo.write("y.txt", "y\n", in: root)
    let tree = FileTree(root: root)
    tree.isLive = true
    pumpMain(until: { self.names(tree) == ["outer", "y.txt"] }, "前提: 根の一覧が出る")

    XCTAssertTrue(holds(for: 1) { self.names(tree) == ["outer", "y.txt"] }, "開いていないフォルダの中を読まない")
  }
}
