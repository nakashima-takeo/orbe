import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 文書と根のサービスの結線（実 git・実 FSEvents・本物のテキスト面）: 外で書き換えられたファイルが開いている
/// 文書へ反映され、未保存の文書は印が立って ⌘S が失敗し、baseline は文書に届く。
///
/// 壊れると何が起きるか。エージェントが書き換えたファイルが古いまま見える。⌘S がエージェントの編集を黙って潰す。
@MainActor
final class DocumentLinkTests: OrbeTestCase {
  private var repo: TempGitRepo!

  override func setUpWithError() throws {
    repo = try TempGitRepo()
  }

  override func tearDownWithError() throws {
    repo.cleanup()
  }

  private func session() -> EditorSession {
    EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
  }

  func testExternalWriteReplacesTheOpenDocument() throws {
    let session = session()
    let document = try session.open(repo.url("a.txt"))
    var changes = 0
    session.onChange = { changes += 1 }

    try repo.write("a.txt", "rewritten\n")
    pumpMain(until: { bodyText(document) == "rewritten\n" }, "監視で差し替わる")
    XCTAssertFalse(document.isDirty)
    XCTAssertFalse(document.isDiskChanged)
    XCTAssertEqual(changes, 0, "未保存も印も変わらないので通知しない")
    document.surface.responder.undoManager?.undo()
    XCTAssertEqual(bodyText(document), "one\n", "⌘Z で戻せる")
  }

  func testExternalWriteMarksADirtyDocumentAndSaveFailsUntilForced() throws {
    let session = session()
    let document = try session.open(repo.url("a.txt"))
    document.surface.responder.perform(Selector(("insertText:")), with: "mine ")
    var changes = 0
    session.onChange = { changes += 1 }

    try repo.write("a.txt", "theirs\n")
    pumpMain(until: { document.isDiskChanged }, "未保存なら印が立つ")
    XCTAssertEqual(bodyText(document), "mine one\n")
    XCTAssertEqual(changes, 1, "印の変化はセッションの通知に載る")
    XCTAssertThrowsError(try session.saveActive())
    XCTAssertEqual(try String(contentsOf: repo.url("a.txt"), encoding: .utf8), "theirs\n")

    try session.saveActive(force: true)
    XCTAssertEqual(try String(contentsOf: repo.url("a.txt"), encoding: .utf8), "mine one\n")
    XCTAssertFalse(document.isDiskChanged)
    pumpMain(
      until: { RootFiles.shared(for: repo.root).status?.badge(of: "a.txt") == .modified },
      "自分の保存も status には映る")
  }

  /// baseline は index 版で、同じファイルを 2 つのタブで開いて片方を閉じても残った方は追従し続ける。
  func testBaselineReachesTheDocumentAndSurvivesClosingTheOtherTab() throws {
    let first = session()
    let second = session()
    let url = repo.url("a.txt")
    let documentA = try first.open(url)
    let documentB = try second.open(url)
    pumpMain(until: { documentA.baseline == "one\n" && documentB.baseline == "one\n" }, "両方に届く")

    documentB.surface.responder.perform(Selector(("insertText:")), with: "x")
    pumpMain(
      until: { documentB.hunks == [LineHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1)] },
      "編集でハンク")

    first.close(documentA)
    try repo.write("a.txt", "two\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { documentB.baseline == "two\n" }, "残った方の baseline は追従する")
    pumpMain(until: { documentB.isDiskChanged }, "未保存なので印が立つ")
    XCTAssertEqual(bodyText(documentB), "xone\n")
    XCTAssertEqual(
      documentB.hunks, [LineHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1)],
      "新しい baseline との差分")
  }

  /// 根のサービスは開いている文書が握っている間だけ生きる。文書を全部閉じれば離され、監視も止まる。
  func testClosingAllDocumentsReleasesTheRootService() throws {
    let session = session()
    let documentA = try session.open(repo.url("a.txt"))
    try repo.write("b.txt", "b\n")
    let documentB = try session.open(repo.url("b.txt"))
    weak var files = RootFiles.shared(for: repo.root)
    XCTAssertNotNil(files)

    session.close(documentA)
    XCTAssertNotNil(files, "まだ b.txt が握っている")
    session.close(documentB)
    XCTAssertNil(files, "全部閉じれば離される")
  }

  /// 文書が属する根は文書の実体から解く（タブの根ではない）。管理外のファイルは baseline 無し。
  func testDocumentOutsideAnyRepositoryHasNoBaseline() throws {
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbe-outside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    let url = outside.appendingPathComponent("n.txt")
    try Data("n\n".utf8).write(to: url)
    let session = session()
    let document = try session.open(url)
    try Data("m\n".utf8).write(to: url)
    pumpMain(until: { bodyText(document) == "m\n" }, "管理外でも外部変更は反映する")
    XCTAssertNil(document.baseline)
    XCTAssertNil(RootFiles.shared(for: GitWorktreeRoot.normalizedPath(outside.path)).repo)
  }
}
