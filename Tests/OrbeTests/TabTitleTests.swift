import XCTest

@testable import Orbe

/// ③派生（タブ名）の純粋ロジック検証。
final class TabTitleTests: XCTestCase {

  // MARK: - compactPath（fish prompt_pwd 純正）

  func testCompactPathRelative() {
    XCTAssertEqual(TabTitle.compactPath("Sources/orbe/Layout"), "S/o/Layout", "相対・末尾フル")
  }

  func testCompactPathTilde() {
    XCTAssertEqual(TabTitle.compactPath("~/other/deep"), "~/o/deep", "~ は頭1字＝~")
  }

  func testCompactPathAbsolute() {
    XCTAssertEqual(TabTitle.compactPath("/etc/nginx"), "/e/nginx", "先頭 / 保持")
  }

  func testCompactPathHiddenDir() {
    XCTAssertEqual(TabTitle.compactPath(".config/nvim"), ".c/nvim", "隠しdir → .+1字")
  }

  func testCompactPathSingleComponent() {
    XCTAssertEqual(TabTitle.compactPath("Layout"), "Layout", "単一要素＝末尾フル")
    XCTAssertEqual(TabTitle.compactPath("~"), "~", "単一要素 ~")
  }

  func testCompactPathEmptyAndRoot() {
    XCTAssertEqual(TabTitle.compactPath(""), "", "空はそのまま")
    XCTAssertEqual(TabTitle.compactPath("/"), "/", "/ はそのまま")
  }

  // MARK: - derive（圧縮アンカーは root の親。pwd と root の 2 分岐）

  private let root = "/Users/me/github/orbe"

  func testDeriveRootExactGivesBasename() {
    XCTAssertEqual(
      TabTitle.derive(pwd: root, root: root), "orbe", "root ちょうど → basename（末尾フルなので不変）")
  }

  func testDeriveUnderRootAnchorsAtRootParent() {
    XCTAssertEqual(
      TabTitle.derive(pwd: root + "/Sources", root: root), "o/Sources",
      "root 直下 → root 名が頭1字圧縮で先頭に付く")
    XCTAssertEqual(
      TabTitle.derive(pwd: root + "/Sources/orbe/Layout", root: root), "o/S/o/Layout",
      "root の深い配下 → root から末尾直前まで頭1字圧縮・末尾フル")
  }

  // root 外は abbreviatingWithTildeInPath（実 home 依存）で ~ 短縮するため、実 home 基準で組む。
  func testDeriveOutsideRootGivesTildeCompact() {
    let home = NSHomeDirectory()
    XCTAssertEqual(
      TabTitle.derive(pwd: home + "/other/deep", root: home + "/github/orbe"), "~/o/deep",
      "root 外（home 配下）→ ~ 基準 absolute を compact")
  }

  func testDeriveRootNilOrEmptyUsesTilde() {
    let home = NSHomeDirectory()
    XCTAssertEqual(
      TabTitle.derive(pwd: home + "/x/y", root: nil), "~/x/y", "root nil → ~ 基準 compact")
    XCTAssertEqual(
      TabTitle.derive(pwd: home + "/x/y", root: ""), "~/x/y", "root 空 → ~ 基準 compact")
  }

  // home 外の絶対パスは ~ 短縮されず先頭 / 保持のまま compact される。
  func testDeriveOutsideHomeKeepsAbsolute() {
    XCTAssertEqual(
      TabTitle.derive(pwd: "/var/log/nginx", root: "/srv/app"), "/v/l/nginx",
      "root 外かつ home 外 → 絶対パスを compact（先頭 / 保持）")
  }

  func testDeriveHandlesTrailingSlash() {
    XCTAssertEqual(
      TabTitle.derive(pwd: root + "/", root: root), "orbe", "末尾 / があっても root ちょうど扱い")
  }
}
