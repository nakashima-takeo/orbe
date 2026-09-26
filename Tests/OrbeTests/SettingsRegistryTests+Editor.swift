import XCTest

@testable import Orbe

extension SettingsRegistryTests {
  /// エディターのエンジンの切り替え 3 件は toggle で gui.conf に出さない。既定は今のエンジン・弾性あり・太らせあり
  /// ——壊れると設定を触っていない人の文書が新しいエンジンで開く。
  func testEditorEngineSwitchesDefaultToTheCurrentEngine() {
    XCTAssertEqual(SettingsRegistry.descriptor(.editorEngineMetal).key, "editor-engine-metal")
    XCTAssertEqual(SettingsRegistry.descriptor(.editorScrollElastic).key, "editor-scroll-elastic")
    XCTAssertEqual(SettingsRegistry.descriptor(.editorFontSmoothing).key, "editor-font-smoothing")
    XCTAssertEqual(SettingsRegistry.descriptor(.editorEngineMetal).defaultValue(), .bool(false))
    XCTAssertEqual(SettingsRegistry.descriptor(.editorScrollElastic).defaultValue(), .bool(true))
    XCTAssertEqual(SettingsRegistry.descriptor(.editorFontSmoothing).defaultValue(), .bool(true))
    for id in [SettingID.editorEngineMetal, .editorScrollElastic, .editorFontSmoothing] {
      XCTAssertNil(SettingsRegistry.descriptor(id).guiConf, "\(id) は gui.conf に出さない")
      XCTAssertEqual(SettingsRegistry.descriptor(id).activation, .toggle)
    }
  }
}
