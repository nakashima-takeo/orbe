import XCTest

@testable import Orbe

/// Orbe 識別色 SSOT のゲート。
/// ① コントラスト: termAnsi の ink スロットが各モードの背景に対し WCAG AA 4.5 以上。
/// ② drift: SSOT から再生成した conf がコミット済み `app/themes/OrbeDark` / `OrbeLight` と一致。
/// ③ 名前解決: conf が書く named theme 名が `app/themes/` の実ファイルに解決する。
/// これらが Level 0 級（低コントラスト・転写ドリフト・テーマ名の片側改名）の再発を構造的に
/// コミット不能にする。
final class OrbePaletteTests: XCTestCase {

  // MARK: - ① コントラストゲート

  /// ink スロット（確定値除外を除く）が背景に対し AA 4.5 以上であることを検証する（未満なら失敗）。
  /// 番人であり値の正しさの証明ではない——将来の値変更で AA を割ることを防ぐ。
  /// `exempt` は 確定配色値ゆえ 4.5 を満たさず除外するスロット（`OrbePalette.aaExempt*`）。
  private func assertInkMeetsAA(_ palette: [Int], background: Int, mode: String, exempt: Set<Int>) {
    for slot in OrbePalette.inkSlots.subtracting(exempt).sorted() {
      let ratio = OrbePalette.contrastRatio(palette[slot], background)
      XCTAssertGreaterThanOrEqual(
        ratio, 4.5,
        "\(mode) ink スロット \(slot)（#\(String(format: "%06x", palette[slot]))）が背景に対し "
          + "AA 4.5 未満（\(String(format: "%.2f", ratio))）")
    }
  }

  func testDarkInkSlotsMeetAA() {
    assertInkMeetsAA(
      OrbePalette.termAnsiDark, background: OrbePalette.terminalDark.background,
      mode: "dark", exempt: OrbePalette.aaExemptDark)
  }

  func testLightInkSlotsMeetAA() {
    assertInkMeetsAA(
      OrbePalette.termAnsiLight, background: OrbePalette.terminalLight.background,
      mode: "light", exempt: OrbePalette.aaExemptLight)
  }

  /// ink（AA 対象）と構造色（対象外）でスロット 0...15 を過不足なく分割する。
  /// 構造色 {0,7,15} を誤って ink に入れると常時失敗、ink を落とすと番人が効かなくなる。
  func testSlotPartitionCoversAllSlots() {
    let ink = OrbePalette.inkSlots
    let structural = OrbePalette.structuralSlots
    XCTAssertTrue(ink.isDisjoint(with: structural), "ink と構造色は重複しない")
    XCTAssertEqual(ink.union(structural), Set(0...15), "0...15 を過不足なく覆う")
  }

  // MARK: - ② drift ゲート

  func testDarkConfMatchesCommitted() {
    assertConfMatchesCommitted(.dark, fileName: "OrbeDark")
  }

  func testLightConfMatchesCommitted() {
    assertConfMatchesCommitted(.light, fileName: "OrbeLight")
  }

  /// SSOT からの再生成とコミット済み conf を byte 一致で照合する。
  /// `ORBE_WRITE_THEMES=1` のとき照合の代わりに再生成をディスクへ書く（生成コマンド相当）。
  private func assertConfMatchesCommitted(_ mode: OrbePalette.Mode, fileName: String) {
    let url = repoRoot().appendingPathComponent("app/themes/\(fileName)")
    let rendered = OrbePalette.renderConf(mode)
    if ProcessInfo.processInfo.environment["ORBE_WRITE_THEMES"] == "1" {
      try? rendered.write(to: url, atomically: true, encoding: .utf8)
      return
    }
    let committed = (try? String(contentsOf: url, encoding: .utf8)) ?? "<no-file>"
    XCTAssertEqual(
      rendered, committed,
      "\(fileName) が SSOT と不一致。`ORBE_WRITE_THEMES=1 swift test` で再生成してコミットせよ")
  }

  // MARK: - ③ テーマ名解決ゲート

  /// conf が書く named theme 名が `app/themes/` の実ファイルに解決することを検証する。
  /// テーマ名は生成 gui.conf（`SettingsRegistry`）・`app/orbe-defaults.conf`・`app/themes/` の
  /// ファイル名に独立して埋まる。②の drift ゲートは内容しか見ないため、conf 側の名前だけ変えても
  /// 全テストが通る。解決に失敗した ghostty は診断を積んで既定色のまま起動する（起動不能にならない）
  /// ので、端末配色が黙って ghostty 既定に落ちたまま出荷され得る。この鎖の唯一の無防備な辺を塞ぐ。
  func testConfThemeNamesResolveToCommittedFiles() {
    let generated = SettingsRegistry.descriptor(.theme).guiConf?(EffectiveSettings(SettingsLayer()))
    XCTAssertNotNil(generated, "theme は値非依存で常時 emit する")

    let defaults = try? String(
      contentsOf: repoRoot().appendingPathComponent("app/orbe-defaults.conf"), encoding: .utf8)
    let defaultsLine = defaults?.split(separator: "\n").first { $0.hasPrefix("theme = ") }
    XCTAssertNotNil(defaultsLine, "app/orbe-defaults.conf は theme 行を持つ")

    for line in [generated, defaultsLine.map(String.init)].compactMap({ $0 }) {
      let names = themeNames(in: line)
      XCTAssertEqual(names.count, 2, "`\(line)` から light/dark 2 つのテーマ名を取れる")
      for name in names {
        let url = repoRoot().appendingPathComponent("app/themes/\(name)")
        XCTAssertTrue(
          FileManager.default.fileExists(atPath: url.path),
          "`\(line)` が指す app/themes/\(name) が存在しない")
      }
    }
  }

  /// `theme = light:X,dark:Y` から `[X, Y]` を取り出す。
  private func themeNames(in line: String) -> [String] {
    guard let rhs = line.split(separator: "=", maxSplits: 1).last else { return [] }
    return rhs.split(separator: ",").compactMap { part in
      let name = part.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
      return (name?.isEmpty ?? true) ? nil : name
    }
  }

  /// このファイル: <repo>/Tests/OrbeTests/...swift → 3 階層上が repo root。
  private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }
}
