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

  private var savedXdgConfigHome: String?
  private var dir: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    // ghostty_config_new は ghostty_init 前に呼ぶと SIGSEGV する。ランタイムを先に起こす。
    _ = Ghostty.shared
    // 層1・層2 の override はハーネスが毎テスト張り直すので、ここで退避する必要はない。
    // `XDG_CONFIG_HOME` はプロセス env なのでハーネスの管轄外＝自分で戻す。
    savedXdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    dir = try XCTUnwrap(TestIsolation.caseDir)
  }

  override func tearDownWithError() throws {
    if let savedXdgConfigHome {
      setenv("XDG_CONFIG_HOME", savedXdgConfigHome, 1)
    } else {
      unsetenv("XDG_CONFIG_HOME")
    }
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

  /// ghostty の既定探索（`ghostty_config_load_default_files`）が走ったら必ず値が入る罠を
  /// XDG 脚へ仕掛ける。走らなければ値は入らない——罠の有無で「呼ばれたか」を観測できる。
  ///
  /// 実ホームには触らない。`XDG_CONFIG_HOME` は libghostty が libc の `getenv` で毎回引き直すので
  /// プロセス内から曲げられる。もう一方の脚（Application Support）は `NSFileManager` 由来で
  /// `HOME` を書き換えても曲がらないため、罠は XDG 側にのみ置ける。
  private func plantDefaultDiscoveryTrap(fontSize: Int) throws {
    let xdg = dir.appendingPathComponent("xdg", isDirectory: true)
    let ghostty = xdg.appendingPathComponent("ghostty", isDirectory: true)
    try FileManager.default.createDirectory(at: ghostty, withIntermediateDirectories: true)
    // 現行の探索名と 1.3.0 以前の名前の両方に置く（どちらが読まれても罠が発火する）。
    for name in ["config.ghostty", "config"] {
      try "font-size = \(fontSize)\n".write(
        to: ghostty.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    setenv("XDG_CONFIG_HOME", xdg.path, 1)
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

    // 17 は libghostty の既定（13）と衝突しない値。既定と同値だと「どの層も読まれなかった」
    // 場合にもこの assert が通ってしまう。
    try setUserLayer("font-size = 12\n")
    try setGuiLayer("font-size = 17\n")
    XCTAssertEqual(try loadedFontSize(), 17, "層3 が全てに勝つ")

    try setGuiLayer(nil)
    XCTAssertEqual(try loadedFontSize(), 12, "層3 が無ければ層2 が層1 に勝つ")

    try setUserLayer(nil)
    XCTAssertEqual(try loadedFontSize(), 11, "層2 も無ければ層1 が残る")
  }

  // MARK: - 既定探索の遮断

  /// `userFileURLOverride` が非 nil なら、層2 はその 1 ファイルに限定され、ghostty 自身の
  /// 既定探索（`~/.config/ghostty` と Application Support）は走らない。
  ///
  /// 隔離ハーネスの ghostty 遮断はこの一点に全乗りしている。ここが崩れると `swift test` が
  /// 開発者の実 ghostty 設定を読み始め、テストは「手元のマシンの状態」を測るものへ変質する。
  /// 既存の後勝ちテストでは検出できない——層2 を不在にしたときに値が入らないことは
  /// 「既定探索が走らなかった」ことを意味せず、罠を置いて初めて区別がつく。
  func testUserOverrideBlocksGhosttyDefaultDiscovery() throws {
    let trapFontSize: Float = 37
    try plantDefaultDiscoveryTrap(fontSize: Int(trapFontSize))
    try setDefaultsLayer(nil)
    try setGuiLayer(nil)

    // override が実ファイルを指すとき: 層2 はそのファイルだけ。罠は入らない。
    try setUserLayer("font-size = 12\n")
    XCTAssertEqual(try loadedFontSize(), 12, "override が指す 1 ファイルが層2 になる")

    // override が不在ファイルを指すとき（ハーネスが張るのはこの形）: 層2 は空のまま。
    // 既定探索へフォールバックしないので、罠の値も入らない。
    try setUserLayer(nil)
    XCTAssertNotEqual(
      try loadedFontSize(), trapFontSize,
      "override が不在ファイルでも既定探索へ落ちない（落ちれば実 user 設定が漏れる）")
  }
}
