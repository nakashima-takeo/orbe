import SwiftUI

/// 左レール: 変更タブ（ChangesRail）。フォルダグルーピング＋3状態 StageBox＋
/// ファイル行（アイコン・hunk 進捗・バッジ）＋フッタの staged 進捗バー。
struct ChangesRailView: View {
  @Bindable var model: EditorPaneModel
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver
  /// 破棄確認ダイアログの対象（nil で非表示）。
  @State private var discardRequest: DiscardRequest?

  /// 変更破棄の確認対象（ファイル単位・フォルダ単位共通）。
  private struct DiscardRequest: Identifiable {
    let id = UUID()
    let title: String
    let changes: [FileChange]
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(model.changeGroups()) { group in
            folderRow(group)
            if group.open {
              ForEach(group.files, id: \.path) { change in
                fileRow(change)
              }
            }
          }
        }
        .padding(.vertical, 5)
      }
      footer
    }
    .confirmationDialog(
      discardRequest.map { l10n.format(.gitDiscardTitle, $0.title) } ?? "",
      isPresented: Binding(
        get: { discardRequest != nil }, set: { if !$0 { discardRequest = nil } }),
      titleVisibility: .visible,
      presenting: discardRequest
    ) { request in
      Button(l10n.string(.gitDiscard), role: .destructive) {
        model.actions?.discardFiles(request.changes)
        discardRequest = nil
      }
      Button(l10n.string(.commonCancel), role: .cancel) { discardRequest = nil }
    } message: { request in
      Text(
        l10n.plural(
          request.changes.count, one: .gitDiscardConfirmOne, other: .gitDiscardConfirmOther))
    }
  }

  private func folderRow(_ group: PaneChangeGroup) -> some View {
    let stageState = model.groupStageState(group)
    let allStaged = stageState == .staged
    return HStack(spacing: 5) {
      StageBoxView(state: stageState)
        .contentShape(Rectangle())
        .onTapGesture { toggleGroupStage(group) }
      Text(verbatim: group.open ? "▾" : "▸")
        .foregroundStyle(allStaged ? Color.theme.stateIdle : Color.theme.textMuted)
      FileIconView(
        name: MochaIcon.name(
          folder: group.dir.split(separator: "/").last.map(String.init) ?? "",
          open: group.open),
        dim: allStaged)
      fontResolver.text(group.dir, base: Theme.Typography.paneRow)
        .foregroundStyle(allStaged ? Color.theme.stateIdle : Color.theme.textSecondary)
      Spacer(minLength: 0)
      countText(group, allStaged: allStaged)
        .font(Font.theme.paneSegment)
    }
    .font(Font.theme.paneRow)
    .padding(.horizontal, 10)
    .frame(height: 22)
    .contentShape(Rectangle())
    .onTapGesture { model.toggleChangesFolder(group.id) }
    .contextMenu {
      Button(l10n.string(.gitDiscardChanges), role: .destructive) {
        // conflict は discard 対象外（discardFiles が除外）。確認の件数を実対象に合わせる。
        discardRequest = DiscardRequest(
          title: group.dir, changes: group.files.filter { !$0.isConflicted })
      }
    }
  }

  @ViewBuilder private func countText(_ group: PaneChangeGroup, allStaged: Bool) -> some View {
    if allStaged {
      Text(verbatim: "\(group.files.count) ✓").foregroundStyle(Color.theme.stateIdle)
    } else {
      HStack(spacing: 3) {
        Text(verbatim: "\(group.files.count) ·").foregroundStyle(Color.theme.textMuted)
        AddDelText(add: group.stat.add, del: group.stat.del)
      }
    }
  }

  private func fileRow(_ change: FileChange) -> some View {
    let selected = model.ui.selectedPath == change.path
    let state = model.stageState(of: change)
    let badge = ChangeBadge.of(change)
    return HStack(spacing: 6) {
      StageBoxView(state: state)
        .contentShape(Rectangle())
        .onTapGesture { toggleStage(change, state: state) }
      FileIconView(name: MochaIcon.name(file: change.path))
      fontResolver.text(EditorPaneModel.fileName(of: change.path), base: Theme.Typography.paneRow)
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(selected ? Color.theme.textPrimary : Color.theme.textSecondary)
      Spacer(minLength: 0)
      if state == .partial, let progress = model.hunkProgress(of: change.path) {
        Text(verbatim: "\(progress.staged)/\(progress.total)")
          .font(Font.theme.paneFootnote)
          .foregroundStyle(Color.theme.diffAdded)
      }
      Text(badge.letter).foregroundStyle(badge.color)
    }
    .font(Font.theme.paneRow)
    .padding(.leading, 22)
    .padding(.trailing, 10)
    .frame(height: 22)
    .background(selected ? Color.theme.surfaceInk.opacity(0.07) : Color.clear)
    .contentShape(Rectangle())
    .onTapGesture { model.select(path: change.path) }
    .contextMenu {
      Button(l10n.string(.gitDiscardChanges), role: .destructive) {
        discardRequest = DiscardRequest(
          title: EditorPaneModel.fileName(of: change.path), changes: [change])
      }
    }
  }

  /// StageBox クリック: none→全 stage・partial→残り全 stage・staged→unstage。conflict は不可。
  private func toggleStage(_ change: FileChange, state: StageState) {
    guard !change.isConflicted else { return }
    switch state {
    case .none, .partial: model.actions?.stageFile(change)
    case .staged: model.actions?.unstageFile(change)
    }
  }

  /// フォルダ StageBox クリック: 全 staged なら配下を一括 unstage・それ以外は一括 stage。
  private func toggleGroupStage(_ group: PaneChangeGroup) {
    let files = group.files.filter { !$0.isConflicted }
    guard !files.isEmpty else { return }
    if model.groupStageState(group) == .staged {
      model.actions?.unstageFiles(files)
    } else {
      model.actions?.stageFiles(files)
    }
  }

  /// フッタ: `staged N/M`＋進捗バー（見本の `レビュー 9/24` を staged 進捗へ接地した逸脱）。
  private var footer: some View {
    let staged = model.stagedFiles.count
    let total = model.changedFiles.count
    return VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: "staged \(staged)/\(total)")
        .font(Font.theme.paneFootnote)
        .foregroundStyle(Color.theme.textMuted)
      GeometryReader { geo in
        RoundedRectangle(cornerRadius: 2)
          .fill(Color.theme.surfaceInk.opacity(0.08))
          .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
              .fill(Color.theme.diffAdded)
              .frame(width: total > 0 ? geo.size.width * CGFloat(staged) / CGFloat(total) : 0)
          }
      }
      .frame(height: 3)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .overlay(alignment: .top) {
      Rectangle().fill(Color.theme.surfaceInk.opacity(0.06)).frame(height: 1)
    }
  }
}
