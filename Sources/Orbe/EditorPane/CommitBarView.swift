import SwiftUI

/// CommitBar（高さ 40・変更タブのみ）。メッセージ入力（per-repo 下書き）・
/// `staged N · +A` 集計・`コミット ⌘⏎` ボタン。失敗/成功の最小表示は直上の帯（PaneBannerStrip）。
struct CommitBarView: View {
  @Bindable var model: EditorPaneModel
  @Environment(\.localization) private var l10n
  /// 共通プレースホルダモディファイアへ渡す focus 判定。フォーカスを奪う変更ではなく、marked text 監視の
  /// active ゲート用（他 chrome 入力欄と同機構に揃える）。
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 8) {
      inputField
      stagedSummary
      commitButton
    }
    .padding(.horizontal, 10)
    .frame(height: 40)
    .overlay(alignment: .top) {
      Rectangle().fill(Color.theme.surfaceInk.opacity(0.07)).frame(height: 1)
    }
  }

  private var inputField: some View {
    HStack(spacing: 7) {
      StatusGlyphView(kind: .done, size: 9)
      TextField("", text: $model.ui.commitDraft)
        .textFieldStyle(.plain)
        .font(Font.theme.paneControl)
        .foregroundStyle(Color.theme.textPrimary)
        .focused($focused)
        // 純正 prompt は IME 変換中も消えないため、共通モディファイアで muted 描画しつつ marked text 中は抑制する。
        .imePlaceholder(
          l10n.string(.commitMessagePlaceholder), showWhenEmpty: model.ui.commitDraft.isEmpty,
          focused: focused, font: Font.theme.paneControl, color: Color.theme.textMuted
        )
        .onSubmit { commit() }
        .onExitCommand { model.actions?.focusTerminal() }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(RoundedRectangle(cornerRadius: 5).fill(Color.theme.inputWash))
    .overlay(
      RoundedRectangle(cornerRadius: 5)
        .strokeBorder(Color.theme.borderInk.opacity(0.14), lineWidth: 1)
    )
    .frame(maxWidth: .infinity)
  }

  private var stagedSummary: some View {
    let stat = model.stagedStat
    return
      (Text(verbatim: "staged \(stat.count) · ")
      + Text(verbatim: "+\(stat.add)").foregroundColor(.theme.diffAdded))
      .font(Font.theme.paneSegment)
      .foregroundStyle(Color.theme.textMuted)
      .lineLimit(1)
  }

  private var commitButton: some View {
    Button(action: commit) {
      Text(l10n.string(model.committing ? .commitInProgress : .commitButton))
        .font(Font.theme.paneControl)
        .foregroundStyle(Color.theme.tabActiveText)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.theme.textPrimary))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .keyboardShortcut(.return, modifiers: .command)
    .disabled(!canCommit)
    .opacity(canCommit ? 1 : Theme.Opacity.disabled)
  }

  private var canCommit: Bool {
    !model.committing && model.stagedStat.count > 0
      && !model.ui.commitDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func commit() {
    guard canCommit else { return }
    model.actions?.commit(
      message: model.ui.commitDraft.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

/// コミット失敗/成功の最小表示（CommitBar 直上の控えめな帯）。タップで消す。
struct PaneBannerStrip: View {
  let banner: PaneBanner
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Text(message)
        .font(Font.theme.paneFootnote)
        .foregroundStyle(isError ? Color.theme.danger : Color.theme.textMuted)
        .lineLimit(2)
        .textSelection(.enabled)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(isError ? Color.theme.danger.opacity(0.1) : Color.theme.diffAdded.opacity(0.06))
    .contentShape(Rectangle())
    .onTapGesture(perform: onDismiss)
  }

  private var isError: Bool {
    if case .error = banner { return true }
    return false
  }

  private var message: String {
    switch banner {
    case .success(let text): return "✓ \(text)"
    case .error(let text): return text
    }
  }
}
