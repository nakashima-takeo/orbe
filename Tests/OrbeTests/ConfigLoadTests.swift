import Foundation
import GhosttyKit
import XCTest

@testable import Orbe

/// `Config.load()` の 3 層読み込み——層1 キュレート既定・層2 user 設定・層3 gui.conf——を
/// 実 libghostty で測る。
///
/// 層1 の存在確認を落とすと、非バンドル起動（`swift build`）で不在パスを
/// `ghostty_config_load_file` に渡すことになる。libghostty は診断も積まず無言で無視するため
/// テストは緑のまま、層1 が本当に効いているのかどうかも分からなくなる。
/// 後勝ち順序が崩れると、GUI の設定パレットで変えた値が user の `~/.config/ghostty` に負けて
/// 画面へ反映されない（あるいは逆に user 設定を無視する）。どちらも診断に出ず値だけが違う。
final class ConfigLoadTests: OrbeTestCase {

  private var savedBundledRoot: URL?
  private var savedUserOverride: URL?
  private var dir: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    // ghostty_config_new は ghostty_init 前に呼ぶと SIGSEGV する。ランタイムを先に起こす。
    _ = Ghostty.shared
    savedBundledRoot = BundledResources.root
    savedUserOverride = Config.userFileURLOverride
    dir = try XCTUnwrap(TestIsolation.caseDir)
  }

  override func tearDownWithError() throws {
    BundledResources.root = savedBundledRoot
    Config.userFileURLOverride = savedUserOverride
    try super.tearDownWithError()
  }

  // MARK: - 観測

  /// 実効 `font-size` を読む。`ghostty_config_get` は書き込むバイト数を型で決めるため、
  /// 型を誤るとメモリを壊す。`font-size` が 4 バイト（f32）であることは実測で確定した。
  private func fontSize(_ cfg: ghostty_config_t) -> Float? {
    var value: Float = 0
    let key = "font-size"
    let ok = key.withCString { ghostty_config_get(cfg, &value, $0, UInt(key.utf8.count)) }
    return ok ? value : nil
  }

  /// 層1 を「`orbe-defaults.conf` を置いたディレクトリ」（nil で空ディレクトリ）へ向ける。
  private func setDefaultsLayer(_ contents: String?) throws {
    let root = dir.appendingPathComponent("resources-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if let contents {
      try contents.write(
        to: root.appendingPathComponent("orbe-defaults.conf"), atomically: true, encoding: .utf8)
    }
    BundledResources.root = root
  }

  /// 層2（user）を実ファイルへ向ける（nil で不在＝読まれない）。
  private func setUserLayer(_ contents: String?) throws {
    let url = dir.appendingPathComponent("user-\(UUID().uuidString.prefix(8)).conf")
    if let contents { try contents.write(to: url, atomically: true, encoding: .utf8) }
    Config.userFileURLOverride = url
  }

  /// 層3（gui.conf）を実ファイルへ向ける（nil で削除＝不在）。
  private func setGuiLayer(_ contents: String?) throws {
    let url = try XCTUnwrap(GuiConfig.fileURL)
    if let contents {
      try contents.write(to: url, atomically: true, encoding: .utf8)
    } else {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func loadedFontSize() throws -> Float {
    let cfg = Config.load()
    defer { ghostty_config_free(cfg) }
    return try XCTUnwrap(fontSize(cfg), "font-size を読めない")
  }

  // MARK: - 層1 の存在確認

  /// 層1 は `orbe-defaults.conf` が実在するときだけ読まれ、空ディレクトリでは値が入らない。
  func testDefaultsLayerAppliesOnlyWhenFilePresent() throws {
    try setUserLayer(nil)
    try setGuiLayer(nil)

    try setDefaultsLayer("font-size = 11\n")
    XCTAssertEqual(try loadedFontSize(), 11, "同梱既定が実在すれば層1 が効く")

    try setDefaultsLayer(nil)
    XCTAssertNotEqual(try loadedFontSize(), 11, "空ディレクトリ＝層1 不在なら効かない")
  }

  // MARK: - 後勝ち順序

  /// 同じキーを 3 層が争うと、層3（gui.conf）＞層2（user）＞層1（同梱既定）の順に勝つ。
  func testLayerPrecedenceIsGuiOverUserOverDefaults() throws {
    try setDefaultsLayer("font-size = 11\n")

    try setUserLayer("font-size = 12\n")
    try setGuiLayer("font-size = 13\n")
    XCTAssertEqual(try loadedFontSize(), 13, "層3 が全てに勝つ")

    try setGuiLayer(nil)
    XCTAssertEqual(try loadedFontSize(), 12, "層3 が無ければ層2 が層1 に勝つ")

    try setUserLayer(nil)
    XCTAssertEqual(try loadedFontSize(), 11, "層2 も無ければ層1 が残る")
  }
}
