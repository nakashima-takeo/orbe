import GhosttyKit
import XCTest

@testable import Orbe

/// 生成 conf（gui.conf）が libghostty に読まれて、設定パレットで選んだ値が端末に効くことを守る。
///
/// 壊れると、パレットで変えた値が端末に効かない・ユーザーの `~/.config/ghostty` を GUI が触っていない
/// キーまで上書きする・ghostty の解釈できない行が混ざる——どれも ghostty は診断を積むだけで起動し、
/// 画面の値だけが黙って違う。
final class GuiConfigTests: OrbeTestCase {

  override func setUpWithError() throws {
    try super.setUpWithError()
    // ghostty_config_new は ghostty_init 前に呼ぶと SIGSEGV する。ランタイムを先に起こす。
    _ = Ghostty.shared
  }

  // MARK: - libghostty で読んだ実効値

  /// パレットで選んだ値は、ユーザー層に同じキーがあっても libghostty の実効値になる。
  func testChosenValuesTakeEffectInGhosttyOverUserLayer() throws {
    try writeUserLayer(
      "font-size = 12\nbackground-opacity = 0.5\n"
        + "background-blur = false\ncursor-style-blink = true\n")

    GuiConfig.regenerate(
      from: settings(
        fontSize: 17, backgroundOpacity: 37, backgroundBlur: true, cursorStyleBlink: false))

    let cfg = Config.load()
    defer { ghostty_config_free(cfg) }
    XCTAssertEqual(get(Float.self, "font-size", cfg), 17)
    XCTAssertEqual(try XCTUnwrap(get(Double.self, "background-opacity", cfg)), 0.37, accuracy: 1e-9)
    XCTAssertEqual(get(Int16.self, "background-blur", cfg).map { $0 > 0 }, true, "ブラーが有効")
    XCTAssertEqual(get(Bool.self, "cursor-style-blink", cfg), false)
  }

  /// パレットが触っていないキーは gui.conf に出ず、ユーザー層の値がそのまま効く。
  func testUntouchedKeysLeaveUserLayerInEffect() throws {
    try writeUserLayer(
      "font-size = 12\nbackground-opacity = 0.5\n"
        + "background-blur = true\ncursor-style-blink = false\n")

    GuiConfig.regenerate(from: settings())

    let cfg = Config.load()
    defer { ghostty_config_free(cfg) }
    XCTAssertEqual(get(Float.self, "font-size", cfg), 12)
    XCTAssertEqual(try XCTUnwrap(get(Double.self, "background-opacity", cfg)), 0.5, accuracy: 1e-9)
    XCTAssertEqual(get(Int16.self, "background-blur", cfg).map { $0 > 0 }, true)
    XCTAssertEqual(get(Bool.self, "cursor-style-blink", cfg), false)
  }

  /// 全項目を立てた gui.conf を、libghostty は 1 行も拒まずに読む。
  func testEveryGeneratedLineIsAcceptedByGhostty() throws {
    var layer = settingsLayer(
      fontSize: 14, backgroundOpacity: 80, backgroundBlur: false, cursorStyleBlink: true)
    layer[SettingKeys.fontFamily] = "Menlo"
    layer[SettingKeys.emojiFont] = .noto
    layer[SettingKeys.theme] = .dark
    GuiConfig.regenerate(from: EffectiveSettings(layer))

    let cfg = Config.load()
    defer { ghostty_config_free(cfg) }
    XCTAssertEqual(diagnostics(cfg), [], "gui.conf に ghostty が解釈できない行がある")
  }

  // MARK: - 常に出る行・出ない行

  /// theme 行はパレットの値に関わらず常に出る（ユーザーの theme 指定を後勝ちで無効化し、端末色を
  /// Orbe のテーマに固定する）。絵文字の codepoint-map は noto のときだけ出る。
  func testThemeLineAlwaysPresentAndEmojiMapFollowsMode() throws {
    for theme in [nil, ThemeMode.auto, .light, .dark] {
      var layer = SettingsLayer()
      layer[SettingKeys.theme] = theme
      GuiConfig.regenerate(from: EffectiveSettings(layer))
      XCTAssertEqual(try lines(withKey: "theme").count, 1, "theme=\(String(describing: theme))")
    }

    GuiConfig.regenerate(from: settings())
    XCTAssertEqual(try lines(withKey: "font-codepoint-map").count, 1, "既定（noto）は map を出す")

    var apple = SettingsLayer()
    apple[SettingKeys.emojiFont] = .apple
    GuiConfig.regenerate(from: EffectiveSettings(apple))
    XCTAssertEqual(try lines(withKey: "font-codepoint-map"), [], "apple は map を出さない")
  }

  /// フォントを選ぶと、既定チェーンを空値で reset してから選んだ family を据える（reset が後に来ると
  /// 選択が消え、reset が無いと選択がチェーン末尾に回って使われない）。
  func testFontFamilyResetsChainBeforeChosenFamily() throws {
    var layer = SettingsLayer()
    layer[SettingKeys.fontFamily] = "SF Mono"
    GuiConfig.regenerate(from: EffectiveSettings(layer))
    XCTAssertEqual(
      try lines(withKey: "font-family"), ["font-family = \"\"", "font-family = SF Mono"])
  }

  /// gui.conf に出るのはフォント・テーマ・背景・カーソル・絵文字の項目だけ
  /// （spec platform/config.md）。それ以外の項目は、値を立てても gui.conf を変えない。
  func testOnlyTerminalAppearanceSettingsChangeGuiConf() throws {
    let terminalKeys: Set = [
      "font-size", "font-family", "theme", "emoji-font",
      "background-opacity", "background-blur", "cursor-style-blink",
    ]
    GuiConfig.regenerate(from: settings())
    let baseline = try content()

    var changing: [String] = []
    for descriptor in SettingsRegistry.all {
      GuiConfig.regenerate(
        from: EffectiveSettings(SettingsLayer([descriptor.id: sampleValue(for: descriptor)])))
      if try content() != baseline { changing.append(descriptor.key) }
    }
    XCTAssertTrue(changing.contains("font-size"), "値を立てても何も変わらない＝検査が空振りしている")
    XCTAssertEqual(
      Set(changing).subtracting(terminalKeys), [], "端末の見た目以外の項目が gui.conf に出ている")
  }

  // MARK: - 補助

  private func settingsLayer(
    fontSize: Int? = nil, backgroundOpacity: Int? = nil, backgroundBlur: Bool? = nil,
    cursorStyleBlink: Bool? = nil
  ) -> SettingsLayer {
    var layer = SettingsLayer()
    layer[SettingKeys.fontSize] = fontSize
    layer[SettingKeys.backgroundOpacity] = backgroundOpacity
    layer[SettingKeys.backgroundBlur] = backgroundBlur
    layer[SettingKeys.cursorStyleBlink] = cursorStyleBlink
    return layer
  }

  private func settings(
    fontSize: Int? = nil, backgroundOpacity: Int? = nil, backgroundBlur: Bool? = nil,
    cursorStyleBlink: Bool? = nil
  ) -> EffectiveSettings {
    EffectiveSettings(
      settingsLayer(
        fontSize: fontSize, backgroundOpacity: backgroundOpacity, backgroundBlur: backgroundBlur,
        cursorStyleBlink: cursorStyleBlink))
  }

  /// その項目の値域に収まる、何か 1 つの値（gui.conf に出るかどうかは値の有無で決まる）。
  private func sampleValue(for descriptor: SettingDescriptor) -> SettingValue {
    switch descriptor.domain {
    case .intRange(let range, _, _): return .int(range.lowerBound)
    case .toggle: return .bool(false)
    case .enumeration(let values): return .string(values().last ?? "sample")
    case .stringMap: return .stringMap(["file": "/tmp/sample.wav"])
    case .pathTemplate: return .string("~/worktrees/{slug}")
    }
  }

  private func writeUserLayer(_ text: String) throws {
    let url = try XCTUnwrap(Config.userFileURLOverride)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  private func content() throws -> String {
    try String(contentsOf: guiConfFile(), encoding: .utf8)
  }

  private func lines(withKey key: String) throws -> [String] {
    try content().split(separator: "\n").map(String.init).filter { $0.hasPrefix("\(key) =") }
  }

  /// `ghostty_config_get` は書き込むバイト数を型で決めるため、キーごとの型を誤るとメモリを壊す。
  /// font-size は f32・background-opacity は f64・background-blur は i16・cursor-style-blink は bool。
  /// 値が無い（optional が未設定）ときは nil。
  private func get<T: Numeric>(_ type: T.Type, _ key: String, _ cfg: ghostty_config_t) -> T? {
    var value: T = 0
    let ok = key.withCString { ghostty_config_get(cfg, &value, $0, UInt(key.utf8.count)) }
    return ok ? value : nil
  }

  private func get(_ type: Bool.Type, _ key: String, _ cfg: ghostty_config_t) -> Bool? {
    var value = false
    let ok = key.withCString { ghostty_config_get(cfg, &value, $0, UInt(key.utf8.count)) }
    return ok ? value : nil
  }

  private func diagnostics(_ cfg: ghostty_config_t) -> [String] {
    (0..<ghostty_config_diagnostics_count(cfg)).map {
      String(cString: ghostty_config_get_diagnostic(cfg, $0).message)
    }
  }
}
