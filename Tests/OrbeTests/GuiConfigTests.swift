import XCTest

@testable import Orbe

/// 生成 conf（GUI が触ったキーだけ sparse に書く。theme 行のみ定数で常時）の検証。
/// 入力型が `EffectiveSettings` へ替わっても、同一設定値に対する**出力バイトは現行と完全一致**する。
final class GuiConfigTests: XCTestCase {
  override func setUp() {
    super.setUp()
    GuiConfig.fileURLOverride = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("GuiConfigTests-\(UUID().uuidString).conf")
  }

  override func tearDown() {
    if let url = GuiConfig.fileURLOverride {
      try? FileManager.default.removeItem(at: url)
    }
    GuiConfig.fileURLOverride = nil
    super.tearDown()
  }

  private func content() -> String {
    guard let url = GuiConfig.fileURLOverride else { return "<no-url>" }
    return (try? String(contentsOf: url, encoding: .utf8)) ?? "<no-file>"
  }

  /// 明示された項目だけを載せた実効設定（未設定は raw で行を出さない＝既定へ解決しない）。
  private func eff(
    fontSize: Int? = nil, theme: ThemeMode? = nil, fontFamily: String? = nil,
    emojiFont: EmojiFontMode? = nil,
    backgroundOpacity: Int? = nil, backgroundBlur: Bool? = nil, cursorStyleBlink: Bool? = nil,
    defaultAgent: String? = nil
  ) -> EffectiveSettings {
    var l = SettingsLayer()
    l[SettingKeys.fontSize] = fontSize
    l[SettingKeys.theme] = theme
    l[SettingKeys.fontFamily] = fontFamily
    l[SettingKeys.emojiFont] = emojiFont
    l[SettingKeys.backgroundOpacity] = backgroundOpacity
    l[SettingKeys.backgroundBlur] = backgroundBlur
    l[SettingKeys.cursorStyleBlink] = cursorStyleBlink
    l[SettingKeys.defaultAgent] = defaultAgent
    return EffectiveSettings(l)
  }

  /// 全 nil でも常時 emit される 2 行（正準順: emoji-font の font-codepoint-map → theme 定数行）。
  /// emoji-font 行は実効既定 noto の map（単一出所）、theme 行はユーザー `~/.config/ghostty` の
  /// theme 指定を層3後勝ちで無効化する定数。
  private let constLines =
    "font-codepoint-map = \(EmojiPresentationRanges.confValue)=Noto Color Emoji\n"
    + "theme = light:OrbeLight,dark:OrbeDark\n"

  /// fontFamily 選択時に吐く font-family ブロック（reset＋選択＋JuliaMono）。
  private func fontBlock(_ family: String) -> String {
    [
      "font-family = \"\"",
      "font-family = \(family)",
      "font-family = JuliaMono",
    ].map { $0 + "\n" }.joined()
  }

  func testFontSizeOnly() {
    GuiConfig.regenerate(from: eff(fontSize: 14))
    XCTAssertEqual(content(), "font-size = 14\n" + constLines)
  }

  /// theme 定数行・emoji-font 行は設定値（auto/dark/light・未設定）に関わらず常時出る。
  func testThemeConstantLineRegardlessOfMode() {
    GuiConfig.regenerate(from: eff())
    XCTAssertEqual(content(), constLines, "全 nil でも常時 emit の 2 行は出る（空ファイルにならない）")
    GuiConfig.regenerate(from: eff(theme: .dark))
    XCTAssertEqual(content(), constLines, "dark でも同一の定数行")
    GuiConfig.regenerate(from: eff(theme: .auto))
    XCTAssertEqual(content(), constLines, "auto 明示でも同一の定数行")
  }

  /// fontFamily 選択時は 3 行（reset＋選択＋JuliaMono）を吐く。空白入り family もクォート無し literal で 2 行目に載る。
  func testFontFamilyOnly() {
    GuiConfig.regenerate(from: eff(fontFamily: "SF Mono"))
    XCTAssertEqual(content(), fontBlock("SF Mono") + constLines)
  }

  /// font-family ブロック（3 行）は font-size の次・emoji-font/theme 定数行の前に並ぶ（正準順）。
  func testCanonicalOrderFontSizeFamilyTheme() {
    GuiConfig.regenerate(from: eff(fontSize: 14, theme: .dark, fontFamily: "Menlo"))
    XCTAssertEqual(content(), "font-size = 14\n" + fontBlock("Menlo") + constLines)
  }

  /// emoji-font=apple では map 先が Apple Color Emoji（60 点集合）の行へ入れ替わる（位置は同じ）。
  func testEmojiFontAppleSwapsMapLine() {
    GuiConfig.regenerate(from: eff(fontSize: 14, emojiFont: .apple))
    XCTAssertEqual(
      content(),
      "font-size = 14\n"
        + "font-codepoint-map = \(SettingsRegistry.appleEmojiConfValue)=Apple Color Emoji\n"
        + "theme = light:OrbeLight,dark:OrbeDark\n")
  }

  /// fontFamily=nil（（既定に戻す））で再生成すると font-family 3 行が消え、他キーは残る。
  func testFontFamilyResetRemovesLineKeepsOthers() {
    GuiConfig.regenerate(from: eff(fontSize: 14, fontFamily: "Menlo"))
    XCTAssertEqual(content(), "font-size = 14\n" + fontBlock("Menlo") + constLines)
    GuiConfig.regenerate(from: eff(fontSize: 14, fontFamily: nil))
    XCTAssertEqual(content(), "font-size = 14\n" + constLines, "font-family 行が消え font-size は残る")
  }

  /// ドメインB の defaultAgent 等は生成 conf に出さない（ドメインA のキーだけ）。
  func testIgnoresNonDomainAFields() {
    GuiConfig.regenerate(from: eff(fontSize: 16, defaultAgent: "claude"))
    XCTAssertEqual(content(), "font-size = 16\n" + constLines)
  }

  /// background-opacity は percent を /100 して 2 桁固定で書く（既定 90→0.90・端数も 2 桁）。
  func testBackgroundOpacityLine() {
    GuiConfig.regenerate(from: eff(backgroundOpacity: 90))
    XCTAssertEqual(content(), constLines + "background-opacity = 0.90\n")
  }

  /// 境界値: 20%→0.20・100%→1.00。
  func testBackgroundOpacityBoundaries() {
    GuiConfig.regenerate(from: eff(backgroundOpacity: 20))
    XCTAssertEqual(content(), constLines + "background-opacity = 0.20\n")
    GuiConfig.regenerate(from: eff(backgroundOpacity: 100))
    XCTAssertEqual(content(), constLines + "background-opacity = 1.00\n")
  }

  /// backgroundOpacity=nil（GUI 未介入）では行を出さない（他キーは残る）。
  func testBackgroundOpacityNilOmitsLine() {
    GuiConfig.regenerate(from: eff(fontSize: 14, backgroundOpacity: nil))
    XCTAssertEqual(content(), "font-size = 14\n" + constLines, "backgroundOpacity 未設定は行を出さない")
  }

  /// background-blur は background-opacity の直後・cursor-style-blink の前（正準順）。
  func testBackgroundBlurOrderBetweenOpacityAndCursorBlink() {
    GuiConfig.regenerate(
      from: eff(backgroundOpacity: 90, backgroundBlur: true, cursorStyleBlink: true))
    XCTAssertEqual(
      content(),
      constLines + "background-opacity = 0.90\nbackground-blur = true\ncursor-style-blink = true\n")
  }

  /// background-blur は true/false をそのまま行に書く。
  func testBackgroundBlurLine() {
    GuiConfig.regenerate(from: eff(backgroundBlur: true))
    XCTAssertEqual(content(), constLines + "background-blur = true\n")
    GuiConfig.regenerate(from: eff(backgroundBlur: false))
    XCTAssertEqual(content(), constLines + "background-blur = false\n")
  }

  /// backgroundBlur=nil（GUI 未介入）では行を出さない（他キーは残る）。
  func testBackgroundBlurNilOmitsLine() {
    GuiConfig.regenerate(from: eff(fontSize: 14, backgroundBlur: nil))
    XCTAssertEqual(content(), "font-size = 14\n" + constLines, "backgroundBlur 未設定は行を出さない")
  }

  /// cursor-style-blink は正準順の末尾（… → background-opacity → background-blur → cursor-style-blink）。
  func testCursorStyleBlinkOrderIsLast() {
    GuiConfig.regenerate(
      from: eff(
        fontSize: 14, theme: .dark, fontFamily: "Menlo", backgroundOpacity: 90,
        cursorStyleBlink: true)
    )
    XCTAssertEqual(
      content(),
      "font-size = 14\n" + fontBlock("Menlo") + constLines
        + "background-opacity = 0.90\ncursor-style-blink = true\n"
    )
  }

  /// cursor-style-blink は true/false をそのまま行に書く。
  func testCursorStyleBlinkLine() {
    GuiConfig.regenerate(from: eff(cursorStyleBlink: true))
    XCTAssertEqual(content(), constLines + "cursor-style-blink = true\n")
    GuiConfig.regenerate(from: eff(cursorStyleBlink: false))
    XCTAssertEqual(content(), constLines + "cursor-style-blink = false\n")
  }

  /// cursorStyleBlink=nil（GUI 未介入）では行を出さない（他キーは残る）。
  func testCursorStyleBlinkNilOmitsLine() {
    GuiConfig.regenerate(from: eff(fontSize: 14, cursorStyleBlink: nil))
    XCTAssertEqual(content(), "font-size = 14\n" + constLines, "cursorStyleBlink 未設定は行を出さない")
  }
}
