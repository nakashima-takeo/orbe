import XCTest

@testable import Orbe

/// 設定パレットの「worktree の作成場所」テキスト入力サブパレット（root index 12・editor 型）の検証。
/// `SettingsPaletteTests` の拡張として helper（`model`/`captureApply`）を共有する。
/// workspace rename と同じ「setMode 後にプリフィル後入れ」の型で、確定は ↵（空＝解除・不正＝情報行へ
/// エラー理由を出して留まる・妥当＝保存して root 復帰）、Esc は保存せず root へ戻る。
@MainActor
extension SettingsPaletteTests {
  /// worktreeDir 行（全行 index 12）へ潜る。
  private func drillIntoWorktreeDir(_ p: SettingsPaletteModel) {
    p.render.selected = 12
    p.render.onActivate()
  }

  private var infoText: String {
    LocalizationStore(language: .ja).string(.settingsWorktreeDirInfo)
  }

  // MARK: - root 行

  /// root 行は未設定でも実効値（既定テンプレート）を出し、drillIn の chevron を持つ。
  func testRootShowsWorktreeDirTemplate() {
    let p = model()
    XCTAssertTrue(p.render.rows[12].label.contains("worktree の作成場所"))
    XCTAssertTrue(p.render.rows[12].label.contains(WorktreePathTemplate.defaultTemplate))
    XCTAssertTrue(p.render.rows[12].chevron, "drillIn 行は chevron 有り")
  }

  // MARK: - drillIn: editor 入力欄とプリフィル

  /// 潜ると editor 入力欄（← はカーソル移動）が出て、実効テンプレートがプリフィルされ、
  /// 行は語彙説明の情報行 1 行のみ（選択・実行の対象にしない）。
  func testWorktreeDirDrillInPrefillsEffectiveTemplate() {
    let p = model()
    drillIntoWorktreeDir(p)
    XCTAssertEqual(p.render.breadcrumb, "‹ worktree の作成場所")
    XCTAssertTrue(p.render.fieldVisible, "editor 入力欄が出る")
    XCTAssertFalse(p.render.fieldIsFilter, "editor＝← をカーソル移動に残す")
    XCTAssertEqual(p.render.query, WorktreePathTemplate.defaultTemplate, "未設定は既定テンプレートをプリフィル")
    XCTAssertEqual(p.render.rows.count, 1)
    XCTAssertFalse(p.render.rows[0].enabled, "情報行は選択・実行の対象にしない")
    XCTAssertEqual(p.render.rows[0].label, infoText, "通常時はプレースホルダ語彙の説明")
  }

  /// 設定済みならその値がプリフィルされる（現在値からの編集で始まる）。
  func testWorktreeDirDrillInPrefillsConfiguredValue() {
    let p = model(worktreeDir: "~/wt/{repo}/{slug}")
    drillIntoWorktreeDir(p)
    XCTAssertEqual(p.render.query, "~/wt/{repo}/{slug}")
  }

  /// workspace スコープのプリフィルはそのスコープの実効値＝global 値を継承する。
  func testWorktreeDirWorkspacePrefillInheritsGlobal() {
    let p = model(worktreeDir: "~/wt/{repo}/{slug}", scope: .workspace)
    drillIntoWorktreeDir(p)
    XCTAssertEqual(p.render.query, "~/wt/{repo}/{slug}", "上書き無しの workspace は global 値を継承")
  }

  // MARK: - ↵ 確定

  /// 妥当なテンプレートの ↵ は保存して root へ戻り、行表示が追従する。
  func testWorktreeDirValidConfirmAppliesAndReturnsToRoot() {
    let p = model()
    drillIntoWorktreeDir(p)
    let applied = captureApply(p)
    p.render.query = "~/wt/{repo}/{slug}"
    p.render.onQueryChange()
    p.render.onActivate()
    XCTAssertEqual(applied()?[SettingKeys.worktreeDir], "~/wt/{repo}/{slug}")
    XCTAssertNil(p.render.breadcrumb, "root へ戻る")
    XCTAssertEqual(p.render.selected, 12, "潜った行へ選択を復元")
    XCTAssertTrue(p.render.rows[12].label.contains("~/wt/{repo}/{slug}"), "行表示が更新される")
  }

  /// 全消し＋↵＝意図的な解除（nil 代入）。global は既定へ戻り root 表示も既定テンプレートになる。
  func testWorktreeDirEmptyConfirmClearsSetting() {
    let p = model(worktreeDir: "~/wt/{repo}/{slug}")
    drillIntoWorktreeDir(p)
    var appliedValue: String? = "SENTINEL"
    p.onApply = { change, _ in
      var layer = SettingsLayer()
      layer[SettingKeys.worktreeDir] = "SENTINEL"
      layer.apply(change)
      appliedValue = layer[SettingKeys.worktreeDir]
    }
    p.render.query = ""
    p.render.onQueryChange()
    p.render.onActivate()
    XCTAssertNil(appliedValue, "worktreeDir=nil（解除）を適用")
    XCTAssertNil(p.render.breadcrumb, "root へ戻る")
    XCTAssertTrue(p.render.rows[12].label.contains(WorktreePathTemplate.defaultTemplate), "既定へ戻る")
  }

  /// workspace スコープの解除は .workspace の単一代入で届く（継承へ戻る）。
  func testWorktreeDirEmptyConfirmInWorkspaceScope() {
    let p = model(worktreeDir: "~/wt/{repo}/{slug}", scope: .workspace)
    drillIntoWorktreeDir(p)
    var last: (SettingChange, SettingsScope)?
    p.onApply = { last = ($0, $1) }
    p.render.query = ""
    p.render.onQueryChange()
    p.render.onActivate()
    XCTAssertEqual(last?.0, SettingChange(id: .worktreeDir, value: nil))
    XCTAssertEqual(last?.1, .workspace)
  }

  /// 不正テンプレートの ↵ は適用せず入力モードに留まり、情報行が検証エラー理由に差し替わる。
  func testWorktreeDirInvalidConfirmShowsErrorAndStays() {
    let p = model()
    drillIntoWorktreeDir(p)
    let applied = captureApply(p)
    p.render.query = "~/wt/{repo}"
    p.render.onQueryChange()
    p.render.onActivate()
    XCTAssertNil(applied(), "不正は適用しない")
    XCTAssertEqual(p.render.breadcrumb, "‹ worktree の作成場所", "入力モードに留まる")
    XCTAssertEqual(p.render.rows[0].label, "{slug} を含めてください", "情報行がエラー理由に差し替わる")
  }

  /// 不正確定後に編集すると、エラー表示は語彙説明へ戻る（エラーは確定時にだけ評価する）。
  func testWorktreeDirErrorClearsOnEdit() {
    let p = model()
    drillIntoWorktreeDir(p)
    p.render.query = "~/wt/{repo}"
    p.render.onActivate()  // 不正確定 → エラー表示
    XCTAssertNotEqual(p.render.rows[0].label, infoText)
    p.render.query = "~/wt/{repo}/{slug}"
    p.render.onQueryChange()  // 編集 → エラーを下げる
    XCTAssertEqual(p.render.rows[0].label, infoText)
  }

  /// 未知プレースホルダはその断片つきでエラー理由が読める。
  func testWorktreeDirUnknownTokenErrorNamesToken() {
    let p = model()
    drillIntoWorktreeDir(p)
    p.render.query = "/wt/{branch}/{slug}"
    p.render.onActivate()
    XCTAssertEqual(p.render.rows[0].label, "不正なプレースホルダ: {branch}")
  }

  // MARK: - Esc

  /// Esc は保存せず root へ戻る（編集途中の値は捨てる）。
  func testWorktreeDirEscReturnsWithoutApply() {
    let p = model()
    drillIntoWorktreeDir(p)
    let applied = captureApply(p)
    p.render.query = "~/wt/{repo}/{slug}"
    p.render.onEscape()
    XCTAssertNil(applied(), "Esc は保存しない")
    XCTAssertNil(p.render.breadcrumb, "root へ戻る")
    XCTAssertEqual(p.render.selected, 12, "潜った行へ選択を復元")
    XCTAssertTrue(
      p.render.rows[12].label.contains(WorktreePathTemplate.defaultTemplate), "表示は元の実効値のまま")
  }
}
