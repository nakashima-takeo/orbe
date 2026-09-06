import SwiftUI

/// ⇧⌘T で開く「閉じたエージェント」パレットの状態機械。
///
/// アクティブ workspace で閉じたまま戻っていない同一性を新しい順に平らに並べ、↵ で選んだ 1 件を復元する。
/// Esc は閉じる。空のときは情報行 1 本。多数を戻す入口は GUI に持たない（orb / MCP の `restore_sessions`）。
///
/// 描画は `PaletteOverlay` / `PaletteCard`。行の中身は `ClosedAgentRowView`。
/// 表示中の更新は提示元（WindowController）が `flushChrome` の契機で `setItems` を流し込む。
@Observable final class ClosedAgentsPaletteModel {
  var onRestore: ((ClosedAgentItem) -> Void)?
  var onDismiss: (() -> Void)?

  let render = PaletteModel()

  private(set) var items: [ClosedAgentItem] = []
  private let localization: LocalizationStore

  init(localization: LocalizationStore = LocalizationStore(language: .systemDefault)) {
    self.localization = localization
    render.surface = .popup
    render.scrimStrength = .normal
    render.breadcrumb = "closed agents"
    render.hintKeys = [
      PaletteModel.HintKey(key: "↵", label: localization.string(.closedAgentsHintRestore)),
      PaletteModel.HintKey(key: "↑↓", label: localization.string(.closedAgentsHintSelect)),
      PaletteModel.HintKey(key: "esc", label: localization.string(.closedAgentsHintClose)),
    ]
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
    render.onEscape = { [weak self] in self?.onDismiss?() }
    rebuild()
  }

  /// キー操作を受けるため focusToken を進めて first responder を確定させる。
  func focus() { render.focus() }

  /// 一覧を差し替えて再描画する（開いたまま届く復元・閉鎖の追従にも使う）。選択は index でなく
  /// sessionId の錨で追い直す（→ `ModalSelection.restore`）。
  func setItems(_ items: [ClosedAgentItem]) {
    let anchor =
      self.items.indices.contains(render.selected)
      ? self.items[render.selected].sessionId : nil
    self.items = items
    rebuild()
    if let anchor, let i = items.firstIndex(where: { $0.sessionId == anchor }) {
      render.restoreSelection(i)
      return
    }
    render.clampSelection()
  }

  /// ↵。選択した 1 件を復元する。
  func activate() {
    guard items.indices.contains(render.selected) else { return }
    onRestore?(items[render.selected])
  }

  private func rebuild() {
    render.rows =
      items.isEmpty
      ? [PaletteModel.RowItem(label: localization.string(.closedAgentsEmpty), enabled: false)]
      : items.map { item in
        PaletteModel.RowItem(
          label: item.title ?? TabTitle.fallback,
          customContent: AnyView(ClosedAgentRowView(item: item)))
      }
  }
}
