import SwiftUI

/// Cmd+, で開く設定パレットの状態機械（ドリルイン式）。
///
/// - root（絞り込み入力欄あり）: 先頭に「スコープ」行（グローバル ⇄ この workspace）、続いてレジストリの設定行を
///   現在値つきで出す。↑↓ で行選択、スコープ行は ←/→/↵ で反転、stepper 行は ←→ で増減、toggle 行は
///   ←/→/↵ で反転、drillIn 行は ↵/→ で潜る、Esc で閉じる。workspace スコープでは行を delete で上書き解除
///   （global 継承へ戻す）——絞り込み欄フォーカス中はクエリ空のときだけ delete が継承解除・非空なら文字削除。
/// - font/tabTitleFont/emojiFont/theme/agent/agentStates/agentIcon/notificationSound: サブパレット
///   （`SettingsPaletteModel+Subpalette`）。通知音だけは行の移動がその場の試聴を伴う
///   （`SettingsPaletteModel+Sound`）。
///
/// 全設定は同じ `onApply`（単一代入 `SettingChange`＋スコープ）で global（settings.json）か workspace 上書きへ
/// 反映し、生成 conf 再生成・ライブ反映は提示元（WindowController）が担う（defaultAgent/devFeatures も同経路）。
/// 値の解決と表示は `ScopedSettingsValues` に閉じる。
@Observable final class SettingsPaletteModel {
  /// 設定変更を適用する。単一代入とスコープを渡し、対象への保存・生成 conf 再生成・ライブ反映は提示元が行う。
  var onApply: (SettingChange, SettingsScope) -> Void = { _, _ in }
  var onDismiss: () -> Void = {}
  /// UI 言語の選択を提示元へ通知する（descriptor 非経由の特別行＝レジストリの SettingChange と別経路）。
  /// 提示元が「ストア更新 → メインメニュー再構築 → preferredLanguage 永続化」を束ねる。
  var onSelectLanguage: (Language) -> Void = { _ in }
  /// グローバル ⌘⌘ 権限行の ↵/→ で System Settings（Accessibility）を開く（提示元が配線）。
  var onOpenAccessibilitySettings: () -> Void = {}
  /// 通知音サブパレットの試聴（nil＝鳴らさず止めるだけ＝「なし」行）。提示元が再生層へ繋ぐ。
  /// **設定は書かない**——聴くことと決めることを分けてある（書くのは ↵ の確定だけ）。
  var onPreviewSound: ((NotificationSound?, AgentSoundEvent) -> Void)?

  /// 現在の UI 言語ホルダー。言語行のマーカー・root 行の現在値表示・自身の文言（breadcrumb/hint）が読む。
  let localization: LocalizationStore

  // ドリル遷移（drillIn/returnTo*）を `SettingsPaletteModel+Navigation` へ分離するため internal。
  enum Mode {
    case root, font, tabTitleFont, emojiFont, theme, agent, agentStates,
      agentIcon(AgentStateIcon.Kind), worktreeDirPresets, worktreeDirCustom, language, update,
      notificationSound
  }

  /// root 行。先頭のスコープ切替行と、レジストリ表示順の各設定行。
  /// キー操作は行 index でなくこの kind で分岐する（スコープ行の差し込みで index がズレないため）。
  /// 行組み立て（`SettingsPaletteModel+Root`）と共有するため internal。
  enum RootRow {
    case scope
    case setting(SettingDescriptor)
    case language  // レジストリ非経由の特別行（UI 言語のドリルイン）。末尾固定。
    case update  // レジストリ非経由の特別行（アップデートのドリルイン）。言語の後ろ・末尾固定。
    case cmdTapPermission  // グローバル ⌘⌘（メニューバー）の権限状態行。設定値ではない（読み取り表示のみ）。
  }

  // ドリル復元（drillIn が全行 index を引く）で `+Navigation` が使うため internal。
  let rootOrder = SettingsRegistry.rootOrder
  var rootRows: [RootRow] {
    [.scope] + rootOrder.map { .setting($0) } + [.language] + (update == nil ? [] : [.update])
      + (cmdTapPermissionGranted == nil ? [] : [.cmdTapPermission])
  }
  /// 絞り込み後に実際に表示している root 行（選択 index → 行の対応）。クエリ空なら `rootRows` 全行。
  var visibleRootRows: [RootRow] = []

  let render = PaletteModel()
  private var mode: Mode = .root
  /// 面の組み立て中（`setMode`/`rebuild`）の選択代入で試聴が鳴るのを止める。入場では鳴らさない。
  /// 試聴の実装（`SettingsPaletteModel+Sound`）が読むため internal。
  var suppressPreview = false
  /// 潜る前にいた root 行の「全行 rootRows での index」（既定は先頭設定行）。
  var rootRowBeforeDrill = 1
  /// 状態一覧からアイコン候補へ潜る前にいた状態行の index（agentIcon から agentStates へ戻る復元用）。
  var stateRowBeforeDrill = 0

  // 以下は行組み立て（`SettingsPaletteModel+Subpalette.swift`）と共有するため internal。

  /// 現在値の行 index（サブモードの表示行に対する。root と、現在値が表示行に無いときは nil）。
  var currentRowIndex: Int?

  /// 通知音サブパレットの試聴対象（完了 / 入力待ち）。⇥ で反転する**面の状態**で、設定には書かない。
  /// 入場のたび `.done` へ戻す（前回を持ち越すと、開いた瞬間に何が鳴るか予測できないため）。
  var previewEvent: AgentSoundEvent = .done

  /// worktreeDir 入力の直前の不正確定理由（語彙の説明行の先頭に差し込んで出す）。
  /// 編集（queryChanged）と入場（drillIn）でクリアし、エラーは確定時にだけ評価する。
  var worktreeDirError: String?

  /// 設定値の解決モデル（global 層・workspace 上書き層・現在スコープ・表示の語彙）。
  var values: ScopedSettingsValues
  /// アップデートの状態モデル（nil＝アップデート面なし。テスト・provider 無し環境では行ごと出さない）。
  let update: UpdateState?
  let fontNames: [String]
  /// 全 family（等幅制限なし）。タブタイトルフォントサブパレットの列挙が使う。
  let allFontNames: [String]
  let agents: [String]  // 検出済み agent コマンド（起動パレットと同じ検出結果）
  /// グローバル ⌘⌘（背面 global monitor）の権限判定。nil＝行を出さない（テスト・gallery の既定）。
  /// 開くたびに評価する（System Settings で付与して戻った直後の再表示に追従）。
  let cmdTapPermissionGranted: (() -> Bool)?
  /// theme サブパレットの固定3択（見本 Settings 画面の Seg 順）。選択 index → ThemeMode の対応。
  static let themeModes: [ThemeMode] = [.auto, .dark, .light]
  /// emoji フォントサブパレットの固定2択（既定 Noto を先頭）。選択 index → EmojiFontMode の対応。
  static let emojiFontModes: [EmojiFontMode] = [.noto, .apple]
  // filter 型フォントサブ（font / tabTitleFont・モード排他）で現在表示中の名前（選択 index → 名前の対応）
  // と、先頭に解除行を出しているか（クエリ空のときだけ）。
  var fontRows: [String] = []
  var fontDefaultRowVisible = false

  /// 実際に起動される default agent。`AgentLauncher` と同一規則で現在スコープの実効値から解決する
  /// （生値が未設定・未検出でも検出先頭へフォールバック）。root 表示・サブの ●・初期ハイライトがこの 1 つを読む。
  var resolvedAgent: String? {
    AgentLauncher.resolveDefault(configured: values.effDefaultAgent, detected: agents)
  }

  init(
    values: ScopedSettingsValues, fontNames: [String], allFontNames: [String] = [],
    agents: [String], localization: LocalizationStore, update: UpdateState? = nil,
    cmdTapPermissionGranted: (() -> Bool)? = nil
  ) {
    self.values = values
    self.update = update
    self.fontNames = fontNames
    self.allFontNames = allFontNames
    self.agents = agents
    self.localization = localization
    self.cmdTapPermissionGranted = cmdTapPermissionGranted
    render.onScrimTap = { [weak self] in self?.onDismiss() }
    render.onTapRow = { [weak self] i in
      self?.render.selected = i
      self?.activate()
    }
    render.onUp = { [weak self] in self?.render.move(-1) }
    render.onDown = { [weak self] in self?.render.move(1) }
    render.onJumpTop = { [weak self] in self?.render.jump(-1) }
    render.onJumpBottom = { [weak self] in self?.render.jump(1) }
    render.onActivate = { [weak self] in self?.activate() }
    render.onLeft = { [weak self] in self?.leftArrow() }
    render.onRight = { [weak self] in self?.rightArrow() ?? false }
    render.onEscape = { [weak self] in self?.escape() }
    render.onDelete = { [weak self] in self?.deleteKey() }
    render.onQueryChange = { [weak self] in self?.queryChanged() }
    render.onSelectionChanged = { [weak self] _ in self?.selectionChanged() }
    render.onTab = { [weak self] in self?.togglePreviewEvent() ?? false }
    rebuild()
    render.selected = 1  // スコープ行（index 0）でなく先頭の設定行（フォントサイズ）を初期選択にする
  }

  /// 通知音サブパレットにいるか（試聴の分離ファイルが `mode` を直に見ないための問い）。
  var isNotificationSoundMode: Bool {
    if case .notificationSound = mode { return true }
    return false
  }

  /// first responder を現在のモードへ移す（focusToken を進め、SwiftUI が描画後に focus を確定する）。
  func focus() { render.focus() }

  /// 単一代入を values へ反映し、提示元へ通知する（面ごとの確定処理も必ずこの漏斗を通す）。
  func assign(_ change: SettingChange) {
    values.apply(change)
    onApply(change, values.scope)
  }

  // MARK: - 操作の意味（キー意図とテストの両方がここを駆動する）

  func activate() {
    switch mode {
    case .root: activateRootRow()
    case .font:
      confirmFilter(rows: fontRows, defaultRowVisible: fontDefaultRowVisible) {
        SettingChange(SettingKeys.fontFamily, $0)
      }
    case .tabTitleFont:
      confirmFilter(rows: fontRows, defaultRowVisible: fontDefaultRowVisible) {
        SettingChange(SettingKeys.tabTitleFontFamily, $0)
      }
    case .emojiFont:
      guard Self.emojiFontModes.indices.contains(render.selected) else { return }
      assign(SettingChange(SettingKeys.emojiFont, Self.emojiFontModes[render.selected]))
      returnToRoot()
    case .theme:
      guard Self.themeModes.indices.contains(render.selected) else { return }
      assign(SettingChange(SettingKeys.theme, Self.themeModes[render.selected]))
      returnToRoot()
    case .agent:
      guard agents.indices.contains(render.selected) else { return }
      assign(SettingChange(SettingKeys.defaultAgent, agents[render.selected]))
      returnToRoot()
    case .agentStates:
      guard AgentStateIcon.Kind.allCases.indices.contains(render.selected) else { return }
      drillIntoState(AgentStateIcon.Kind.allCases[render.selected])
    case .agentIcon(let kind):
      let symbols = AgentStateIcon.curatedSymbols[kind] ?? []
      // 行 0＝Glass（既定・nil）、以降は curated symbol。範囲外は no-op。
      guard (0...symbols.count).contains(render.selected) else { return }
      let symbol = render.selected == 0 ? nil : symbols[render.selected - 1]
      assign(values.agentStateIconChange(kind: kind, symbol: symbol))
      returnToStates()
    case .worktreeDirPresets:
      activateWorktreeDirPresetRow()
    case .worktreeDirCustom:
      confirmWorktreeDir()
    case .language:
      guard Language.allCases.indices.contains(render.selected) else { return }
      onSelectLanguage(Language.allCases[render.selected])  // ストア更新はここで反映される
      returnToRoot()  // 新言語で root を組み直す
    case .update:
      activateUpdateRow()
    case .notificationSound:
      activateNotificationSoundRow()
    }
  }

  /// root 行の ↵。スコープ行は反転、toggle 行は反転、drillIn 行は潜る、stepper 行は no-op。
  private func activateRootRow() {
    guard visibleRootRows.indices.contains(render.selected) else { return }
    switch visibleRootRows[render.selected] {
    case .scope: toggleScope()
    case .setting(let d):
      switch d.activation {
      case .stepper: break  // stepper 行の Enter は no-op（現状維持）
      case .toggle: toggleValue(d)
      case .drillIn: drillIn(d.id)
      }
    case .language: drillIntoLanguage()
    case .update: drillIntoUpdate()
    case .cmdTapPermission: onOpenAccessibilitySettings()  // 権限あり時も System Settings を開くだけ
    }
  }

  /// filter モード（font）の ↵ 確定。先頭の既定行は nil 代入（＝既定チェーンへ戻す）、名前行はその値を
  /// 代入し root へ戻る。空状態の情報行では何もしない。`change` は選択値（or nil）を単一代入へ橋渡す。
  private func confirmFilter(
    rows: [String], defaultRowVisible: Bool, change: (String?) -> SettingChange
  ) {
    if defaultRowVisible && render.selected == 0 {  // 既定行 → 上書き/global を解除し既定チェーンへ
      assign(change(nil))
      returnToRoot()
      return
    }
    let i = render.selected - (defaultRowVisible ? 1 : 0)
    guard rows.indices.contains(i) else { return }  // 空状態の情報行では何もしない
    assign(change(rows[i]))
    returnToRoot()
  }

  /// ← ＝戻る/減算/反転。root のスコープ行/toggle 行は反転、stepper 行は減算、サブモードでは root へ戻る。
  private func leftArrow() {
    switch mode {
    case .root:
      guard visibleRootRows.indices.contains(render.selected) else { return }
      switch visibleRootRows[render.selected] {
      case .scope: toggleScope()
      case .setting(let d):
        switch d.activation {
        case .stepper: adjustStepper(d, -1)
        case .toggle: toggleValue(d)
        case .drillIn: break
        }
      case .language, .update, .cmdTapPermission: break  // drillIn 行と同じく ← は無反応
      }
    case .font, .tabTitleFont, .emojiFont, .theme, .agent, .agentStates, .worktreeDirPresets,
      .language, .update, .notificationSound:
      returnToRoot()
    case .worktreeDirCustom: break  // editor 入力欄の ← はカーソル移動（ここへは届かない）。戻るは esc
    case .agentIcon: returnToStates()  // 1 段ずつ浅く（アイコン候補→状態一覧）
    }
  }

  /// → の意味。true を返すとキーを消費。root のスコープ行/toggle 行は反転、stepper 行は増算、drillIn 行は潜る。
  private func rightArrow() -> Bool {
    if case .agentStates = mode {
      activate()  // → は状態一覧からアイコン候補へ潜る（↵ と同義）
      return true
    }
    if case .update = mode {
      rightArrowUpdateRow()  // トグル行は反転、他は no-op（↵ と同じ意味の部分集合）
      return true
    }
    if case .worktreeDirPresets = mode {
      // → は「潜る」意味だけを持つ。1 段深いのは chevron のある「カスタム…」行だけ。
      guard render.selected == worktreeDirCustomRow else { return false }
      drillIntoWorktreeDirCustom()
      return true
    }
    guard case .root = mode, visibleRootRows.indices.contains(render.selected) else { return false }
    switch visibleRootRows[render.selected] {
    case .scope: toggleScope()
    case .setting(let d):
      switch d.activation {
      case .stepper: adjustStepper(d, 1)
      case .toggle: toggleValue(d)
      case .drillIn: drillIn(d.id)
      }
    case .language: drillIntoLanguage()
    case .update: drillIntoUpdate()
    case .cmdTapPermission: onOpenAccessibilitySettings()
    }
    return true
  }

  /// delete＝workspace スコープの上書き行を解除して global 継承へ戻す（root のみ）。
  private func deleteKey() {
    guard case .root = mode, values.scope == .workspace,
      visibleRootRows.indices.contains(render.selected),
      case .setting(let d) = visibleRootRows[render.selected],
      values.isOverriddenByWorkspace(d.id)
    else { return }
    assign(values.clearChange(for: d.id))
    rebuild()
  }

  /// スコープを反転して root を再構築する。
  private func toggleScope() {
    values.toggleScope()
    rebuild()
  }

  /// Esc。root では閉じ、サブモードでは 1 段ずつ浅くなる。worktreeDir のカスタム入力は保存せず一覧へ戻る。
  private func escape() {
    switch mode {
    case .root: onDismiss()
    case .font, .tabTitleFont, .emojiFont, .theme, .agent, .agentStates, .worktreeDirPresets,
      .language, .update, .notificationSound:
      returnToRoot()
    case .agentIcon: returnToStates()  // 1 段ずつ浅く
    case .worktreeDirCustom: returnToWorktreeDirPresets()  // 同上（カスタム入力→プリセット一覧）
    }
  }

  private func queryChanged() {
    switch mode {
    case .root, .font, .tabTitleFont: break  // フィルタ入力を持つモードのみ再構築
    case .worktreeDirCustom:
      // 編集は不正確定のエラー表示を下げ（エラーは確定時にだけ評価する）、repo を区別しない旨の警告を
      // 入力へ追従させる。行はすべて選択不可の情報行なので選択は動かさない。
      worktreeDirError = nil
      rebuild()
      return
    default: return
    }
    render.selected = 0  // 行集合が入れ替わるため選択は先頭へ戻す
    rebuild()
  }

  /// direction は ±1。範囲・刻みは descriptor の domain から読む。現在値は実効値（スコープ依存）。
  private func adjustStepper(_ d: SettingDescriptor, _ direction: Int) {
    guard case .intRange(let range, let step, _) = d.domain,
      case .int(let current) = values.effectiveValue(d.id)
    else { return }
    let clamped = min(range.upperBound, max(range.lowerBound, current + direction * step))
    guard clamped != current else { return }  // 範囲端ではクランプして適用しない
    assign(SettingChange(id: d.id, value: .int(clamped)))
    rebuild()
  }

  /// toggle 行の値を反転して適用する。←/→/↵ すべてこれを呼び、毎回反転を適用する（端クランプは無い）。
  private func toggleValue(_ d: SettingDescriptor) {
    guard case .toggle = d.activation, case .bool(let current) = values.effectiveValue(d.id) else {
      return
    }
    assign(SettingChange(id: d.id, value: .bool(!current)))
    rebuild()
  }

  // MARK: - モード遷移・描画

  /// mode を切り替えて行を組み直し、選択を決める（ドリル遷移は `SettingsPaletteModel+Navigation`）。
  /// `prefill` は入力欄を持つモードの初期クエリ。行の組み立てが query を読むモードがあるため、
  /// 空へ戻すのでなくここで確定させてから `rebuild()` に渡す。
  func setMode(_ m: Mode, select: Int? = nil, prefill: String = "") {
    // 通知音の面へ入るたび試聴対象を「完了」へ戻す（前回の対象を持ち越さない）。
    if case .notificationSound = m { previewEvent = .done }
    withoutPreview {
      mode = m
      render.query = prefill
      rebuild()  // ここで currentRowIndex が確定する
      render.selected = select ?? currentRowIndex ?? 0
      render.clampSelection()
    }
    focus()  // 入力欄なしモードは CardKeyCapture、入力欄ありモードは TextField が focusToken で focus を取る
  }

  /// 現在の mode の行を組み直す（mode はそのまま。入力途中の再描画に使う）。
  func rebuild() {
    currentRowIndex = nil
    render.headerSegments = []  // 面ごとのヘッダ装飾は組み直すたび白紙から（通知音の面だけが立てる）
    withoutPreview {
      switch mode {
      case .root: rebuildRoot()
      case .font: rebuildFont()
      case .tabTitleFont: rebuildTabTitleFont()
      case .emojiFont: rebuildEmojiFont()
      case .theme: rebuildTheme()
      case .agent: rebuildAgent()
      case .agentStates: rebuildAgentStates()
      case .agentIcon(let kind): rebuildAgentIcon(kind: kind)
      case .worktreeDirPresets: rebuildWorktreeDirPresets()
      case .worktreeDirCustom: rebuildWorktreeDirCustom()
      case .language: rebuildLanguage()
      case .update: rebuildUpdate()
      case .notificationSound: rebuildNotificationSound()
      }
      render.clampSelection()
    }
  }
}
