import XCTest

@testable import orbe_cli

/// `orb pane split` の分割方向フラグ→direction の契約を固定する。
/// `-h` は上下分割（direction:"down"）であって help ではない（help は `--help` のみ）。
final class PaneSplitDirectionTests: XCTestCase {
  /// `-h` は上下分割（down）。回帰: 以前は help に横取りされ到達不能だった。
  func testHorizontalFlagMapsToDown() {
    var args = ["-h"]
    XCTAssertEqual(paneSplitDirection(&args), "down")
    XCTAssertTrue(args.isEmpty, "-h は消費される")
  }

  /// `-v` は左右分割（right）。
  func testVerticalFlagMapsToRight() {
    var args = ["-v"]
    XCTAssertEqual(paneSplitDirection(&args), "right")
    XCTAssertTrue(args.isEmpty, "-v は消費される")
  }

  /// フラグ無しの既定は左右（right）。
  func testDefaultIsRight() {
    var args: [String] = []
    XCTAssertEqual(paneSplitDirection(&args), "right")
  }

  /// 分割フラグは抜き取り、位置引数（pane id）は残す。
  func testLeavesPositionalPaneArg() {
    var args = ["-h", "7"]
    XCTAssertEqual(paneSplitDirection(&args), "down")
    XCTAssertEqual(args, ["7"], "pane 位置引数は消費しない")
  }
}
