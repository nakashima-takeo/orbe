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
  /// 音量まで渡すのは、耳に届く値が root 行の表示と食い違わないため——値の解決はこのスコープの
  /// 実効値（`ScopedSettingsValues`）だけが持つ規約で、提示元は別の解決を持ち込まない。
  var onPreviewSound: ((NotificationSound?, AgentSoundEvent, Int) -> Void)?

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
  /// 現在の面。遷移は `setMode` だけが行い、キー意図の分岐（`+Keys`）と行組み立てが読む。
  private(set) var mode: Mode = .root
  /// 潜る前にいた root 行の「全行 rootRows での index」（既定は先頭設定行）。
  var rootRowBeforeDrill = 1
  /// 状態一覧からアイコン候補へ潜る前にいた状態行の index（agentIcon から agentStates へ戻る復元用）。
  var stateRowBeforeDrill = 0

  // 以下は行組み立て（`SettingsPaletteModel+Subpalette.swift`）と共有するため internal。

  /// 現在値の行 index（サブモードの表示行に対する。root と、現在値が表示行に無いときは nil）。
  var currentRowIndex: Int?

  /// 通知音サブパレットの試聴対象（完了 / 入力待ち）。⇥ とセグメントのクリックで反転する**面の状態**で、
  /// 設定には書かない。入場のたび `.done` へ戻す（前回を持ち越すと、開いた瞬間に何が鳴るか予測できない）。
  var previewEvent: AgentSoundEvent = .done

  // 試聴インジケータ（EQ）の状態。格納プロパティなのでここに置き、読み書きは `+Sound` だけが行う
  // （extension には格納プロパティを置けない）。

  /// 試聴中の行（EQ を出す行）。鳴り終わり（`SoundCatalog.duration`）で自動的に nil へ戻る**面の状態**で、
  /// 設定にも `PaletteModel.rows` にも書かない。
  var previewingRow: Int?
  /// 先行する消灯予約を無効化する世代（↑↓ 連打で消灯が食い違わない）。
  var previewGeneration = 0
  /// 鳴り終わりの予約。既定は main queue。テストは手動スケジューラへ差し替えて 2 秒待たずに消灯を見る
  /// （`onApply` / `onPreviewSound` と同じ「提示元が埋める口」の流儀）。
  var schedulePreviewEnd: (TimeInterval, @escaping () -> Void) -> Void = { delay, fire in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: fire)
  }

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
    render.onSelectionChanged = { [weak self] _ in self?.previewSelectedRow() }
    render.onTab = { [weak self] in self?.togglePreviewEvent() ?? false }
    render.onTapSegment = { [weak self] i in self?.selectPreviewEvent(i) }
    rebuild()
    render.place(1)  // スコープ行（index 0）でなく先頭の設定行（フォントサイズ）を初期選択にする
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

  // MARK: - モード遷移・描画

  /// mode を切り替えて行を組み直し、選択を決める（ドリル遷移は `SettingsPaletteModel+Navigation`）。
  /// `prefill` は入力欄を持つモードの初期クエリ。行の組み立てが query を読むモードがあるため、
  /// 空へ戻すのでなくここで確定させてから `rebuild()` に渡す。
  func setMode(_ m: Mode, select: Int? = nil, prefill: String = "") {
    // 通知音の面へ入るたび試聴対象を「完了」へ戻す（前回の対象を持ち越さない）。
    if case .notificationSound = m { previewEvent = .done }
    cancelPreviewIndicator()  // 面を移るときは EQ を必ず畳む（予約中の消灯も無効化する）
    mode = m
    render.query = prefill
    rebuild()  // ここで currentRowIndex が確定する
    render.place(select ?? currentRowIndex ?? 0)  // 面の組み立てによる配置＝入場では鳴らさない
    render.clampSelection()
    focus()  // 入力欄なしモードは CardKeyCapture、入力欄ありモードは TextField が focusToken で focus を取る
  }

  /// 現在の mode の行を組み直す（mode はそのまま。入力途中の再描画に使う）。
  func rebuild() {
    // 面ごとの装飾は組み直すたび白紙から（立てるのは各 rebuild だけ）。試聴 EQ（`rowAccessory`）は
    // 行の再構築と独立に点いて消える一時状態なので、ここでは触らず `+Sound` が単独で握る。
    currentRowIndex = nil
    render.segments = []
    render.caption = ""
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
