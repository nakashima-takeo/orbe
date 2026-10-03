import SwiftUI

/// ベースを選ぶ画面の状態。候補を絞り込み、カーソルの 1 つを選ぶ。入力欄は一覧と同じ 1 本を使い回し、
/// 中身（`query`）だけをこの型が持つ。
@Observable final class WorktreeBasePickerModel {
  private let candidates: [WorktreeBaseCandidate]
  /// 絞り込みの入力。変わるたびにカーソルを先頭へ戻す。
  var query = "" {
    didSet {
      refreshItems()
      selected = 0
    }
  }
  /// 可視の候補。
  private(set) var items: [WorktreeBaseCandidate] = []
  /// 選択とホバー追従ガード（一覧と同じ `ModalSelection`）。
  private var selection = ModalSelection()

  init(candidates: [WorktreeBaseCandidate]) {
    self.candidates = candidates
    refreshItems()
  }

  var selected: Int {
    get { selection.index }
    set { selection.index = newValue }
  }

  var inputModality: InputModality {
    get { selection.modality }
    set { selection.modality = newValue }
  }

  var selectedItem: WorktreeBaseCandidate? {
    items.indices.contains(selected) ? items[selected] : nil
  }

  /// ↑↓。端で wrap。
  func move(_ direction: Int) {
    guard !items.isEmpty else { return }
    selected = (selected + direction + items.count) % items.count
  }

  /// ホバー開始による選択追従（実マウス移動後だけ効く）。
  func hoverSelect(_ index: Int) {
    guard items.indices.contains(index) else { return }
    selection.hoverSelect(index)
  }

  private func refreshItems() {
    items =
      query.isEmpty
      ? candidates : candidates.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }
}

/// ベースを選ぶ画面のリスト部。行は一覧のブランチ行と同じ見た目（グリフ・名前・相対日時）。
struct WorktreeBasePickerList: View {
  @Bindable var model: WorktreeBasePickerModel
  /// 行タップ＝決定。
  let onConfirm: (Int) -> Void
  @Environment(\.localization) private var l10n

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if model.items.isEmpty {
            WorktreePaletteEmptyNote(text: l10n.string(.worktreePaletteBaseNoMatch))
          }
          ForEach(Array(model.items.enumerated()), id: \.offset) { index, candidate in
            WorktreePaletteRowFrame(
              glyph: candidate.isRemote ? .remoteBranch : .localBranch, name: candidate.name,
              detail: candidate.relativeDate, selected: index == model.selected,
              onTap: { onConfirm(index) }, onHoverEnter: { model.hoverSelect(index) },
              trailing: { EmptyView() }
            )
            .id(index)
          }
        }
        .padding(Theme.Space.note)
        .background(
          GeometryReader { geometry in
            Color.clear.preference(
              key: WorktreePaletteContentHeightKey.self, value: geometry.size.height)
          }
        )
      }
      .scrollIndicators(.automatic)
      .onChange(of: model.selected) { proxy.scrollTo(model.selected) }
    }
  }
}

/// ベースを選ぶ画面のフッター（`↵ X をベースにする`＋キーヒント）。
struct WorktreeBasePickerFooter: View {
  @Bindable var model: WorktreeBasePickerModel
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      if let name = model.selectedItem?.name {
        WorktreePaletteEnterLine(
          template: l10n.string(.worktreePaletteBasePickEnter), slots: [.name(name)])
      }
      Spacer(minLength: Theme.Space.step)
      HStack(spacing: Theme.Space.step + Theme.Space.hair) {
        if model.items.count >= 2 {
          WorktreePaletteKeyHint(key: "↑↓", label: l10n.string(.worktreePaletteHintSelect))
        }
        WorktreePaletteKeyHint(key: "esc", label: l10n.string(.worktreePaletteHintBack))
      }
      .font(Font.theme.sectionLabel)
      .foregroundStyle(Color.theme.textMuted)
      .fixedSize()
    }
  }
}
