import Foundation
import OrbeTestSupport
import XCTest
import os

@testable import OrbeEditorCore

/// 版の本文を読むだけで持つ文書——名前から言語を決めて構文の色を裏で作り、結んだ面と差し込みの出どころの読み手へ知らせ、
/// 面は読むだけにし、見えている範囲（面が無くても）を先に色付けし、閉じたら大きな部品を裏で手放す。壊れると、diff の
/// 古い側が素の字のまま・遅れて色が付いても削除行が描き直されない・遠くの削除行の色がいつまでも付かない・閉じると main が
/// 止まる。
@MainActor
final class RevisionDocumentTests: XCTestCase {
  private let registry = LanguageRegistry(queriesRoot: Queries.root)

  /// 名前の拡張子で言語を決め、写しの役割の並びに構文の色が付く。結んだ面は読むだけになり、写しを引き、役割の変化を受ける。
  func testColorsTheTextAndNotifiesTheAttachedSurface() throws {
    let document = RevisionDocument(
      text: "let a = 1\nfunc f() {}\n", name: URL(fileURLWithPath: "/x/a.swift"),
      registry: registry)
    XCTAssertEqual(document.language, .swift)
    let surface = FakeTextSurface(text: "let a = 1\nfunc f() {}\n")
    var notified: [IndexSet] = []
    document.onRolesChange = { notified.append($0) }
    document.attach(surface)
    XCTAssertFalse(surface.isEditable, "結んだ面は読むだけ")
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 30))
    let keywords = surface.texts(of: .keyword)
    XCTAssertTrue(keywords.contains("let") && keywords.contains("func"), "\(keywords)")
    XCTAssertFalse(surface.changedRoles.isEmpty, "結んだ面へ役割の変化を知らせる")
    XCTAssertEqual(notified, surface.changedRoles, "出どころの読み手へも同じ区間を知らせる")
    XCTAssertEqual(document.rowSourceContent.roles.length, document.text.length)
  }

  /// 言語の無い名前では色を作らず、すぐ追いつく。
  func testUnknownLanguagesStayPlain() {
    let document = RevisionDocument(
      text: "plain\n", name: URL(fileURLWithPath: "/x/notes.unknown"), registry: registry)
    XCTAssertNil(document.language)
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 1))
    XCTAssertTrue(document.roles.roles(in: NSRange(location: 0, length: 6)).isEmpty)
  }

  /// 面が無くても、渡した見えている範囲を先に色付けする（打鍵の止むのを待つ見えていない範囲より前）。
  func testVisibleLinesAreColoredFirstWithoutASurface() throws {
    let lines = (0..<20_000).map { "let value\($0) = \($0)" }.joined(separator: "\n")
    let document = RevisionDocument(
      text: lines, name: URL(fileURLWithPath: "/x/big.swift"), registry: registry,
      quietDelay: .seconds(60))
    document.setVisible(lines: 15_000...15_040)
    let start = document.text.lineStart(15_020)
    let deadline = Date().addingTimeInterval(30)
    while document.roles.roles(in: NSRange(location: start, length: 3)).first?.role != .keyword,
      Date() < deadline
    {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertEqual(
      document.roles.roles(in: NSRange(location: start, length: 3)).first?.role, .keyword,
      "渡した範囲の色が付く")
  }

  /// 外した面は delegate を失い、それ以後の色の変化を受けない。
  func testDetachingReleasesTheSurface() {
    let document = RevisionDocument(
      text: "let a = 1\n", name: URL(fileURLWithPath: "/x/a.swift"), registry: registry)
    let surface = FakeTextSurface(text: "let a = 1\n")
    document.attach(surface)
    document.detach()
    XCTAssertNil(surface.delegate)
    XCTAssertNil(document.surface)
  }

  /// 閉じると、構文の裏の仕事の最後の参照は裏で手放される（main で大きな木を解放しない）。
  func testClosingHandsTheSyntaxWorkerToTheBackground() {
    let released = OSAllocatedUnfairLock(initialState: false)
    do {
      let document = RevisionDocument(
        text: "let a = 1\n", name: URL(fileURLWithPath: "/x/a.swift"), registry: registry)
      document.releaseParts = { parcel in
        DispatchQueue.global().async {
          let worker = parcel.withLock { $0?.syntax }
          released.withLock { $0 = worker != nil }
          parcel.withLock { $0 = nil }
        }
      }
    }
    let deadline = Date().addingTimeInterval(5)
    while !released.withLock({ $0 }), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(released.withLock { $0 }, "裏の仕事が裏へ渡る")
  }
}
