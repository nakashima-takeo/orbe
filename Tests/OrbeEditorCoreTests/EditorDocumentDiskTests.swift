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
    let contents = try EditorDocument.read(url)
    let surface = FakeTextSurface(text: contents.text)
    return (
      EditorDocument(url: url, contents: contents, surface: surface, registry: registry), surface
    )
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

  /// 監視が届く前の ⌘S でも同じ判定——未編集の文書は差し替えてから書き（外の編集は失われない）、
  /// 未保存の文書は失敗する。外のツールが元に戻せば印は消える。
  func testSaveChecksTheDiskWithoutWaitingForAWatcherAndTheMarkClearsWhenRestored() throws {
    let url = try temp("c.txt", "old\n")
    let (document, surface) = try open(url)

    try Data("theirs\n".utf8).write(to: url)
    try document.save()
    XCTAssertEqual(surface.text, "theirs\n", "未編集なら差し替わる")
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "theirs\n")
    XCTAssertFalse(document.isDiskChanged)
    XCTAssertFalse(document.isDirty)

    try Data("old\n".utf8).write(to: url)
    document.reconcileWithDisk()
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

  /// 外のツールが UTF-8 でない内容（別の符号化・バイナリ）を書いたら、一致を証明できないので印が立ち、
  /// ⌘S は失敗する——未編集でも差し替えられない。UTF-8 なら拒否されるのにバイナリなら通る、という
  /// 非対称を作らない。消えたファイルはこれまでどおり印を立てない。
  func testNonUTF8ExternalWriteMarksTheDocumentAndBlocksSave() throws {
    let url = try temp("f.txt", "text\n")
    let (document, surface) = try open(url)
    let bytes = Data([0x82, 0xA0, 0x82, 0xA2, 0x0A])

    try bytes.write(to: url)
    document.reconcileWithDisk()
    XCTAssertTrue(document.isDiskChanged, "未編集でも差し替えられないので印が立つ")
    XCTAssertEqual(surface.text, "text\n", "本文はそのまま")
    XCTAssertThrowsError(try document.save()) { error in
      XCTAssertEqual(error as? EditorDocumentError, .diskChanged(url))
    }
    XCTAssertEqual(try Data(contentsOf: url), bytes, "ディスクは変わらない")

    surface.replace(NSRange(location: 0, length: 0), with: "x")
    XCTAssertThrowsError(try document.save(), "未保存でも同じ")
    try document.save(force: true)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "xtext\n")
    XCTAssertFalse(document.isDiskChanged)
  }

  /// UTF-8 BOM で始まるファイルは、開いたときの有無を保存で保つ——一文字も触らない ⌘S で先頭 3 バイトが
  /// 消えない。本文には含めず、ディスクの姿はバイト列で取るので、自分の保存は外部変更にならず、外のツールが
  /// BOM だけを足せば変化として拾って以後はそれに倣う。
  func testUTF8BOMIsPreservedAcrossSave() throws {
    let bom = Data([0xEF, 0xBB, 0xBF])
    let url = try temp("bom.txt", "")
    try (bom + Data("hello\n".utf8)).write(to: url)
    let (document, surface) = try open(url)
    XCTAssertEqual(surface.text, "hello\n", "本文に BOM は含めない")

    // 未保存の状態で照合する——未編集だと同じ本文の差し替えで黙って自己修復し、ダイジェストの出どころが
    // 本文に戻る退行を捕まえられない。
    surface.replace(NSRange(location: 0, length: 0), with: "x")
    document.reconcileWithDisk()
    XCTAssertFalse(document.isDiskChanged, "開いた直後: ディスクの姿は BOM を含むバイト列で取る")

    try document.save(force: true)
    XCTAssertEqual(try Data(contentsOf: url), bom + Data("xhello\n".utf8), "BOM は残る")
    surface.replace(NSRange(location: 0, length: 0), with: "y")
    document.reconcileWithDisk()
    XCTAssertFalse(document.isDiskChanged, "自分の保存は外部変更ではない（保存が置く姿も書いたバイト列）")
    try document.save()
    XCTAssertEqual(try Data(contentsOf: url), bom + Data("yxhello\n".utf8))

    let plain = try temp("plain.txt", "hi\n")
    let (plainDocument, _) = try open(plain)
    try plainDocument.save()
    XCTAssertEqual(try Data(contentsOf: plain), Data("hi\n".utf8), "無かった BOM は足さない")
    try (bom + Data("hi\n".utf8)).write(to: plain)
    plainDocument.reconcileWithDisk()
    XCTAssertFalse(plainDocument.isDiskChanged, "BOM だけの変化も差し替え（本文は同じ）")
    try plainDocument.save()
    XCTAssertEqual(try Data(contentsOf: plain), bom + Data("hi\n".utf8), "外のツールが足した BOM に倣う")
  }

  // MARK: - ハンク

  /// baseline を置けば即時にハンクが出て、編集は同期では作り直さず、連続した編集で作り直しは 1 回。
  /// baseline を外せば空。
  func testHunksFollowTheBaselineImmediatelyAndConsecutiveEditsRebuildOnce() throws {
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
  private func pumpMain(
    until condition: () -> Bool, timeout: TimeInterval = 5, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(condition(), "条件が \(timeout) 秒以内に成立しない", file: file, line: line)
  }
}
