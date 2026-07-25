import XCTest

@testable import Orbe

/// 設定パレットの「worktree の作成場所」（root index 12）の検証。
/// 潜るとまずプリセット一覧（現在値に ●・最終行「カスタム…」）が出て、テキスト入力は「カスタム…」から
/// 1 段深く潜ったときだけ現れる。カスタム入力は実効テンプレートをプリフィルして入場し（注意行はその値から
/// 組む）、↵ 確定（空＝解除・不正＝先頭の注意行へ理由を出して留まる・妥当＝保存して root へ）、
/// Esc は保存せず一覧へ戻る。
/// `SettingsPaletteTests` の拡張として helper（`model`/`captureApply`）を共有する。
@MainActor
extension SettingsPaletteTests {
  /// worktreeDir 行（全行 index 12）からプリセット一覧へ潜る。
  private func drillIntoWorktreeDir(_ p: SettingsPaletteModel) {
    p.render.selected = 12
    p.render.onActivate()
  }

  /// プリセット一覧の最終行「カスタム…」からテキスト入力へ潜る。
  private func drillIntoCustom(_ p: SettingsPaletteModel) {
    drillIntoWorktreeDir(p)
    p.render.selected = customRow
    p.render.onActivate()
  }

  /// 「カスタム…」行の index（プリセットの次）。
  private var customRow: Int { WorktreePathTemplate.presets.count }

  /// 語彙の説明行（語ごとに 1 行）。注意の有無によらず常に出たままであること。
  private var vocabularyLabels: [String] {
    let l = LocalizationStore(language: .ja)
    return [
      l.string(.settingsWorktreeDirDescParent), l.string(.settingsWorktreeDirDescRepo),
      l.string(.settingsWorktreeDirDescRepoPath), l.string(.settingsWorktreeDirDescSlug),
      l.string(.settingsWorktreeDirDescTilde),
    ]
  }

  /// 説明行の先頭に差し込まれた注意（エラー理由 or 警告。無ければ nil）。
  private func notice(_ p: SettingsPaletteModel) -> String? {
    p.render.rows.count == vocabularyLabels.count ? nil : p.render.rows[0].label
  }

  /// 注意の有無にかかわらず説明行が末尾に揃っていること。
  private func assertVocabularyShown(_ p: SettingsPaletteModel, line: UInt = #line) {
    XCTAssertEqual(
      p.render.rows.suffix(vocabularyLabels.count).map(\.label), vocabularyLabels,
      "語彙の説明行は消さない", line: line)
    XCTAssertTrue(p.render.rows.allSatisfy { !$0.enabled }, "情報行は選択・実行の対象にしない", line: line)
  }

  // MARK: - root 行

  /// root 行は未設定でも実効値（既定テンプレート）を出し、drillIn の chevron を持つ。
  func testRootShowsWorktreeDirTemplate() {
    let p = model()
    XCTAssertTrue(p.render.rows[12].label.contains("worktree の作成場所"))
    XCTAssertTrue(p.render.rows[12].label.contains(WorktreePathTemplate.defaultTemplate))
    XCTAssertTrue(p.render.rows[12].chevron, "drillIn 行は chevron 有り")
  }

  // MARK: - プリセット一覧

  /// 潜るとプリセット＋「カスタム…」の一覧が出る（入力欄なし）。各行はラベル＋テンプレートの補足。
  func testWorktreeDirDrillInShowsPresetList() {
    let p = model()
    drillIntoWorktreeDir(p)
    XCTAssertEqual(p.render.breadcrumb, "‹ worktree の作成場所")
    XCTAssertFalse(p.render.fieldVisible, "一覧は絞り込み欄なし")
    XCTAssertEqual(p.render.rows.count, WorktreePathTemplate.presets.count + 1)
    XCTAssertTrue(p.render.rows[0].label.contains("リポジトリの隣（既定）"))
    XCTAssertEqual(p.render.rows[0].detail, WorktreePathTemplate.defaultTemplate, "補足はテンプレート文字列")
    XCTAssertTrue(p.render.rows[customRow].label.contains("カスタム…"))
    XCTAssertTrue(p.render.rows[customRow].chevron, "カスタム…だけが 1 段深い")
  }

  /// 現在値と一致するプリセット行に ● が付き、初期選択もその行に置かれる（未設定＝既定＝先頭行）。
  func testWorktreeDirPresetMarkerOnMatchingRow() {
    let p = model()
    drillIntoWorktreeDir(p)
    XCTAssertEqual(p.render.selected, 0, "既定と一致する行を初期選択")
    XCTAssertTrue(p.render.rows[0].label.hasPrefix("● "))
    XCTAssertFalse(p.render.rows[customRow].label.hasPrefix("● "))
  }

  /// 既定以外のプリセットを設定していれば、その行に ● と初期選択が乗る。
  func testWorktreeDirPresetMarkerOnConfiguredPreset() {
    let p = model(worktreeDir: WorktreePathTemplate.presets[2].template)
    drillIntoWorktreeDir(p)
    XCTAssertEqual(p.render.selected, 2)
    XCTAssertTrue(p.render.rows[2].label.hasPrefix("● "))
  }

  /// どのプリセットとも一致しない値は「カスタム…」行に ● が付き、その行の補足に現在値が出る。
  func testWorktreeDirCustomRowMarkedWhenNoPresetMatches() {
    let p = model(worktreeDir: "~/wt/{repo}/{slug}")
    drillIntoWorktreeDir(p)
    XCTAssertEqual(p.render.selected, customRow)
    XCTAssertTrue(p.render.rows[customRow].label.hasPrefix("● "))
    XCTAssertEqual(p.render.rows[customRow].detail, "~/wt/{repo}/{slug}", "一致しない現在値を補足に出す")
  }

  /// 一致するプリセットがあるときの「カスタム…」行は補足を持たない（現在値の在処が二重に出ない）。
  func testWorktreeDirCustomRowHasNoDetailWhenPresetMatches() {
    let p = model()
    drillIntoWorktreeDir(p)
    XCTAssertNil(p.render.rows[customRow].detail)
  }

  /// プリセット行の ↵ はそのテンプレートを保存して root へ戻る（1 打で決まる）。
  func testWorktreeDirPresetConfirmAppliesAndReturnsToRoot() {
    let p = model()
    drillIntoWorktreeDir(p)
    let applied = captureApply(p)
    p.render.selected = 1
    p.render.onActivate()
    XCTAssertEqual(
      applied()?[SettingKeys.worktreeDir], WorktreePathTemplate.presets[1].template)
    XCTAssertNil(p.render.breadcrumb, "root へ戻る")
    XCTAssertEqual(p.render.selected, 12, "潜った行へ選択を復元")
  }

  /// 一覧の Esc は保存せず root へ戻る。
  func testWorktreeDirPresetEscapeReturnsToRoot() {
    let p = model()
    drillIntoWorktreeDir(p)
    let applied = captureApply(p)
    p.render.onEscape()
    XCTAssertNil(applied())
    XCTAssertNil(p.render.breadcrumb)
    XCTAssertEqual(p.render.selected, 12)
  }

  /// 一覧は入力欄を持たないので ← も Esc と同じく root へ戻る（保存しない）。
  func testWorktreeDirPresetLeftReturnsToRoot() {
    let p = model()
    drillIntoWorktreeDir(p)
    let applied = captureApply(p)
    p.render.onLeft()
    XCTAssertNil(applied(), "← でも保存しない")
    XCTAssertNil(p.render.breadcrumb, "root へ戻る")
    XCTAssertEqual(p.render.selected, 12, "潜った行へ選択を復元")
  }

  /// → は「カスタム…」行だけで潜る（プリセット行の → は潜らない）。
  func testWorktreeDirRightArrowDrillsInOnlyFromCustomRow() {
    let p = model()
    drillIntoWorktreeDir(p)
    p.render.selected = 0
    XCTAssertFalse(p.render.onRight(), "プリセット行の → は潜らない")
    XCTAssertEqual(p.render.breadcrumb, "‹ worktree の作成場所", "一覧に留まる")
    p.render.selected = customRow
    XCTAssertTrue(p.render.onRight())
    XCTAssertEqual(p.render.breadcrumb, "‹ カスタム…", "カスタム入力へ潜る")
  }

  // MARK: - カスタム入力: editor 入力欄とプリフィル

  /// 「カスタム…」で潜ると editor 入力欄（← はカーソル移動）が出て、実効テンプレートがプリフィルされ、
  /// 行は語ごとに 1 行の説明（選択・実行の対象にしない）だけが並ぶ。
  func testWorktreeDirCustomPrefillsEffectiveTemplate() {
    let p = model()
    drillIntoCustom(p)
    XCTAssertEqual(p.render.breadcrumb, "‹ カスタム…")
    XCTAssertTrue(p.render.fieldVisible, "editor 入力欄が出る")
    XCTAssertFalse(p.render.fieldIsFilter, "editor＝← をカーソル移動に残す")
    XCTAssertEqual(p.render.query, WorktreePathTemplate.defaultTemplate, "未設定は既定テンプレートをプリフィル")
    XCTAssertNil(notice(p), "妥当な現在値では注意を出さない")
    assertVocabularyShown(p)
    XCTAssertEqual(
      p.render.rows.map(\.label),
      [
        "{parent} — リポジトリの親ディレクトリ", "{repo} — リポジトリ名", "{repo_path} — リポジトリの場所",
        "{slug} — ブランチ名（/ は - にする）", "先頭の ~ — ホームディレクトリ",
      ], "各行はトークンとその意味")
  }

  /// 設定済みならその値がプリフィルされる（現在値からの編集で始まる）。
  func testWorktreeDirCustomPrefillsConfiguredValue() {
    let p = model(worktreeDir: "~/wt/{repo}/{slug}")
    drillIntoCustom(p)
    XCTAssertEqual(p.render.query, "~/wt/{repo}/{slug}")
  }

  /// workspace スコープのプリフィルはそのスコープの実効値＝global 値を継承する。
  func testWorktreeDirWorkspacePrefillInheritsGlobal() {
    let p = model(worktreeDir: "~/wt/{repo}/{slug}", scope: .workspace)
    drillIntoCustom(p)
    XCTAssertEqual(p.render.query, "~/wt/{repo}/{slug}", "上書き無しの workspace は global 値を継承")
  }

  // MARK: - カスタム入力: ↵ 確定

  /// 妥当なテンプレートの ↵ は保存して root へ戻り、行表示が追従する。
  func testWorktreeDirValidConfirmAppliesAndReturnsToRoot() {
    let p = model()
    drillIntoCustom(p)
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
    drillIntoCustom(p)
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
    drillIntoCustom(p)
    var last: (SettingChange, SettingsScope)?
    p.onApply = { last = ($0, $1) }
    p.render.query = ""
    p.render.onQueryChange()
    p.render.onActivate()
    XCTAssertEqual(last?.0, SettingChange(id: .worktreeDir, value: nil))
    XCTAssertEqual(last?.1, .workspace)
  }

  /// 不正テンプレートの ↵ は適用せず入力モードに留まり、説明行の先頭に検証エラー理由が差し込まれる。
  func testWorktreeDirInvalidConfirmShowsErrorAndStays() {
    let p = model()
    drillIntoCustom(p)
    let applied = captureApply(p)
    p.render.query = "~/wt/{repo}"
    p.render.onQueryChange()
    p.render.onActivate()
    XCTAssertNil(applied(), "不正は適用しない")
    XCTAssertEqual(p.render.breadcrumb, "‹ カスタム…", "入力モードに留まる")
    XCTAssertEqual(notice(p), "{slug} を含めてください", "先頭にエラー理由が入る")
    assertVocabularyShown(p)
  }

  /// 不正確定後に編集すると、エラー行は消えて説明行だけに戻る（エラーは確定時にだけ評価する）。
  func testWorktreeDirErrorClearsOnEdit() {
    let p = model()
    drillIntoCustom(p)
    p.render.query = "~/wt/{repo}"
    p.render.onActivate()  // 不正確定 → エラー表示
    XCTAssertNotNil(notice(p))
    p.render.query = "~/wt/{repo}/{slug}"
    p.render.onQueryChange()  // 編集 → エラーを下げる
    XCTAssertNil(notice(p))
    assertVocabularyShown(p)
  }

  /// 未知プレースホルダはその断片つきでエラー理由が読める。
  func testWorktreeDirUnknownTokenErrorNamesToken() {
    let p = model()
    drillIntoCustom(p)
    p.render.query = "/wt/{branch}/{slug}"
    p.render.onActivate()
    XCTAssertEqual(notice(p), "不正なプレースホルダ: {branch}")
  }

  // MARK: - カスタム入力: repo を区別しないテンプレートの警告（保存は通す）

  /// 現在値が repo を区別しないなら、打鍵を待たず入場した時点で警告が出る
  /// （どのプリセットにも一致しない値＝「カスタム…」行に ● が乗る値なので、↵ 一発でここに着く）。
  func testWorktreeDirMissingRepoWarnsOnEntry() {
    let p = model(worktreeDir: "~/wt/{slug}")
    drillIntoCustom(p)
    XCTAssertEqual(p.render.query, "~/wt/{slug}", "実効テンプレートがプリフィルされる")
    XCTAssertEqual(
      notice(p), "{repo} も {repo_path} も無いため別リポジトリの同名ブランチと衝突します",
      "プリフィルした現在値に対して入場時点で警告する")
    assertVocabularyShown(p)
  }

  /// repo を区別しない妥当なテンプレートは警告するだけ——確定は通り root へ戻る。
  func testWorktreeDirMissingRepoWarnsButSaves() {
    let p = model()
    drillIntoCustom(p)
    let applied = captureApply(p)
    p.render.query = "~/wt/{slug}"
    p.render.onQueryChange()
    XCTAssertEqual(
      notice(p), "{repo} も {repo_path} も無いため別リポジトリの同名ブランチと衝突します", "入力に追従して警告が出る")
    p.render.onActivate()
    XCTAssertEqual(applied()?[SettingKeys.worktreeDir], "~/wt/{slug}", "警告しても保存は拒否しない")
    XCTAssertNil(p.render.breadcrumb, "root へ戻る")
  }

  /// `{repo_path}` は repo 固有の場所なので警告しない（repo 内配置プリセットがこの形）。
  func testWorktreeDirRepoPathDoesNotWarn() {
    let p = model(worktreeDir: "{repo_path}/.worktrees/{slug}")
    drillIntoCustom(p)
    XCTAssertNil(notice(p))
  }

  /// 警告は妥当なテンプレートにだけ出す（打鍵途中の不完全な入力では説明行のみ）。
  func testWorktreeDirMissingRepoWarningOnlyForValidTemplate() {
    let p = model()
    drillIntoCustom(p)
    p.render.query = "~/wt/{sl"
    p.render.onQueryChange()
    XCTAssertNil(notice(p))
    p.render.query = ""
    p.render.onQueryChange()
    XCTAssertNil(notice(p), "空（＝解除）は警告しない")
    assertVocabularyShown(p)
  }

  // MARK: - カスタム入力: Esc

  /// Esc は保存せずプリセット一覧へ 1 段戻る（潜った「カスタム…」行に選択が復元される）。
  func testWorktreeDirEscReturnsToPresetsWithoutApply() {
    let p = model()
    drillIntoCustom(p)
    let applied = captureApply(p)
    p.render.query = "~/wt/{repo}/{slug}"
    p.render.onEscape()
    XCTAssertNil(applied(), "Esc は保存しない")
    XCTAssertEqual(p.render.breadcrumb, "‹ worktree の作成場所", "プリセット一覧へ戻る")
    XCTAssertEqual(p.render.selected, customRow, "潜った「カスタム…」行へ選択を復元")
    p.render.onEscape()
    XCTAssertNil(p.render.breadcrumb, "もう 1 段で root")
    XCTAssertTrue(
      p.render.rows[12].label.contains(WorktreePathTemplate.defaultTemplate), "表示は元の実効値のまま")
  }
}
