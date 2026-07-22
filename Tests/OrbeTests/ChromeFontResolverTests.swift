import AppKit
import XCTest

@testable import Orbe

/// chrome フォント割り当て機構（TitleGlyphs 一般化・ChromeFontResolver・FontCatalog.resolve）の検証。
/// バンドル無し（swift test）では同梱 TTF が解決できないため、割り当ての有無と退避だけを固定し、
/// 実フォントの字形は実機確認が担う。
final class ChromeFontResolverTests: XCTestCase {

  private let base = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

  // MARK: - TitleGlyphs.needsAssignment（本文行の早期打ち切り判定）

  /// 端末系グリフ/絵文字を含まない文字列（本文行の大半）は割り当て不要＝素の Text のまま。
  func testNeedsAssignmentFalseForPlainText() {
    XCTAssertFalse(TitleGlyphs.needsAssignment("let x = 1  // plain"))
    XCTAssertFalse(TitleGlyphs.needsAssignment("日本語のパス/ファイル名.swift"))
    XCTAssertFalse(TitleGlyphs.needsAssignment(""))
  }

  /// 絵文字（emoji-presentation・VS16 昇格対象）・私用領域・点字は割り当てが要る。
  func testNeedsAssignmentTrueForGlyphTargets() {
    XCTAssertTrue(TitleGlyphs.needsAssignment("fix 😀 bug"))
    XCTAssertTrue(TitleGlyphs.needsAssignment("✳ Claude"), "VS16 昇格対象（text 既定の emoji 可能記号）")
    XCTAssertTrue(TitleGlyphs.needsAssignment("\u{E0A0} branch"), "Nerd（私用領域）")
    XCTAssertTrue(TitleGlyphs.needsAssignment("⣷ spinner"), "点字")
  }

  // MARK: - TitleGlyphs.attributed / width（基底フォント引数化）

  /// emoji=nil（Apple へ委譲・degrade）では絵文字 run にフォントを埋めない（view の .font() を継承）。
  func testAttributedWithNilEmojiLeavesRunsUnassigned() {
    let out = TitleGlyphs.attributed("a😀b", base: base, emoji: nil)
    for run in out.runs {
      XCTAssertNil(run.font, "割り当てなし＝全 run 無指定")
    }
  }

  /// emoji フォント指定時は絵文字 run にだけフォントが乗る（他 run は無指定＝view の .font() 継承）。
  func testAttributedAssignsFontOnlyToEmojiRun() throws {
    let emoji = try XCTUnwrap(NSFont(name: "Menlo", size: 12))  // 実フォントで代用（割り当てだけ見る）
    let out = TitleGlyphs.attributed("a😀", base: base, emoji: emoji)
    let assigned = out.runs.filter { $0.font != nil }
    XCTAssertEqual(assigned.count, 1, "絵文字 run にだけフォントが乗る")
    XCTAssertEqual(String(out.runs.first { $0.font != nil }.map { out[$0.range] }!.characters), "😀")
  }

  /// text 既定の emoji 可能記号（✳）は VS16 を足して emoji run へ昇格し、emoji フォントが乗る。
  func testAttributedPromotesTextSymbolWithVS16() throws {
    let emoji = try XCTUnwrap(NSFont(name: "Menlo", size: 12))  // 実フォントで代用（割り当てだけ見る）
    let out = TitleGlyphs.attributed("✳", base: base, emoji: emoji)
    XCTAssertEqual(String(out.characters), "✳\u{FE0F}", "VS16 を付与してカラー presentation へ昇格")
    XCTAssertEqual(out.runs.filter { $0.font != nil }.count, 1, "昇格記号が emoji run としてフォント割り当て")
  }

  /// 幅計測は描画と同じ割り当てで、プレーン文字列は基底フォント幅と一致する。
  func testWidthMatchesBaseFontForPlainText() {
    let expected = ("plain title" as NSString).size(withAttributes: [.font: base]).width
    XCTAssertEqual(TitleGlyphs.width("plain title", base: base, emoji: nil), expected)
  }

  /// 絵文字 run の幅は emoji フォントを基底サイズへ揃えて測る（12pt 指定でも 11pt 基底なら 11pt 幅）。
  func testWidthResizesEmojiFontToBaseSize() throws {
    let emoji = try XCTUnwrap(NSFont(name: "Menlo", size: 12))
    let resized = try XCTUnwrap(NSFont(descriptor: emoji.fontDescriptor, size: base.pointSize))
    let expected = ("😀" as NSString).size(withAttributes: [.font: resized]).width
    XCTAssertEqual(TitleGlyphs.width("😀", base: base, emoji: emoji), expected)
  }

  // MARK: - FontCatalog.resolve（family 厳密解決）

  func testResolveKnownFamilyAtRequestedSize() throws {
    let font = try XCTUnwrap(FontCatalog.resolve(family: "Menlo", size: 11))
    XCTAssertEqual(font.familyName, "Menlo")
    XCTAssertEqual(font.pointSize, 11)
  }

  func testResolveUnknownFamilyReturnsNil() {
    XCTAssertNil(FontCatalog.resolve(family: "存在しないファミリ名 XYZ", size: 11))
  }

  // MARK: - ChromeFontResolver（既定と Text ファクトリ）

  /// 既定はタブタイトル＝システム等幅 11pt・絵文字＝同梱 Noto（バンドル無しは nil＝Apple 委譲）。
  func testResolverDefaults() {
    let r = ChromeFontResolver()
    XCTAssertEqual(r.tabTitleFont, Theme.Typography.chrome)
    XCTAssertEqual(r.emojiFont, TitleGlyphs.notoEmoji)
  }

  // MARK: - WindowController 結線（applyActiveWorkspaceConfig → resolver）

  private func withIsolatedState(_ body: () -> Void) {
    let dir = FileManager.default.temporaryDirectory
    let uuid = UUID().uuidString
    SettingsPersistence.fileURLOverride = dir.appendingPathComponent("cfr-settings-\(uuid).json")
    AppStatePersistence.fileURLOverride = dir.appendingPathComponent("cfr-appstate-\(uuid).json")
    WorkspacePersistence.fileURLOverride = dir.appendingPathComponent("cfr-ws-\(uuid).json")
    GuiConfig.fileURLOverride = dir.appendingPathComponent("cfr-gui-\(uuid).conf")
    defer {
      for url in [
        SettingsPersistence.fileURLOverride, AppStatePersistence.fileURLOverride,
        WorkspacePersistence.fileURLOverride, GuiConfig.fileURLOverride,
      ] {
        if let url { try? FileManager.default.removeItem(at: url) }
      }
      SettingsPersistence.fileURLOverride = nil
      AppStatePersistence.fileURLOverride = nil
      WorkspacePersistence.fileURLOverride = nil
      GuiConfig.fileURLOverride = nil
    }
    body()
  }

  /// tab-title-font-family の設定・解決不能名・解除が resolver のタブタイトルフォントを駆動する。
  @MainActor
  func testTabTitleFontSettingDrivesResolver() {
    withIsolatedState {
      let wc = WindowController()
      wc.settingsStore.applyGlobal(SettingChange(SettingKeys.tabTitleFontFamily, "Menlo"))
      wc.applyActiveWorkspaceConfig()
      XCTAssertEqual(wc.fontResolver.tabTitleFont.familyName, "Menlo")
      XCTAssertEqual(wc.fontResolver.tabTitleFont.pointSize, 11, "タブタイトルは 11pt 固定")

      wc.settingsStore.applyGlobal(SettingChange(SettingKeys.tabTitleFontFamily, "存在しない名前"))
      wc.applyActiveWorkspaceConfig()
      XCTAssertEqual(
        wc.fontResolver.tabTitleFont, Theme.Typography.chrome, "解決不能名は既定へ退避（クラッシュしない）")

      wc.settingsStore.applyGlobal(SettingChange(id: .tabTitleFontFamily, value: nil))
      wc.applyActiveWorkspaceConfig()
      XCTAssertEqual(wc.fontResolver.tabTitleFont, Theme.Typography.chrome, "解除＝既定へ")
    }
  }

  /// emoji-font の noto/apple 切替が resolver の絵文字フォント（Noto / nil＝Apple 委譲）を駆動する。
  @MainActor
  func testEmojiFontSettingDrivesResolver() {
    withIsolatedState {
      let wc = WindowController()
      XCTAssertEqual(wc.fontResolver.emojiFont, TitleGlyphs.notoEmoji, "実効既定 noto")

      wc.settingsStore.applyGlobal(SettingChange(SettingKeys.emojiFont, EmojiFontMode.apple))
      wc.applyActiveWorkspaceConfig()
      XCTAssertNil(wc.fontResolver.emojiFont, "apple＝割り当てなし（Apple Color Emoji へ委譲）")

      wc.settingsStore.applyGlobal(SettingChange(SettingKeys.emojiFont, EmojiFontMode.noto))
      wc.applyActiveWorkspaceConfig()
      XCTAssertEqual(wc.fontResolver.emojiFont, TitleGlyphs.notoEmoji, "noto へ復帰")
    }
  }
}
