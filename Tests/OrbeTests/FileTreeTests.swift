import XCTest

@testable import Orbe

/// エクスプローラーのツリー（実ファイル・実 git・実 FSEvents）: 見えている間だけ根のサービスを握り、展開した
/// ディレクトリだけを取り、変化を追い、status を最後に成功したもので保ち、祖先を開いて選択し、行内の新規作成が
/// ファイルを作って開く。
///
/// 壊れると何が起きるか。隠れたタブのツリーが監視を握り続けると全タブの根を常時監視する。握り直しで status を
/// 写すとバッジが毎回消えて戻る。消えたディレクトリを畳まないと無いものが展開されたまま残る。
@MainActor
final class FileTreeTests: OrbeTestCase {
  private var repo: TempGitRepo!

  override func setUpWithError() throws {
    repo = try TempGitRepo()
    try repo.write("src/main.swift", "let a = 1\n")
    try repo.write("src/sub/deep.md", "# d\n")
    try repo.write("docs/readme.md", "# r\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "tree"]).isSuccess)
  }

  override func tearDownWithError() throws {
    repo.cleanup()
  }

  /// 名前を打って Enter。
  private func commit(_ tree: FileTree, _ name: String) -> Bool {
    tree.setNewName(name)
    return tree.commitNew()
  }

  private func names(_ tree: FileTree) -> [String] {
    tree.rows.map { String(repeating: "  ", count: $0.depth) + $0.name }
  }

  func testLiveTreeListsTheRootAndExpandsDirectoriesLazily() {
    let tree = FileTree(root: repo.root)
    XCTAssertTrue(tree.rows.isEmpty, "握る前は空")

    tree.isLive = true
    XCTAssertEqual(names(tree), ["docs", "src", "a.txt"], "根だけ。ディレクトリが先、あとは名前順")
    XCTAssertEqual(tree.rootName, (repo.root as NSString).lastPathComponent.uppercased())

    tree.toggle("src")
    XCTAssertEqual(names(tree), ["docs", "src", "  sub", "  main.swift", "a.txt"], "展開した階層だけ取る")
    XCTAssertNil(tree.entries["src/sub"], "開いていない配下は読まない")
    XCTAssertEqual(tree.selected, "src", "ディレクトリの開閉はその行を選択表示する")

    tree.toggle("src")
    XCTAssertEqual(names(tree), ["docs", "src", "a.txt"])
    XCTAssertNil(tree.entries["src"], "畳めば一覧も捨てる")
  }

  func testBadgesFollowGitAndNamesOfDirectoriesCarryNone() throws {
    let tree = FileTree(root: repo.root)
    tree.isLive = true
    try repo.write("a.txt", "changed\n")
    try repo.write("src/new.swift", "x\n")
    pumpMain(until: { tree.status?.badge(of: "a.txt") == .modified }, "外部の編集で M")
    XCTAssertTrue(repo.git(["add", "src/new.swift"]).isSuccess)
    pumpMain(until: { tree.status?.badge(of: "src/new.swift") == .added }, "git add で A")

    tree.toggle("src")
    let badges = Dictionary(
      uniqueKeysWithValues: tree.rows.map { row -> (String, GitStatus.Badge?) in
        if case .file(let badge) = row.kind { return (row.id, badge) }
        return (row.id, nil)
      })
    XCTAssertEqual(badges["a.txt"], .modified)
    XCTAssertEqual(badges["src/new.swift"], .added)
    XCTAssertNil(badges["src"] ?? nil, "ディレクトリ行はバッジを持たない")
  }

  func testStatusSurvivesReleasingAndRetakingTheService() throws {
    let tree = FileTree(root: repo.root)
    tree.isLive = true
    try repo.write("a.txt", "changed\n")
    pumpMain(until: { tree.status?.badge(of: "a.txt") == .modified })

    tree.isLive = false
    XCTAssertEqual(tree.status?.badge(of: "a.txt"), .modified, "離しても status のキャッシュは保つ")
    XCTAssertEqual(names(tree), ["docs", "src", "a.txt"], "一覧のキャッシュも保つ")

    tree.isLive = true
    XCTAssertEqual(tree.status?.badge(of: "a.txt"), .modified, "握り直した直後（新しいサービスの status は nil）も保つ")
  }

  func testChangesUnderExpandedDirectoriesAreFollowedAndVanishedDirectoriesCollapse() throws {
    let tree = FileTree(root: repo.root)
    tree.isLive = true
    tree.toggle("src")
    tree.toggle("src/sub")
    XCTAssertTrue(tree.expanded.contains("src/sub"))

    try repo.write("src/added.swift", "y\n")
    pumpMain(until: { tree.rows.contains { $0.id == "src/added.swift" } }, "展開中のディレクトリへの追加")

    try FileManager.default.removeItem(atPath: repo.root + "/src/sub")
    pumpMain(until: { !tree.expanded.contains("src/sub") }, "消えた展開中のディレクトリは畳む")
    XCTAssertNil(tree.entries["src/sub"])
    XCTAssertFalse(tree.rows.contains { $0.id == "src/sub" })

    try repo.write("docs/inner/x.txt", "x\n")
    try repo.write("src/marker.txt", "m\n")
    pumpMain(until: { tree.rows.contains { $0.id == "src/marker.txt" } }, "同じバッチの配達")
    XCTAssertNil(tree.entries["docs"], "展開していないディレクトリは取り直さない")
  }

  /// 離せば根のサービスは解放され（強参照は `files` だけ）、以後の変化は届かない。
  func testReleasingTheServiceFreesItAndStopsDelivery() throws {
    let tree = FileTree(root: repo.root)
    tree.isLive = true
    tree.toggle("src")
    weak var service = RootFiles.shared(for: repo.root)
    XCTAssertNotNil(service, "前提: 握っている間は生きている")

    tree.isLive = false
    pumpMain(until: { service == nil }, "離せば解放される（握り続けると全タブの根を常時監視する）")

    let witness = FileTree(root: repo.root)  // 配達の目印を待つ立会人（同じ根を握り直す）
    witness.isLive = true
    witness.toggle("src")
    try repo.write("src/after.txt", "a\n")
    pumpMain(until: { witness.rows.contains { $0.id == "src/after.txt" } }, "目印の配達")
    XCTAssertFalse(tree.rows.contains { $0.id == "src/after.txt" }, "離したツリーには届かない")
    XCTAssertEqual(names(tree), ["docs", "src", "  sub", "  main.swift", "a.txt"], "キャッシュは保つ")
  }

  /// 読めないディレクトリは空として扱い、展開しようとしても畳んだまま。
  func testUnreadableDirectoryStaysCollapsed() throws {
    let locked = repo.root + "/docs"
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
    }
    let tree = FileTree(root: repo.root)
    tree.isLive = true

    tree.toggle("docs")

    XCTAssertFalse(tree.expanded.contains("docs"))
    XCTAssertNil(tree.entries["docs"])
    XCTAssertEqual(names(tree), ["docs", "src", "a.txt"], "行は閉じたまま残る")
  }

  func testRevealOpensAncestorsAndSelectsTheFile() {
    let tree = FileTree(root: repo.root)
    tree.reveal(repo.url("src/sub/deep.md"))
    XCTAssertEqual(tree.expanded, ["src", "src/sub"], "握る前でも展開集合には入る")
    XCTAssertEqual(tree.selected, "src/sub/deep.md")

    tree.isLive = true
    XCTAssertEqual(
      names(tree), ["docs", "src", "  sub", "    deep.md", "  main.swift", "a.txt"], "握った瞬間に展開中が揃う")
    XCTAssertTrue(tree.rows.first { $0.id == "src/sub/deep.md" }?.isSelected ?? false)

    tree.reveal(URL(fileURLWithPath: "/etc/hosts"))
    XCTAssertNil(tree.selected, "根の外は選択を外す")

    tree.revealDirectory(repo.url("docs"))
    XCTAssertTrue(tree.expanded.contains("docs"))
    XCTAssertEqual(tree.selected, "docs")

    tree.collapseAll()
    XCTAssertEqual(names(tree), ["docs", "src", "a.txt"], "根は開いたまま全部畳む")
  }

  /// 挿し先（かその祖先）を畳めば入力行は画面から消えるので、入力も終わる（他のディレクトリを畳んでも残る）。
  func testCollapsingTheTargetDirectoryEndsTheInput() {
    let tree = FileTree(root: repo.root)
    tree.isLive = true
    var ended = 0
    tree.onInputEnded = { ended += 1 }
    tree.toggle("src")
    tree.toggle("src/sub")
    tree.beginNew(isDirectory: false)
    XCTAssertEqual(tree.newEntry?.directory, "src/sub")

    tree.toggle("docs")
    tree.toggle("docs")
    XCTAssertNotNil(tree.newEntry, "無関係のディレクトリを畳んでも残る")
    XCTAssertEqual(ended, 0)

    tree.toggle("src")
    XCTAssertNil(tree.newEntry, "祖先を畳めば終わる")
    XCTAssertEqual(ended, 1, "終わりは 1 回")
  }

  /// 選択の種別は選ばせた側が持つ——すべて畳んで親の一覧が無くなっても、深いディレクトリの選択はそこへ挿す。
  func testNewEntryGoesIntoTheSelectedDirectoryEvenAfterCollapsingAll() {
    let tree = FileTree(root: repo.root)
    tree.isLive = true
    tree.toggle("src")
    tree.toggle("src/sub")
    tree.collapseAll()
    XCTAssertNil(tree.entries["src"], "前提: 親の一覧は無い")

    tree.beginNew(isDirectory: true)
    XCTAssertEqual(tree.newEntry?.directory, "src/sub", "選択したディレクトリに挿す（その親ではない）")
    XCTAssertEqual(tree.expanded, ["src", "src/sub"], "挿し先まで開き直す")
  }

  func testInlineCreationMakesTheEntryAndOpensFiles() throws {
    let tree = FileTree(root: repo.root)
    tree.isLive = true
    var created: [URL] = []
    tree.onCreated = { created.append($0) }
    tree.reveal(repo.url("src/main.swift"))

    tree.beginNew(isDirectory: false)
    XCTAssertEqual(tree.newEntry?.directory, "src", "ファイルの選択はその親へ")
    XCTAssertEqual(tree.newEntry?.isDirectory, false)
    XCTAssertEqual(tree.rows.first(where: \.isInput)?.depth, 1, "入力行は親の子の先頭")
    XCTAssertEqual(tree.rows.firstIndex(where: \.isInput), 2, "docs・src の次")

    XCTAssertFalse(commit(tree, "main.swift"), "既に在れば入力に留まる")
    XCTAssertNotNil(tree.newEntry)
    XCTAssertFalse(commit(tree, " "), "空は無効")
    XCTAssertFalse(commit(tree, "nested/x.swift"), "`/` 入りは無効（中間ディレクトリは作らない）")
    XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root + "/src/nested"))
    XCTAssertNotNil(tree.newEntry)

    XCTAssertTrue(commit(tree, "fresh.swift"))
    XCTAssertNil(tree.newEntry)
    XCTAssertTrue(FileManager.default.fileExists(atPath: repo.root + "/src/fresh.swift"))
    XCTAssertEqual(created, [repo.url("src/fresh.swift")], "ファイルは開く")
    XCTAssertTrue(tree.rows.contains { $0.id == "src/fresh.swift" }, "作った直後に親を取り直す")

    tree.toggle("docs")
    tree.beginNew(isDirectory: true)
    XCTAssertEqual(tree.newEntry?.directory, "docs", "ディレクトリの選択はそこへ")
    XCTAssertEqual(tree.newEntry?.isDirectory, true)
    XCTAssertTrue(commit(tree, "guides"))
    XCTAssertTrue(
      tree.rows.contains { $0.id == "docs/guides" && $0.kind == .directory(isExpanded: false) })
    XCTAssertEqual(created.count, 1, "フォルダは開かない")

    tree.beginNew(isDirectory: false)
    let first = try XCTUnwrap(tree.newEntry)
    tree.beginNew(isDirectory: true)
    let second = try XCTUnwrap(tree.newEntry)
    XCTAssertNotEqual(first.generation, second.generation, "出すたびに世代が進む（行の同一性が変わる）")
    XCTAssertNotEqual(
      FileTree.inputRowID(first), FileTree.inputRowID(second), "同じ挿し先でも別の行")
    XCTAssertEqual(tree.rows.filter(\.isInput).count, 1, "入力行は 1 つだけ")
    tree.cancelNew(first.generation)
    XCTAssertNotNil(tree.newEntry, "古い世代の取り消しは今の入力に触れない")
    tree.cancelNew(second.generation)
    XCTAssertNil(tree.newEntry)
  }
}

extension FileTree.Row {
  fileprivate var isInput: Bool {
    if case .input = kind { return true }
    return false
  }
}
