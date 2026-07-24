import XCTest

@testable import Orbe

/// 設定パレットの worktree パステンプレ編集面（activation=textInput）のロジック検証。
/// 潜入時のバッファ・プリフィル、ライブ展開プレビュー、不正テンプレのインラインエラー＋確定阻止、
/// 妥当テンプレの確定（単一代入）を固定する（libghostty 非依存の @Observable モデルのみ）。
@MainActor
final class SettingsPaletteWorktreePathTests: XCTestCase {
  private func model(
    worktreePath: String? = nil, scope: SettingsScope = .global,
    override: SettingsLayer = SettingsLayer(), previewRoot: String = "/Users/dev/orbe"
  ) -> SettingsPaletteModel {
    var global = SettingsLayer()
    global[SettingKeys.worktreePath] = worktreePath
    return SettingsPaletteModel(
      values: ScopedSettingsValues(scope: scope, global: global, override: override),
      fontNames: [], agents: [], localization: LocalizationStore(language: .ja),
      worktreePreviewRoot: previewRoot)
  }

  private func captureApply(_ p: SettingsPaletteModel) -> () -> (SettingChange, SettingsScope)? {
    var applied: (SettingChange, SettingsScope)?
    p.onApply = { change, scope in applied = (change, scope) }
    return { applied }
  }

  /// 編集して onQueryChange を打つ（共有 PaletteCard の binding と同じ経路）。
  private func type(_ p: SettingsPaletteModel, _ text: String) {
    p.render.query = text
    p.render.onQueryChange()
  }

  // MARK: - 潜入・プリフィル・プレビュー

  /// 潜ると入力欄が現在の実効テンプレでプリフィルされ、プレビューが展開先を出す。
  func testDrillSeedsBufferAndPreview() {
    let p = model()  // 未設定＝既定テンプレへ解決
    p.drillIn(.worktreePath)
    XCTAssertEqual(p.render.query, WorktreePathTemplate.defaultTemplate, "実効テンプレをプリフィル")
    XCTAssertNil(p.render.errorText)
    XCTAssertEqual(p.render.rows.count, 1)
    XCTAssertTrue(
      p.render.rows[0].label.contains("/Users/dev/orbe-worktrees/issue-44"),
      "サンプルブランチ issue/44 で展開したプレビューを出す: \(p.render.rows[0].label)")
    XCTAssertFalse(p.render.rows[0].enabled, "プレビューは情報行（選択対象外）")
  }

  /// 打鍵でプレビューがライブに追従する。
  func testPreviewUpdatesLive() {
    let p = model()
    p.drillIn(.worktreePath)
    type(p, "~/wt/{slug}")
    XCTAssertNil(p.render.errorText)
    let home = NSHomeDirectory()
    XCTAssertTrue(p.render.rows[0].label.contains("\(home)/wt/issue-44"))
  }

  // MARK: - 検証（インラインエラー＋確定阻止）

  /// 不正テンプレ（{slug} 欠落）はエラーを出しプレビューを消し、↵ で確定しない。
  func testInvalidTemplateShowsErrorAndBlocksConfirm() {
    let p = model()
    let applied = captureApply(p)
    p.drillIn(.worktreePath)
    type(p, "wt/fixed")
    XCTAssertNotNil(p.render.errorText, "{slug} 欠落はインラインエラー")
    XCTAssertTrue(p.render.rows.isEmpty, "不正はプレビューを出さない")
    p.activate()  // ↵
    XCTAssertNil(applied(), "不正は確定しない（単一代入が飛ばない）")
  }

  func testUnknownTokenShowsError() {
    let p = model()
    p.drillIn(.worktreePath)
    type(p, "{owner}/{slug}")
    XCTAssertNotNil(p.render.errorText, "未知トークンはインラインエラー")
  }

  // MARK: - 確定（単一代入）

  /// 妥当テンプレは ↵ で現在スコープへ単一代入して確定する。
  func testValidTemplateConfirmsAndApplies() throws {
    let p = model()
    let applied = captureApply(p)
    p.drillIn(.worktreePath)
    type(p, "~/central/{repo}/{slug}")
    p.activate()  // ↵
    let (change, scope) = try XCTUnwrap(applied())
    XCTAssertEqual(change, SettingChange(SettingKeys.worktreePath, "~/central/{repo}/{slug}"))
    XCTAssertEqual(scope, .global)
  }

  /// workspace スコープでは上書き層へ単一代入する（二層が効く）。
  func testWorkspaceScopeAppliesToOverride() throws {
    let p = model(scope: .workspace)
    let applied = captureApply(p)
    p.drillIn(.worktreePath)
    type(p, "../{repo}-wt/{slug}")
    p.activate()
    let (_, scope) = try XCTUnwrap(applied())
    XCTAssertEqual(scope, .workspace)
  }
}
