import Foundation
import OrbeTestSupport
import XCTest
import os

@testable import OrbeEditorCore

/// 版の本文を読むだけで持つ文書——名前から言語を決めて構文の色を裏で作って main へ届け、結んだ面と差し込みの出どころの読み手へ知らせ、
/// 面は読むだけにし、閉じたら大きな部品を裏で手放す。壊れると、diff の古い側が素の字のまま・遅れて色が付いても削除行が
/// 描き直されない・閉じると main が止まる。
@MainActor
final class RevisionDocumentTests: XCTestCase {
  private let registry = LanguageRegistry(queriesRoot: Queries.root)

  /// 名前の拡張子で言語を決め、写しの役割の並びに構文の色が付く——待たなくても、裏で作った色は main に届いて載る。結んだ面は
  /// 読むだけになり、写しを引き、役割の変化を受ける。
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
    // 追いつくのを待つ口（自分で受け取る）を使わず、main を回すだけで届くのを待つ。
    waitUntil(10) { surface.texts(of: .keyword).contains("func") }
    let keywords = surface.texts(of: .keyword)
    XCTAssertTrue(keywords.contains("let") && keywords.contains("func"), "\(keywords)")
    XCTAssertFalse(surface.changedRoles.isEmpty, "結んだ面へ役割の変化を知らせる")
    XCTAssertEqual(notified, surface.changedRoles, "出どころの読み手へも同じ区間を知らせる")
    XCTAssertEqual(document.rowSourceContent.roles.length, document.text.length)
  }

  /// 先頭の画面の色が届いた後に見えている範囲を遠くへ移してから初めて見せると、移した先の色を待つ（diff を最初の変更へ
  /// 送った直後の待ち）。前に見えていた範囲の色が揃ったことでは待ちを抜けない。
  func testTheFirstShowWaitsForTheLinesMadeVisibleLast() throws {
    // 先頭の画面を作り終えてから、遠くの行まで作り進むのに十分かかる大きさ。
    let lineCount = 20_000
    let text = (0..<lineCount).map { "let value\($0) = \($0)\n" }.joined()
    let document = RevisionDocument(
      text: text, name: URL(fileURLWithPath: "/x/big.swift"), registry: registry)
    let roles = { (line: Int) in
      document.roles.roles(
        in: NSRange(location: document.text.lineStart(line), length: "let".utf16.count))
    }
    waitUntil(10) { !roles(0).isEmpty }
    XCTAssertFalse(roles(0).isEmpty, "前提: 先頭の画面の色が届く")
    let far = lineCount - 100
    XCTAssertTrue(roles(far).isEmpty, "前提: 遠くの行はまだ作っていない")

    document.setVisible(lines: far...(far + 50))
    document.prepareToShow(until: .now() + 10)
    XCTAssertEqual(roles(far).map(\.role), [.keyword], "移した先の色が付いてから戻る")
  }

  /// 言語の無い名前では色を作らず、すぐ追いつく。
  func testUnknownLanguagesStayPlain() {
    let document = RevisionDocument(
      text: "plain\n", name: URL(fileURLWithPath: "/x/notes.unknown"), registry: registry)
    XCTAssertNil(document.language)
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 1))
    XCTAssertTrue(document.roles.roles(in: NSRange(location: 0, length: 6)).isEmpty)
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
    waitUntil(5) { released.withLock { $0 } }
    XCTAssertTrue(released.withLock { $0 }, "裏の仕事が裏へ渡る")
  }
}
