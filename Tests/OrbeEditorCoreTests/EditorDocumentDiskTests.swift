import Foundation
import XCTest

@testable import OrbeEditorCore

/// 文書とディスク・baseline——外で書き換えられたファイルの差し替えと印、⌘S の失敗と force、ハンクの追従。
/// 壊れると外部の編集が古いまま見える、⌘S がエージェントの編集を黙って潰す、ガターの差分が違う行に出る。
@MainActor
final class EditorDocumentDiskTests: XCTestCase {
  private let registry = LanguageRegistry(queriesRoot: Queries.root)
  private var root: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-disk-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
    try super.tearDownWithError()
  }

  private func temp(_ name: String, _ text: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
  }

  private func open(_ url: URL) throws -> (EditorDocument, FakeTextSurface) {
    let surface = FakeTextSurface(text: try EditorDocument.read(url))
    return (EditorDocument(url: url, surface: surface, registry: registry), surface)
  }

  // MARK: - 外部変更

  /// 未保存でない文書は、外で書き換えられた内容に本文が差し替わる——未保存にならず、⌘Z で戻せる区切りになる。
  func testExternalChangeReplacesACleanDocument() throws {
    let url = try temp("a.txt", "old\n")
    let (document, surface) = try open(url)
    var diskChanges: [Bool] = []
    document.onDiskChange = { diskChanges.append($0) }

    try Data("new\n".utf8).write(to: url)
    document.reconcileWithDisk()
    XCTAssertEqual(surface.text, "new\n")
    XCTAssertFalse(document.isDirty, "差し替えは未保存にしない")
    XCTAssertFalse(document.isDiskChanged)
    XCTAssertEqual(diskChanges, [], "印は立たない")
    XCTAssertEqual(surface.undoBoundaries, 1, "差し替えは undo の区切り")
    XCTAssertEqual(document.lineIndex, LineIndex(text: "new\n"), "索引は差し替えに追従する")

    document.reconcileWithDisk()
    XCTAssertEqual(surface.undoBoundaries, 1, "同じ内容なら何もしない")
  }

  /// 未保存の文書は本文を保って印を立て、⌘S は失敗してディスクに触れない。force だけが上書きする。
  func testExternalChangeMarksADirtyDocumentAndBlocksSave() throws {
    let url = try temp("b.txt", "old\n")
    let (document, surface) = try open(url)
    surface.replace(NSRange(location: 0, length: 0), with: "mine ")
    var diskChanges: [Bool] = []
    document.onDiskChange = { diskChanges.append($0) }

    try Data("theirs\n".utf8).write(to: url)
    document.reconcileWithDisk()
    XCTAssertEqual(surface.text, "mine old\n", "本文はそのまま")
    XCTAssertTrue(document.isDiskChanged)
    XCTAssertEqual(diskChanges, [true])

    XCTAssertThrowsError(try document.save()) { error in
      XCTAssertEqual(error as? EditorDocumentError, .diskChanged(url))
    }
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "theirs\n", "ディスクは変わらない")
    XCTAssertTrue(document.isDirty)

    try document.save(force: true)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "mine old\n")
    XCTAssertFalse(document.isDiskChanged)
    XCTAssertFalse(document.isDirty)
    XCTAssertEqual(diskChanges, [true, false])
  }

  /// 監視が届く前の ⌘S でもディスクを読み直して同じ判定をする。外のツールが元に戻せば印は消える。
  func testSaveChecksTheDiskWithoutWaitingForAWatcherAndTheMarkClearsWhenRestored() throws {
    let url = try temp("c.txt", "old\n")
    let (document, surface) = try open(url)
    surface.replace(NSRange(location: 0, length: 0), with: "x")

    try Data("theirs\n".utf8).write(to: url)
    XCTAssertFalse(document.isDiskChanged, "まだ照合していない")
    XCTAssertThrowsError(try document.save())
    XCTAssertTrue(document.isDiskChanged, "保存の直前の照合で印が立つ")

    try Data("old\n".utf8).write(to: url)
    document.reconcileWithDisk()
    XCTAssertFalse(document.isDiskChanged, "元の内容に戻れば印は消える")
    try document.save()
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "xold\n")
  }

  /// 同じ内容の書き直しと自分の保存は外部変更にならない。ファイルが消えていれば印は立たず ⌘S で作り直す。
  func testSameContentOwnSaveAndDeletionAreNotExternalChanges() throws {
    let url = try temp("d.txt", "same\n")
    let (document, surface) = try open(url)
    try Data("same\n".utf8).write(to: url)
    document.reconcileWithDisk()
    XCTAssertFalse(document.isDiskChanged)
    XCTAssertEqual(surface.undoBoundaries, 0, "同じ内容なら差し替えない")

    surface.replace(NSRange(location: 0, length: 0), with: "a")
    try document.save()
    document.reconcileWithDisk()
    XCTAssertFalse(document.isDiskChanged, "自分の保存は外部変更ではない")
    XCTAssertEqual(surface.text, "asame\n")

    surface.replace(NSRange(location: 0, length: 0), with: "b")
    try FileManager.default.removeItem(at: url)
    document.reconcileWithDisk()
    XCTAssertFalse(document.isDiskChanged, "消えていれば印は立たない")
    try document.save()
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "basame\n", "作り直す")
  }

  // MARK: - ハンク

  /// baseline を置けば即時にハンクが出て、編集は runloop 1 回に間引いて作り直す。baseline を外せば空。
  func testHunksFollowTheBaselineImmediatelyAndEditsAfterOneRunLoopTurn() throws {
    let (document, surface) = try open(try temp("e.txt", "a\nb\nc\n"))
    XCTAssertEqual(document.hunks, [])
    var notified = 0
    document.onHunksChange = { notified += 1 }

    document.baseline = "a\nc\n"
    XCTAssertEqual(
      document.hunks, [LineHunk(oldStart: 1, oldCount: 0, newStart: 2, newCount: 1)], "置いた瞬間に出る")
    XCTAssertEqual(notified, 1)

    surface.replace(NSRange(location: 0, length: 1), with: "A")
    surface.replace(NSRange(location: 6, length: 0), with: "d\n")
    XCTAssertEqual(document.hunks.count, 1, "編集の直後はまだ作り直していない")
    pumpMain(until: { document.hunks.count == 2 })
    XCTAssertEqual(
      document.hunks,
      [
        LineHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 2),
        LineHunk(oldStart: 2, oldCount: 0, newStart: 4, newCount: 1),
      ])
    XCTAssertEqual(notified, 2, "2 回の編集で作り直しは 1 回")

    document.baseline = nil
    XCTAssertEqual(document.hunks, [])
    XCTAssertEqual(notified, 3)
  }

  /// runloop を回して条件の成立を待つ（ハンクの作り直しは main へ 1 回だけ積まれる）。
  private func pumpMain(until condition: () -> Bool, timeout: TimeInterval = 5) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(condition(), "条件が \(timeout) 秒以内に成立しない")
  }
}
