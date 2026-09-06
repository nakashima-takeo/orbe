import SwiftUI

/// ⇧⌘T で開く「閉じたエージェント」パレットの状態機械。
///
/// アクティブ workspace で閉じたまま戻っていない同一性を新しい順に並べる。2 件以上の群は 1 行にまとめ、
/// ↵ で群全体を復元・→ で群の中身へ潜って 1 件ずつ選んで復元（`members`）。1 件の群は 1 件行で ↵ が
/// その 1 件を復元する。← / Esc は members → groups、groups → 閉じる。空のときは情報行 1 本。
///
/// 描画は `PaletteOverlay` / `PaletteCard`。行の中身は `ClosedAgentRowView` / `ClosedAgentGroupRowView`。
/// 表示中の更新は提示元（WindowController）が `flushChrome` の契機で `setGroups` を流し込む。
@Observable final class ClosedAgentsPaletteModel {
  var onRestore: (([ClosedAgentItem]) -> Void)?
  var onDismiss: (() -> Void)?

  let render = PaletteModel()

  /// 群の同一性は `atKey`。全 closed から切った群の `at` は復元の途中でも動かないので、members 表示中に
  /// 1 件ずつ復元しても同じ群を追える。
  enum Mode: Equatable {
    case groups
    case members(atKey: String)
  }
  private(set) var mode: Mode = .groups
  private(set) var groups: [ClosedAgentGroup] = []
  private let localization: LocalizationStore

  init(localization: LocalizationStore = LocalizationStore(language: .systemDefault)) {
    self.localization = localization
    render.surface = .popup
    render.scrimStrength = .normal
    render.onScrimTap = { [weak self] in self?.onDismiss?() }
    render.onTapRow = { [weak self] i in
      self?.render.selected = i
      self?.activate()
    }
    render.onUp = { [weak self] in self?.render.move(-1) }
    render.onDown = { [weak self] in self?.render.move(1) }
    render.onJumpTop = { [weak self] in self?.render.jump(-1) }
    render.onJumpBottom = { [weak self] in self?.render.jump(1) }
    render.onActivate = { [weak self] in self?.activate() }
    render.onRight = { [weak self] in self?.drillIn() ?? false }
    render.onLeft = { [weak self] in self?.goBack() }
    render.onEscape = { [weak self] in self?.goBack() }
    rebuild()
  }

  /// キー操作を受けるため focusToken を進めて first responder を確定させる。
  func focus() { render.focus() }

  /// 一覧を差し替えて再描画する（開いたまま届く復元・閉鎖の追従にも使う）。選択は index でなく
  /// 錨（groups では群の `atKey`・members では sessionId）で追い直す（→ `ModalSelection.restore`）。
  /// members 表示中に錨の群が消えたら（全件戻った）groups へ戻る。
  func setGroups(_ groups: [ClosedAgentGroup]) {
    let anchorKey: String? = {
      switch mode {
      case .groups:
        return self.groups.indices.contains(render.selected)
          ? self.groups[render.selected].atKey : nil
      case .members(let atKey):
        let items = self.groups.first { $0.atKey == atKey }?.items ?? []
        return items.indices.contains(render.selected) ? items[render.selected].sessionId : nil
      }
    }()
    self.groups = groups
    if case .members(let atKey) = mode, !groups.contains(where: { $0.atKey == atKey }) {
      mode = .groups
      rebuild()
      render.clampSelection()
      return
    }
    rebuild()
    if let anchorKey, let i = visibleKeys.firstIndex(of: anchorKey) {
      render.restoreSelection(i)
      return
    }
    render.clampSelection()
  }

  // MARK: - 操作の意味（キー意図とテストの両方がここを駆動する）

  /// ↵。groups では選択した群（1 件行ならその 1 件）を全部、members では選択した 1 件を復元する。
  func activate() {
    switch mode {
    case .groups:
      guard groups.indices.contains(render.selected) else { return }
      onRestore?(groups[render.selected].items)
    case .members(let atKey):
      guard let items = groups.first(where: { $0.atKey == atKey })?.items,
        items.indices.contains(render.selected)
      else { return }
      onRestore?([items[render.selected]])
    }
  }

  /// →。2 件以上の群の行でだけ中身へ潜る（true＝キーを消費）。
  @discardableResult
  func drillIn() -> Bool {
    guard case .groups = mode, groups.indices.contains(render.selected),
      groups[render.selected].items.count > 1
    else { return false }
    mode = .members(atKey: groups[render.selected].atKey)
    rebuild()
    render.place(0)
    return true
  }

  /// ← / Esc。members なら潜った群の行へ戻り、groups なら閉じる。
  func goBack() {
    switch mode {
    case .groups:
      onDismiss?()
    case .members(let atKey):
      mode = .groups
      rebuild()
      render.place(groups.firstIndex { $0.atKey == atKey } ?? 0)
    }
  }

  // MARK: - 行の組み立て

  /// 表示行の錨（groups: 群の atKey・members: sessionId）。`setGroups` の追い直しが引く。
  private var visibleKeys: [String] {
    switch mode {
    case .groups: return groups.map(\.atKey)
    case .members(let atKey):
      return groups.first { $0.atKey == atKey }?.items.map(\.sessionId) ?? []
    }
  }

  private func rebuild() {
    switch mode {
    case .groups:
      render.breadcrumb = "closed agents"
      render.hintKeys = [
        PaletteModel.HintKey(key: "↵", label: localization.string(.closedAgentsHintRestore)),
        PaletteModel.HintKey(key: "→", label: localization.string(.closedAgentsHintDrill)),
        PaletteModel.HintKey(key: "↑↓", label: localization.string(.closedAgentsHintSelect)),
        PaletteModel.HintKey(key: "esc", label: localization.string(.closedAgentsHintClose)),
      ]
      render.rows =
        groups.isEmpty
        ? [PaletteModel.RowItem(label: localization.string(.closedAgentsEmpty), enabled: false)]
        : groups.map { group in
          group.items.count == 1
            ? itemRow(group.items[0])
            : PaletteModel.RowItem(
              label: localization.format(.closedAgentsGroupCount, group.items.count),
              chevron: true, customContent: AnyView(ClosedAgentGroupRowView(group: group)))
        }
    case .members(let atKey):
      let group = groups.first { $0.atKey == atKey }
      render.breadcrumb = "closed agents › " + (group.map { Self.clock.string(from: $0.at) } ?? "")
      render.hintKeys = [
        PaletteModel.HintKey(key: "↵", label: localization.string(.closedAgentsHintRestoreOne)),
        PaletteModel.HintKey(key: "←", label: localization.string(.closedAgentsHintBack)),
        PaletteModel.HintKey(key: "esc", label: localization.string(.closedAgentsHintClose)),
      ]
      render.rows = (group?.items ?? []).map(itemRow)
    }
  }

  private func itemRow(_ item: ClosedAgentItem) -> PaletteModel.RowItem {
    PaletteModel.RowItem(
      label: "\(item.command) › \(TabTitle.derive(pwd: item.cwd, root: item.rootPath))",
      detail: item.reason, customContent: AnyView(ClosedAgentRowView(item: item)))
  }

  /// members の breadcrumb に出す閉じた時刻（ローカル時刻の HH:mm:ss）。
  private static let clock: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm:ss"
    return f
  }()
}
