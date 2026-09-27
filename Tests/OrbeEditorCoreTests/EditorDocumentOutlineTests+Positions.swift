import Foundation
import XCTest

@testable import OrbeEditorCore

/// 取り直す前の結果への位置の問い——1 回の操作が複数の区間を変える編集の束をまたいでも、他の裏の仕事の結果を受け取った後
/// でも、区間の端ちょうどに打っても、今の本文で答える。
extension EditorDocumentOutlineTests {
  /// 束の頭の長い挿入でシンボルの名前が束の後ろの編集の位置より後ろへ押されても、飛び先・範囲・今の位置を含むシンボルは
  /// 今の本文の上にある。
  func testQuestionsAboutPositionsFollowABatchOfEdits() throws {
    let (document, surface) = try open(quietDelay: .seconds(30))
    document.wantsOutline = true
    XCTAssertTrue(document.waitUntilCaughtUp())
    let token = try XCTUnwrap(document.outline?.token)
    let grow = try index("grow(by:)", in: document)
    let width = try index("width", in: document)

    let head = "// a comment long enough to push the name past the body\n"
    let body = (surface.text as NSString).range(of: "amount\n")
    XCTAssertGreaterThan(
      (surface.text as NSString).range(of: "grow").location + head.utf16.count, NSMaxRange(body),
      "前提: 束の頭の挿入が、名前を束の後ろの編集の区間より後ろへ押す")
    surface.apply([
      TextEdit(range: NSRange(location: 0, length: 0), replacement: head),
      TextEdit(range: NSRange(location: body.location, length: 6), replacement: "amount * 2"),
    ])
    XCTAssertEqual(document.outline?.token, token, "前提: まだ取り直していない")

    let name = try XCTUnwrap(document.outlineNameRange(of: grow, in: token))
    XCTAssertEqual(surface.substring(in: name), "grow", "飛び先は今の本文の名前")
    let range = try XCTUnwrap(document.outlineRange(of: grow, in: token))
    XCTAssertTrue(surface.substring(in: range).hasPrefix("func grow"))
    XCTAssertTrue(surface.substring(in: range).hasSuffix("}"))
    let text = surface.text as NSString
    XCTAssertEqual(
      document.outlineSymbol(containing: text.range(of: "* 2").location, in: token), grow)
    XCTAssertEqual(
      document.outlineSymbol(containing: text.range(of: "func grow").location, in: token), grow,
      "範囲の頭")
    XCTAssertEqual(
      document.outlineSymbol(containing: text.range(of: "var width").location, in: token), width)
  }

  /// 編集の後に構文の結果（見えている範囲の色）を受け取っても、取り直す前の結果への位置の問いに答え続ける——結果の版から
  /// 後ろの編集は、アウトラインが取り直されるまで捨てない。
  func testQuestionsAreAnsweredAfterOtherResultsArrive() throws {
    let (document, surface) = try open(quietDelay: .seconds(30))
    document.wantsOutline = true
    XCTAssertTrue(document.waitUntilCaughtUp())
    let token = try XCTUnwrap(document.outline?.token)
    let grow = try index("grow(by:)", in: document)

    surface.replace(NSRange(location: 0, length: 0), with: "// head\n")
    let deadline = Date().addingTimeInterval(5)
    while !document.isFirstColorReady, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(document.isFirstColorReady, "前提: 編集の後の構文の結果を受け取った")
    XCTAssertEqual(document.outline?.token, token, "前提: まだ取り直していない")

    let name = try XCTUnwrap(document.outlineNameRange(of: grow, in: token))
    XCTAssertEqual(surface.substring(in: name), "grow")
    let body = (surface.text as NSString).range(of: "width += amount")
    XCTAssertEqual(document.outlineSymbol(containing: body.location, in: token), grow)
  }

  /// 名前の頭ちょうどに打った字は飛び先の名前に入らず、範囲の終わりちょうどに打った字は範囲に入らない（どちらもシンボルの
  /// 外の字）。
  func testTextTypedExactlyAtTheEdgesStaysOutsideTheSymbol() throws {
    let (document, surface) = try open(quietDelay: .seconds(30))
    document.wantsOutline = true
    XCTAssertTrue(document.waitUntilCaughtUp())
    let token = try XCTUnwrap(document.outline?.token)
    let grow = try index("grow(by:)", in: document)
    let end = try XCTUnwrap(document.outlineRange(of: grow, in: token)).upperBound

    surface.replace(NSRange(location: end, length: 0), with: " // after")
    let name = (surface.text as NSString).range(of: "grow")
    surface.replace(NSRange(location: name.location, length: 0), with: "big_")

    XCTAssertEqual(
      surface.substring(in: try XCTUnwrap(document.outlineNameRange(of: grow, in: token))), "grow")
    let range = try XCTUnwrap(document.outlineRange(of: grow, in: token))
    XCTAssertTrue(surface.substring(in: range).hasSuffix("}"), "範囲の終わりの後に打った字は入らない")
  }
}
