import XCTest

@testable import Orbe

extension RootFilesWritesTests {
  /// 追跡中のパスの場所を塞いでいる未追跡のもの——同じ名前のディレクトリ・入れ子のリポジトリ（コミットの有無に依らず）・
  /// ファイルに置き換えた親の階層——は、破棄で戻す前にゴミ箱へ移す（git の restore は黙って消す）。塞いでいる親の行も
  /// 一緒に破棄すると（すべて破棄）、戻したディレクトリを未追跡の行としてゴミ箱へ移し直さない。
  func testDiscardMovesWhatBlocksATrackedPathToTheTrashBeforeRestoring() throws {
    for path in ["p.txt", "q.txt", "r.txt", "d/x"] { try repo.write(path, "\(path)\n") }
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "tracked"]).isSuccess)
    for path in ["p.txt", "q.txt", "r.txt", "d"] {
      try FileManager.default.removeItem(atPath: repo.root + "/" + path)
    }
    try repo.write("p.txt/inside", "untracked inside\n")
    try repo.write("q.txt/inside", "nested with a commit\n")
    let identity = ["-c", "user.email=t@example.com", "-c", "user.name=t"]
    for args in [["init", "-q"], ["add", "inside"], identity + ["commit", "-qm", "nested"]] {
      XCTAssertTrue(repo.git(args, in: repo.root + "/q.txt").isSuccess, "\(args)")
    }
    try repo.write("r.txt/inside", "nested without a commit\n")
    XCTAssertTrue(repo.git(["init", "-q"], in: repo.root + "/r.txt").isSuccess)
    try repo.write("d", "a file where the directory was\n")
    let files = repo.files()

    let rows = ["p.txt", "q.txt", "r.txt", "d/x", "d"].map {
      GitStatus.Row(path: $0, originalPath: nil)
    }
    let discarded = finish(files) { files.discard(rows, completion: $0) }
    XCTAssertNil(discarded.failure)
    for path in ["p.txt", "q.txt", "r.txt", "d/x"] {
      XCTAssertEqual(
        try String(contentsOfFile: repo.root + "/" + path, encoding: .utf8), "\(path)\n", path)
    }
    let trash = try XCTUnwrap(GitRepo.trashDirectoryOverride)
    let trashed = { (path: String) in
      try String(contentsOf: trash.appendingPathComponent(path), encoding: .utf8)
    }
    XCTAssertEqual(try trashed("p.txt/inside"), "untracked inside\n")
    XCTAssertEqual(try trashed("q.txt/inside"), "nested with a commit\n")
    XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path + "/q.txt/.git"), "履歴ごと")
    XCTAssertEqual(try trashed("r.txt/inside"), "nested without a commit\n")
    XCTAssertEqual(try trashed("d"), "a file where the directory was\n")
  }

  /// 大文字小文字を区別しないボリューム（macOS の既定）で、消した追跡中のディレクトリ `D` の場所に小文字のファイル `d` を
  /// 置き、その両方を破棄すると、`d` をゴミ箱へ移して `D/x` を戻す——戻した `D/` を、名前の当たる `d` として移し直さない。
  func testDiscardRestoresADirectoryNamedLikeAnUntrackedFileUpToCase() throws {
    try repo.write("D/x", "tracked\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "tracked"]).isSuccess)
    try FileManager.default.removeItem(atPath: repo.root + "/D")
    try repo.write("d", "a file where the directory was\n")
    guard FileManager.default.fileExists(atPath: repo.root + "/D") else {
      throw XCTSkip("大文字小文字を区別するボリューム")
    }
    let files = repo.files()

    let rows = ["D/x", "d"].map { GitStatus.Row(path: $0, originalPath: nil) }
    let discarded = finish(files) { files.discard(rows, completion: $0) }
    XCTAssertNil(discarded.failure)
    XCTAssertEqual(try String(contentsOfFile: repo.root + "/D/x", encoding: .utf8), "tracked\n")
    let trash = try XCTUnwrap(GitRepo.trashDirectoryOverride)
    XCTAssertEqual(
      try String(contentsOf: trash.appendingPathComponent("d"), encoding: .utf8),
      "a file where the directory was\n")
  }

  /// 同じ場面で `d` が intent-to-add（`git add -N`）でも、`d` を index から外してゴミ箱へ移し、`D/x` を戻す——戻した `D/` を
  /// 移し直さない。
  func testDiscardRestoresADirectoryNamedLikeAnIntentToAddFileUpToCase() throws {
    try repo.write("D/x", "tracked\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "tracked"]).isSuccess)
    try FileManager.default.removeItem(atPath: repo.root + "/D")
    try repo.write("d", "a file where the directory was\n")
    guard FileManager.default.fileExists(atPath: repo.root + "/D") else {
      throw XCTSkip("大文字小文字を区別するボリューム")
    }
    XCTAssertTrue(repo.git(["add", "-N", "d"]).isSuccess)
    let files = repo.files()

    let rows = ["D/x", "d"].map { GitStatus.Row(path: $0, originalPath: nil) }
    let discarded = finish(files) { files.discard(rows, completion: $0) }
    XCTAssertNil(discarded.failure)
    XCTAssertEqual(try String(contentsOfFile: repo.root + "/D/x", encoding: .utf8), "tracked\n")
    XCTAssertFalse(
      repo.git(["ls-files"]).stdoutText.split(separator: "\n").contains("d"), "d は index から外れる")
    let trash = try XCTUnwrap(GitRepo.trashDirectoryOverride)
    XCTAssertEqual(
      try String(contentsOf: trash.appendingPathComponent("d"), encoding: .utf8),
      "a file where the directory was\n")
  }
}
