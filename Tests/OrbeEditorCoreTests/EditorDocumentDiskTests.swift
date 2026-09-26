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
    XCTAssertEqual(
      document.text.substring(NSRange(location: 0, length: document.text.length)), "new\n",
      "写しは差し替えに追従する")

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

  /// baseline を置くと裏で行差分を取ってハンクが届く。編集の直後は、編集で増えた行の数だけずらした前のハンクを出し、
  /// 裏の結果が届くと置き換わる。baseline を外せば即時に空。
  func testHunksFollowTheBaselineAndEditsThroughTheBackground() throws {
    let (document, surface) = try open(try temp("e.txt", "a\nb\nc\n"))
    XCTAssertEqual(document.hunks, [])
    var notified = 0
    document.onHunksChange = { notified += 1 }

    document.baseline = "a\nc\n"
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(document.hunks, [LineHunk(oldStart: 1, oldCount: 0, newStart: 2, newCount: 1)])
    XCTAssertEqual(notified, 1)

    surface.replace(NSRange(location: 0, length: 0), with: "z\n")
    XCTAssertEqual(
      document.hunks, [LineHunk(oldStart: 1, oldCount: 0, newStart: 3, newCount: 1)],
      "編集の直後は、増えた行の数だけずらした前のハンク")
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(
      document.hunks,
      [
        LineHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: 1),
        LineHunk(oldStart: 1, oldCount: 0, newStart: 3, newCount: 1),
      ])

    let before = notified
    document.baseline = nil
    XCTAssertEqual(document.hunks, [])
    XCTAssertEqual(notified, before + 1)
  }

  /// 外部変更の差し替えは全体の置換として届くが、文書は本文が実際に変わった区間だけを編集として扱う——変わっていない字の
  /// 役割は差し替えの直後（裏を待たずに）も残る。
  func testReplacingFromDiskKeepsTheRolesOfTheUnchangedText() throws {
    let source = (1...50).map { "let value\($0) = \($0)\n" }.joined()
    let url = try temp("r.swift", source)
    let (document, _) = try open(url)
    XCTAssertTrue(document.waitUntilCaughtUp())
    let all = NSRange(location: 0, length: document.text.length)
    let before = document.roles.roles(in: all)
    XCTAssertFalse(before.isEmpty, "前提: 色が付いている")
    var edits: [TextEdit] = []
    document.onTextChange = { edits.append($0) }

    try Data(source.replacingOccurrences(of: "value25 = 25", with: "value25 = 99").utf8).write(
      to: url)
    document.reconcileWithDisk()
    let changed = (source as NSString).range(of: "25\n", options: .backwards)
    XCTAssertEqual(edits.map(\.range), [NSRange(location: changed.location, length: 2)], "変わった区間だけ")
    XCTAssertEqual(document.roles.roles(in: all), before, "差し替えの直後も役割は残る")
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(
      document.text.substring(all),
      source.replacingOccurrences(of: "value25 = 25", with: "value25 = 99"))
  }
}
