import OrbeTestSupport
import XCTest

@testable import Orbe

/// 根のサービスが答える、ツリーの絞り込みの対象の一覧（実 git）——無視されているフォルダの中と既定の除外を除き、単独で
/// 無視されているファイルは含める。入れ子のリポジトリとサブモジュールの中は、その `.git` の設定・index・オブジェクトを読まずに、
/// 作業ツリーの上のファイルと `.gitignore` の規則で集める。git 管理外の根では既定の除外だけが効く。sparse checkout でディスクに
/// 無いファイルは含めない。
///
/// 壊れると何が起きるか。名前で絞り込んでも `.env` が見つからない。`node_modules` や無視したビルド成果物が結果を埋める。
/// サブモジュールの中のファイルが出ない。競合中のファイルや消したファイルの行が、重なって・残って出る。git 管理外の根では
/// 何も絞り込めない。sparse checkout の範囲外の、開けないファイルが結果に出る。根の下に置かれただけのリポジトリの設定の
/// コマンドが、字を打つだけで利用者の権限で走る。入れ子のリポジトリの設定が指す、根の外の場所が読まれる。
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
      paths.sorted(),
      [
        ".gitignore", "broken/f.txt", "docs/readme.md", "inner/.gitignore", "inner/src.c",
        "x.log",
      ])
    XCTAssertFalse(paths.contains("broken/.git"), "絞り込まないツリーと同じく `.git` は出ない")
  }

  /// skip-worktree のファイル（sparse checkout の範囲外など）は、ディスクに無ければ出ず、ディスクに在れば出る。
  func testSkipWorktreeFilesAreListedOnlyWhileTheyAreOnDisk() throws {
    try repo.write("kept/x.txt", "x\n")
    try repo.write("hidden/y.txt", "y\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "two folders"]).isSuccess)
    // sparse checkout の範囲外と同じ形（skip-worktree で、ディスクに無い）と、ディスクに在る skip-worktree のファイル。
    XCTAssertTrue(
      repo.git(["update-index", "--skip-worktree", "kept/x.txt", "hidden/y.txt"]).isSuccess)
    try FileManager.default.removeItem(atPath: repo.root + "/hidden/y.txt")
    XCTAssertEqual(
      repo.git(["ls-files", "-t", "kept/x.txt", "hidden/y.txt"]).stdoutText,
      "S hidden/y.txt\nS kept/x.txt\n", "前提: どちらも skip-worktree")

    let list = try filterPaths(of: repo.files())

    guard case .listed(let paths, _) = list else { return XCTFail("取れた一覧が返る: \(list)") }
    XCTAssertEqual(paths.sorted(), ["a.txt", "kept/x.txt"])
  }

  /// 入れ子のリポジトリ `lib` を作り、`files` をディスクに置いて、`tracked` を commit する。
  private func nestedRepository(_ lib: String, files: [String: String], tracked: [String]) throws {
    XCTAssertTrue(repo.git(["init", "-q", "-b", "main", lib]).isSuccess)
    for (path, text) in files { try repo.write(lib + "/" + path, text) }
    let commit = ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-qm", "c"]
    XCTAssertTrue(repo.git(["-C", lib, "add", "-f"] + tracked).isSuccess)
    XCTAssertTrue(repo.git(["-C", lib] + commit).isSuccess)
  }

  /// 使い捨てのディレクトリに目印のファイルを作るだけの、罠のコマンド（実行できるスクリプト）。目印のパスと、スクリプトのパス。
  private func trapCommand() throws -> (marker: String, script: String) {
    let marker = TestScratch.caseDir.appendingPathComponent("trap-ran-\(UUID().uuidString)").path
    let script = TestScratch.caseDir.appendingPathComponent("trap-\(UUID().uuidString).sh").path
    try Data("#!/bin/sh\ntouch '\(marker)'\nexit 1\n".utf8).write(to: URL(fileURLWithPath: script))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
    return (marker, script)
  }

  /// 入れ子のリポジトリの `.git` が走らせるコマンド（設定の `core.fsmonitor`、partial clone の取得元へつなぐ `core.sshCommand`）
  /// は、一覧を取っても走らない。
  func testListingRunsNoCommandFromANestedRepositorysGitDirectory() throws {
    // vendor/watched: 設定の core.fsmonitor が罠のコマンド。
    let fsmonitor = try trapCommand()
    try nestedRepository("vendor/watched", files: ["w.c": "w\n"], tracked: ["w.c"])
    XCTAssertTrue(
      repo.git(["-C", "vendor/watched", "config", "core.fsmonitor", fsmonitor.script]).isSuccess)
    // vendor/lazy: sparse index の範囲外の tree が無く、partial clone の取得元へつなぐコマンドが罠のコマンド（取得元の名前は
    // 解決できない宛先で、罠のコマンドが先に失敗して終わる）。
    let ssh = try trapCommand()
    try nestedRepository(
      "vendor/lazy", files: ["big/a.txt": "a\n", "small/b.txt": "b\n"], tracked: ["big", "small"])
    for args in [
      ["sparse-checkout", "init", "--cone", "--sparse-index"], ["sparse-checkout", "set", "small"],
    ] {
      XCTAssertTrue(repo.git(["-C", "vendor/lazy"] + args).isSuccess, "\(args)")
    }
    let big = repo.git(["-C", "vendor/lazy", "rev-parse", "HEAD:big"]).stdoutText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try FileManager.default.removeItem(
      atPath: repo.root + "/vendor/lazy/.git/objects/\(big.prefix(2))/\(big.dropFirst(2))")
    for (key, value) in [
      ("core.repositoryformatversion", "1"), ("extensions.partialClone", "origin"),
      ("remote.origin.url", "ssh://example.invalid/x"), ("remote.origin.promisor", "true"),
      ("core.sshCommand", ssh.script),
    ] {
      XCTAssertTrue(repo.git(["-C", "vendor/lazy", "config", key, value]).isSuccess, key)
    }
    for (lib, trap) in [("vendor/watched", fsmonitor), ("vendor/lazy", ssh)] {
      _ = repo.git(["-C", lib, "ls-files"])
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: trap.marker), "前提: 素の ls-files は、\(lib) の罠のコマンドを走らせる"
      )
      try FileManager.default.removeItem(atPath: trap.marker)
    }

    let list = try filterPaths(of: repo.files())

    guard case .listed(let paths, _) = list else { return XCTFail("取れた一覧が返る: \(list)") }
    XCTAssertTrue(
      paths.contains("vendor/watched/w.c") && paths.contains("vendor/lazy/small/b.txt"),
      "前提: 2 つの入れ子のリポジトリの中を一覧に取った: \(paths)")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fsmonitor.marker), "core.fsmonitor は走らない")
    XCTAssertFalse(FileManager.default.fileExists(atPath: ssh.marker), "core.sshCommand は走らない")
  }

  /// 入れ子のリポジトリの `.git` の中身（index・`info/exclude`・設定、`.git` のファイルが指す根の外の git のディレクトリ）は、
  /// 一覧を変えない——一覧はディスクの上のファイルと `.gitignore` の規則だけで決まる。
  func testANestedRepositorysGitDirectoryDoesNotChangeTheList() throws {
    let outside = TestScratch.caseDir.appendingPathComponent(
      "orbe-outside-\(UUID().uuidString)", isDirectory: true)
    try repo.write("excludes", "hidden/\n", in: outside.path)
    // vendor/lib: index に、無視されたフォルダの中のファイルを無理に追跡させ、info/exclude と、設定の core.excludesFile（根の
    // 外のファイル）で、ディスクの上のファイルを除く。
    try nestedRepository(
      "vendor/lib",
      files: [
        ".gitignore": "gen/\n", "lib.c": "c\n", "gen/forced.c": "f\n", "secret.txt": "s\n",
        "hidden/x.txt": "x\n",
      ],
      tracked: [".gitignore", "lib.c", "gen/forced.c"])
    try repo.write("vendor/lib/.git/info/exclude", "secret.txt\n")
    XCTAssertTrue(
      repo.git(["-C", "vendor/lib", "config", "core.excludesFile", outside.path + "/excludes"])
        .isSuccess)
    // vendor/linked: `.git` のファイルが、根の外の git のディレクトリ（info/exclude で hidden/ を除く）を指す。
    XCTAssertTrue(repo.git(["init", "-q", outside.path + "/real"]).isSuccess)
    try repo.write("real/.git/info/exclude", "hidden/\n", in: outside.path)
    try repo.write("vendor/linked/hidden/y.txt", "y\n")
    try repo.write("vendor/linked/.git", "gitdir: \(outside.path)/real/.git\n")
    XCTAssertTrue(
      repo.git(["-C", "vendor/lib", "ls-files", "-c"]).stdoutText.contains("gen/forced.c"),
      "前提: 入れ子の index は、無視されたフォルダの中のファイルを追跡している")
    XCTAssertEqual(
      repo.git(["-C", "vendor/lib", "ls-files", "-o", "--exclude-standard"]).stdoutText, "",
      "前提: 入れ子の info/exclude と設定の core.excludesFile は、secret.txt と hidden/ を除く")
    XCTAssertEqual(
      repo.git(["-C", "vendor/linked", "ls-files", "-o", "--exclude-standard"]).stdoutText, "",
      "前提: `.git` のファイルが指す git のディレクトリの info/exclude は、hidden/ を除く")

    let list = try filterPaths(of: repo.files())

    guard case .listed(let paths, _) = list else { return XCTFail("取れた一覧が返る: \(list)") }
    XCTAssertEqual(
      paths.sorted(),
      [
        "a.txt", "vendor/lib/.gitignore", "vendor/lib/hidden/x.txt", "vendor/lib/lib.c",
        "vendor/lib/secret.txt", "vendor/linked/hidden/y.txt",
      ],
      "一覧に、無視されたフォルダの中の追跡しているファイルは出ず、入れ子の .git の除外は効かない")
  }
}
