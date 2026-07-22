import SwiftUI

/// Cmd+Shift+S で開く workspace コマンドパレットの状態機械（ドリルイン式）。
///
/// - 一覧: 入力で絞り込み、↑↓ で選択、Enter で切替（一致なし入力＋Enter で新規作成）、
///   選択 workspace 行で → を押すと同じカードが詳細メニューに潜る、Esc で閉じる。
/// - 詳細メニュー（改名 / ディレクトリ / 削除）: ↑↓ で選択、Enter で実行、← か Esc で一覧へ戻る。
/// - 改名 / ディレクトリ: 入力欄に現値をプリフィルし Enter で確定、Esc で詳細メニューへ戻る。
///
/// 描画は `PaletteOverlay`/`PaletteCard`（`AppShell` の `.overlay` が compose）。本モデルは
/// mode/entries の意味を駆動し、行・選択・絞り込み欄・キー意図を `render`(PaletteModel) へ立て下げる。
@Observable final class WorkspacePaletteModel {
  struct Item {
    let index: Int
    let name: String
    let isActive: Bool
    /// このセッションで未だ表示していない（復元のみの）休眠 workspace。暗く出す。
    let dormant: Bool
    /// この workspace のエージェント状態ロールアップ（状態順の `[(state, count)]`）。空なら何も出さない。
    let agentRollup: [(state: String, count: Int)]
    /// この workspace のディレクトリ設定（rootPath）。詳細メニューの「ディレクトリ」編集にプリフィルする。
    let dir: String
  }

  var onSwitch: ((Int) -> Void)?
  var onCreate: ((String) -> Void)?
  /// 末尾常設の「＋ 新規ワークスペース」行＝専用作成フォームへ遷移。
  var onCreateFlow: (() -> Void)?
  var onRename: ((Int, String) -> Void)?
  var onSetDir: ((Int, String) -> Void)?
  var onClose: ((Int) -> Void)?
  var onDismiss: (() -> Void)?

  private enum Mode {
    case list
    case submenu(Int)  // workspace index
    case rename(Int)  // workspace index
    case setDir(Int)  // workspace index
  }
  private enum Entry {
    case workspace(Item)
    case create(String)
    /// 末尾常設の作成フォーム導線（絞り込み中も残す）。
    case createFlow
    case action(Action)
  }
  private enum Action { case rename, setDir, close }

  let render = PaletteModel()
  /// 現在の workspace 一覧（計算済み `agentRollup` を含む）。読みは公開（テストが rollup 写像を検証する）。
  private(set) var items: [Item] = []
  private var mode: Mode = .list
  private var entries: [Entry] = []
  /// 行・絞り込み欄・ヒントの文言を現在言語で出すためのストア（提示元＝WindowController が渡す）。
  private let localization: LocalizationStore

  init(localization: LocalizationStore) {
    self.localization = localization
    render.scrimStrength = .normal  // workspace は通常暗幕（強い暗幕は設定パレット専用）
    render.onScrimTap = { [weak self] in self?.onDismiss?() }
    render.onTapRow = { [weak self] i in
      self?.render.selected = i
      self?.activate()
    }
    render.onUp = { [weak self] in self?.moveSelection(-1) }
    render.onDown = { [weak self] in self?.moveSelection(1) }
    render.onJumpTop = { [weak self] in self?.jumpSelection(-1) }
    render.onJumpBottom = { [weak self] in self?.jumpSelection(1) }
    render.onActivate = { [weak self] in self?.activate() }
    render.onLeft = { [weak self] in self?.goBack() }  // 入力欄なしモード（詳細メニュー）のみ届く
    render.onRight = { [weak self] in self?.tryDrillIn() ?? false }
    render.onEscape = { [weak self] in self?.goBack() }
    render.onQueryChange = { [weak self] in self?.queryChanged() }
    rebuild()
  }

  /// first responder を現在のモードへ移す（focusToken を進め、SwiftUI が描画後に focus を確定する）。
  func focus() { render.focusToken &+= 1 }

  /// workspace 一覧を反映して再描画する（操作後の再読込にも使う）。
  func setItems(_ items: [Item]) {
    self.items = items
    // 行が外因（背景 workspace の畳み込み等）で作り直された＝捕捉済み index が
    // 別 workspace を指す恐れ。submenu/rename 中なら確定前に一覧へ戻し、
    // 誤対象の削除/改名を断つ。
    if case .list = mode {
      rebuild()
    } else {
      setMode(.list)
    }
  }

  /// 開いた直後、選択カーソルをアクティブ workspace 行へ載せる（提示元がパレットを開くとき
  /// 一覧を読み込んだ後に 1 度だけ呼ぶ）。ハイライトは常に選択カーソルの 1 つだけなので、
  /// 開いた瞬間の見た目が「アクティブ行が 1 つハイライト」になり design モックと一致する。
  func selectActiveRow() { render.selected = activeRow() }

  /// 改名・ディレクトリ編集中の ↑↓→ はカーソル/無効、一覧の ↑↓→ は一覧ナビ。
  private var fieldNavigates: Bool {
    switch mode {
    case .rename, .setDir: return false
    default: return true
    }
  }

  private func moveSelection(_ d: Int) {
    if fieldNavigates { render.move(d) }
  }

  private func jumpSelection(_ d: Int) {
    if fieldNavigates { render.jump(d) }
  }

  /// → 押下。ドリルインしたら true（キー消費）、改名中など潜れないなら false（カーソルへ委ねる）。
  private func tryDrillIn() -> Bool {
    guard fieldNavigates else { return false }
    drillIn()
    return true
  }

  // MARK: - モード遷移

  private func setMode(_ m: Mode) {
    mode = m
    render.selected = 0
    render.query = ""
    rebuild()
    focus()
  }

  private func name(of index: Int) -> String {
    items.first(where: { $0.index == index })?.name ?? ""
  }

  private func dir(of index: Int) -> String {
    items.first(where: { $0.index == index })?.dir ?? ""
  }

  // MARK: - 行の構築・描画

  private func rebuild() {
    switch mode {
    case .list:
      let query = render.query.trimmingCharacters(in: .whitespaces)
      let matched =
        query.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(query) }
      entries = matched.map { .workspace($0) }
      if !query.isEmpty, !items.contains(where: { $0.name == query }) {
        entries.append(.create(query))
      }
      entries.append(.createFlow)  // 一覧末尾に常設（絞り込み中も残す）
    case .submenu:
      entries = [.action(.rename), .action(.setDir)]
      if items.count > 1 { entries.append(.action(.close)) }  // 最後の1つは削除メニューを出さない
    case .rename, .setDir:
      entries = []
    }
    renderRows()
  }

  private func renderRows() {
    switch mode {
    case .list:
      render.fieldVisible = true
      render.placeholder = localization.string(.wsPalettePlaceholder)
      render.breadcrumb = nil
      render.hint = localization.string(.wsPaletteHintList)
    case .submenu(let idx):
      render.fieldVisible = false
      render.breadcrumb = "‹ " + name(of: idx)
      render.hint = localization.string(.wsPaletteHintSubmenu)
    case .rename:
      render.fieldVisible = true
      render.placeholder = localization.string(.wsRenamePlaceholder)
      render.breadcrumb = nil
      render.hint = localization.string(.wsRenameHint)
    case .setDir:
      render.fieldVisible = true
      render.placeholder = localization.string(.wsSetDirPlaceholder)
      render.breadcrumb = nil
      render.hint = localization.string(.wsSetDirHint)
    }
    render.rows = entries.map { entry in
      switch entry {
      case .workspace(let it):
        return PaletteModel.RowItem(
          label: it.name, dimmed: it.dormant,
          customContent: AnyView(
            WorkspaceSwitcherRow(
              name: it.name, rollup: it.agentRollup,
              path: (it.dir as NSString).abbreviatingWithTildeInPath)))
      case .create(let name):
        return PaletteModel.RowItem(label: localization.format(.wsCreateInline, name))
      case .createFlow:
        return PaletteModel.RowItem(
          label: localization.string(.wsCreateFlowRow), trailingBadge: "⌘N", createStyle: true)
      case .action(let a):
        let label: String = {
          switch a {
          case .rename: return localization.string(.wsActionRename)
          case .setDir: return localization.string(.wsActionSetDir)
          case .close: return localization.string(.wsActionClose)
          }
        }()
        return PaletteModel.RowItem(label: label)
      }
    }
    render.clampSelection()
  }

  // MARK: - 操作の意味（キー意図とテストの両方がここを駆動する）

  func activate() {
    switch mode {
    case .list:
      guard entries.indices.contains(render.selected) else { return }
      switch entries[render.selected] {
      case .workspace(let it): onSwitch?(it.index)
      case .create(let name): onCreate?(name)
      case .createFlow: onCreateFlow?()
      case .action: break
      }
    case .submenu(let idx):
      guard entries.indices.contains(render.selected),
        case .action(let a) = entries[render.selected]
      else { return }
      switch a {
      case .rename: beginRename(idx)
      case .setDir: beginSetDir(idx)
      case .close:
        onClose?(idx)
        setMode(.list)  // 一覧へ戻る（selected は下で確定）
        render.selected = activeRow()  // 削除後はアクティブ workspace の行へ合わせる
      }
    case .rename(let idx):
      let newName = render.query.trimmingCharacters(in: .whitespaces)
      if !newName.isEmpty { onRename?(idx, newName) }
      setMode(.list)
    case .setDir(let idx):
      let newDir = render.query.trimmingCharacters(in: .whitespaces)
      if !newDir.isEmpty { onSetDir?(idx, newDir) }
      setMode(.list)
    }
  }

  /// 一覧 entries 内でアクティブ workspace の行 index。無ければ 0。
  private func activeRow() -> Int {
    entries.firstIndex {
      if case .workspace(let it) = $0 { return it.isActive }
      return false
    } ?? 0
  }

  /// 一覧で選択中の workspace 行 → 詳細メニューへ潜る。create 行・詳細メニューでは無視。
  func drillIn() {
    guard case .list = mode, entries.indices.contains(render.selected),
      case .workspace(let it) = entries[render.selected]
    else { return }
    setMode(.submenu(it.index))
  }

  /// ← / Esc。一覧では閉じ、詳細では一覧へ、改名では詳細へ戻る（1段ずつ浅くなる）。
  func goBack() {
    switch mode {
    case .list: onDismiss?()
    case .submenu: setMode(.list)
    case .rename(let idx), .setDir(let idx): setMode(.submenu(idx))
    }
  }

  func queryChanged() {
    if case .list = mode {
      render.selected = 0  // 行集合が入れ替わるため選択は先頭へ戻す（create 行への誤着地を防ぐ）
      rebuild()
    }  // 絞り込みは一覧のみ
  }

  private func beginRename(_ idx: Int) {
    setMode(.rename(idx))  // focus() が常設の入力欄へ first responder を移す
    render.query = name(of: idx)
  }

  private func beginSetDir(_ idx: Int) {
    setMode(.setDir(idx))  // focus() が常設の入力欄へ first responder を移す
    render.query = dir(of: idx)  // 現ディレクトリをプリフィルして編集させる
  }
}
