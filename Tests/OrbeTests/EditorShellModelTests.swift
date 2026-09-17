import XCTest

@testable import Orbe

/// 骨の写し——ファイルタブ行（名前・チップ・未保存・衝突・アクティブ）とパンくず（根の下は相対で押せる、
/// 根の外は絶対で押せない）。
///
/// 壊れると何が起きるか。写しがセッションと食い違うと、閉じた文書のタブが残る・別の文書がアクティブに見える。
/// 根の外の文書のパンくずが押せると、ツリーに無い場所を開こうとする。
@MainActor
final class EditorShellModelTests: OrbeTestCase {
  private func file(_ name: String, _ text: String = "x") throws -> URL {
    let dir = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent("root/src", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url.resolvingSymlinksInPath()
  }

  func testTabsMirrorTheSessionAndCrumbsFollowTheRoot() throws {
    let session = EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
    let a = try session.open(try file("a.swift"))
    let b = try session.open(try file("b.md"))
    let root = a.url.deletingLastPathComponent().deletingLastPathComponent().path
    let shell = EditorShellModel()

    shell.update(from: session, root: root)
    XCTAssertEqual(shell.tabs.map(\.name), ["a.swift", "b.md"])
    XCTAssertEqual(shell.tabs.map(\.isActive), [false, true])
    XCTAssertEqual(shell.tabs[0].chip, FileChip(glyph: "S", hue: .orange))
    XCTAssertEqual(shell.activeID, b.url)
    XCTAssertEqual(shell.activeName, "b.md")
    XCTAssertEqual(shell.crumbs.map(\.name), ["src"])
    XCTAssertEqual(shell.crumbs.first?.directory?.path, root + "/src", "根の下は祖先の URL を持つ")

    a.surface.responder.perform(Selector(("insertText:")), with: "Z")
    shell.update(from: session, root: root)
    XCTAssertEqual(shell.tabs.map(\.isDirty), [true, false])
    XCTAssertEqual(shell.tabs.map(\.isConflicted), [false, false])

    shell.update(from: session, root: root + "/elsewhere")
    XCTAssertEqual(
      shell.crumbs.map(\.name), Array(b.url.pathComponents.dropFirst().dropLast()), "根の外は絶対パスの構成要素")
    XCTAssertTrue(shell.crumbs.allSatisfy { $0.directory == nil }, "根の外は押せない")

    session.close(b)
    session.close(a)
    shell.update(from: session, root: root)
    XCTAssertTrue(shell.tabs.isEmpty)
    XCTAssertNil(shell.activeName)
    XCTAssertTrue(shell.crumbs.isEmpty)
  }
}
