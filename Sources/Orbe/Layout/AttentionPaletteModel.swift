import SwiftUI

/// ⌘⌘（前面時）/ TopBar ストリップで開く Attention パレットの状態機械。
///
/// 全ライブペインの agentState（waiting/done/working）を stateChangedAt 降順にフラット一覧し、
/// ↑↓ で選択・Enter/行タップでそのペインへ移動（WS activate＋タブ選択＋ペイン focus）・
/// Esc/scrim で閉じる。フィルタ入力欄・ドリルインは持たない。空のときは情報行 1 本。
/// ヘッダは breadcrumb「attention」＋右端 `⌘⌘` バッジ（デザイン第10シーン）。
///
/// 描画は `PaletteOverlay`/`PaletteCard`。行の中身は `AttentionRowView`（customContent）。
/// 表示中の更新は提示元（WindowController）が `flushChrome` の snapshot 更新時に `setRows` で流し込む。
@Observable final class AttentionPaletteModel {
  var onFocusPane: ((Int) -> Void)?
  var onDismiss: (() -> Void)?

  let render = PaletteModel()
  private var rows: [AttentionRow] = []
  private let localization: LocalizationStore

  init(localization: LocalizationStore = LocalizationStore(language: .systemDefault)) {
    self.localization = localization
    render.breadcrumb = "attention"
    render.headerBadge = "⌘⌘"
    render.scrimStrength = .normal  // 頻繁に開く軽いパレット（workspace 切替と同じ通常暗幕）
    render.hint = localization.string(.attentionPaletteHint)
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
  func focus() { render.focusToken &+= 1 }

  /// snapshot を反映して再描画する（開いたまま届く report の追従にも使う）。
  func setRows(_ rows: [AttentionRow]) {
    self.rows = rows
    rebuild()
    render.clampSelection()
  }

  // MARK: - 操作の意味（キー意図とテストの両方がここを駆動する）

  func activate() {
    guard rows.indices.contains(render.selected) else { return }
    onFocusPane?(rows[render.selected].paneId)
  }

  private func rebuild() {
    render.rows =
      rows.isEmpty
      ? [PaletteModel.RowItem(label: localization.string(.attentionEmpty), enabled: false)]
      : rows.map { row in
        PaletteModel.RowItem(
          label: "\(row.workspaceName) › \(row.tabTitle)",
          customContent: AnyView(AttentionRowView(row: row)))
      }
  }
}
