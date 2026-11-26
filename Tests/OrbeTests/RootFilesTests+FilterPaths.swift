import OrbeTestSupport
import XCTest

@testable import Orbe

/// 根のサービスが答える、ツリーの絞り込みの対象の一覧（実 git）——無視されているフォルダの中と既定の除外を除き、単独で
/// 無視されているファイルは含める。入れ子のリポジトリとサブモジュールの中にも同じ決まりを当て、git 管理外の根では既定の除外
/// だけが効く。
///
/// 壊れると何が起きるか。名前で絞り込んでも `.env` が見つからない。`node_modules` や無視したビルド成果物が結果を埋める。
/// サブモジュールの中のファイルが出ない。競合中のファイルや消したファイルの行が、重なって・残って出る。git 管理外の根では
/// 何も絞り込めない。
extension RootFilesTests {
  /// 判定が済むのを待ってから一覧を取り、返った一覧。
  private func filterPaths(of files: RootFiles) throws -> RootFiles.PathList {
    pumpMain(until: { files.isResolved }, "管理下かの判定")
    var list: RootFiles.PathList?
    files.listFilterPaths { list = $0 }
    pumpMain(until: { list != nil }, "一覧が返る")
    return try XCTUnwrap(list)
  }

  func testManagedRootListsEverythingButIgnoredFoldersAndDefaultExcludes() throws {
    try repo.write(".gitignore", "build/\n.env\n*.log\n")
    try repo.write("src/a.swift", "a\n")
    try repo.write("gone.txt", "g\n")
    try repo.write("c.txt", "base\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "base"]).isSuccess)
    try repo.addSubmodule("sub")
    // c.txt を競合させる（index に同じパスが 3 つのステージで並ぶ）。
    XCTAssertTrue(repo.git(["checkout", "-qb", "other"]).isSuccess)
    try repo.write("c.txt", "theirs\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "theirs"]).isSuccess)
    XCTAssertTrue(repo.git(["checkout", "-q", "main"]).isSuccess)
    try repo.write("c.txt", "ours\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "ours"]).isSuccess)
    XCTAssertFalse(repo.git(["merge", "-q", "other"]).isSuccess, "前提: 競合する")
    try FileManager.default.removeItem(atPath: repo.root + "/gone.txt")
    try repo.write("new.txt", "n\n")
    try repo.write("build/out.o", "o\n")
    try repo.write(".env", "e\n")
    try repo.write("src/debug.log", "l\n")
    try repo.write("node_modules/pkg/index.js", "j\n")
    try repo.write("src/.DS_Store", "d\n")
    XCTAssertTrue(repo.git(["init", "-q", "vendor/lib"]).isSuccess)
    try repo.write("vendor/lib/.gitignore", "tmp/\n*.env\n")
    try repo.write("vendor/lib/lib.c", "c\n")
    try repo.write("vendor/lib/key.env", "k\n")
    try repo.write("vendor/lib/tmp/cache.bin", "b\n")
    XCTAssertTrue(repo.git(["-C", "vendor/lib", "add", "lib.c"]).isSuccess)

    let list = try filterPaths(of: repo.files())

    guard case .listed(let paths, let isTruncated) = list else {
      return XCTFail("取れた一覧が返る: \(list)")
    }
    XCTAssertEqual(
      paths.sorted(),
      [
        ".env", ".gitignore", ".gitmodules", "a.txt", "c.txt", "new.txt", "src/a.swift",
        "src/debug.log", "sub/t.txt", "vendor/lib/.gitignore", "vendor/lib/key.env",
        "vendor/lib/lib.c",
      ],
      "無視されているフォルダの中・既定の除外・消した追跡ファイル・サブモジュールの行は出ず、競合中のファイルは 1 つ")
    XCTAssertFalse(isTruncated)
  }

  /// git 管理外の根はディスクを走査し、既定の除外だけが効く（`.gitignore` は効かない）。中で `.git` を持つフォルダには git の
  /// 決まりを当て、git が失敗する（壊れた `.git`）フォルダは走査する。
  func testUnmanagedRootListsEverythingButDefaultExcludes() throws {
    let plain = TestScratch.caseDir.appendingPathComponent(
      "orbe-plain-\(UUID().uuidString)", isDirectory: true)
    let root = GitWorktreeRoot.normalizedPath(plain.path)
    for (path, text) in [
      (".gitignore", "*.log\n"), ("x.log", "l\n"), ("docs/readme.md", "r\n"),
      ("node_modules/m.js", "m\n"), (".DS_Store", "d\n"), ("inner/.gitignore", "gen/\n"),
      ("inner/src.c", "c\n"), ("inner/gen/g.txt", "g\n"), ("broken/f.txt", "f\n"),
    ] {
      try repo.write(path, text, in: root)
    }
    XCTAssertTrue(repo.git(["init", "-q", "inner"], in: root).isSuccess)
    try repo.write("broken/.git", "gitdir: /nonexistent/orbe/.git\n", in: root)

    let list = try filterPaths(of: RootFiles(root: root))

    guard case .listed(let paths, _) = list else { return XCTFail("取れた一覧が返る: \(list)") }
    XCTAssertEqual(
      paths.filter { ($0 as NSString).lastPathComponent != ".git" }.sorted(),
      [
        ".gitignore", "broken/f.txt", "docs/readme.md", "inner/.gitignore", "inner/src.c",
        "x.log",
      ])
    XCTAssertFalse(paths.contains("broken/.git"), "絞り込まないツリーと同じく `.git` は出ない")
  }
}
