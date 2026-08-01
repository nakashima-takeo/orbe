import SwiftUI

/// diff 表示（DiffHunksBody）。staged hunk（HEAD↔index）と unstaged hunk
/// （index↔worktree）を新行番号順に統合表示し、hunk 単位の stage/解除・折りたたみを持つ。
struct DiffHunksView: View {
  @Bindable var model: EditorPaneModel
  let path: String
  @Environment(\.localization) private var l10n

  var body: some View {
    let hunks = model.mergedHunks(for: path)
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(Array(hunks.enumerated()), id: \.element.id) { index, hunk in
          hunkView(hunk, isFirst: index == 0)
        }
        if hunks.isEmpty {
          Text(l10n.string(.gitNoChanges))
            .font(Font.theme.paneRow)
            .foregroundStyle(Color.theme.textMuted)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.vertical, 5)
    }
  }

  private func hunkView(_ hunk: PaneMergedHunk, isFirst: Bool) -> some View {
    let collapsed = model.ui.collapsedHunks.contains(hunk.id)
    return VStack(spacing: 0) {
      hunkHeader(hunk, collapsed: collapsed, isFirst: isFirst)
      if !collapsed {
        ForEach(Array(hunk.hunk.lines.enumerated()), id: \.offset) { _, line in
          DiffLineRow(line: line)
        }
      }
    }
    .padding(.top, isFirst ? 0 : 4)
  }

  private func hunkHeader(
    _ hunk: PaneMergedHunk, collapsed: Bool, isFirst: Bool
  ) -> some View {
    let stat = hunk.stat
    return HStack(spacing: 7) {
      if hunk.staged {
        StatusGlyphView(kind: .done, size: 11)
      } else {
        RoundedRectangle(cornerRadius: 2.5)
          .strokeBorder(Color.theme.surfaceInk.opacity(0.22), lineWidth: 1)
          .frame(width: 11, height: 11)
      }
      Text(verbatim: "\(collapsed ? "▸" : "▾") \(hunk.header)")
        .foregroundStyle(collapsed ? Color.theme.textMuted : Color.theme.textSecondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .contentShape(Rectangle())
        .onTapGesture { toggleCollapse(hunk) }
      Spacer(minLength: 0)
      if hunk.staged {
        Text(verbatim: "staged")
          .font(Font.theme.paneSegment)
          .foregroundStyle(Color.theme.diffAdded)
          .layoutPriority(1)
        PaneMiniButton(label: l10n.string(.gitUnstageAction)) {
          model.actions?.unstageHunk(path: path, diff: hunk.diff, hunkIndex: hunk.hunkIndex)
        }
        .layoutPriority(1)
      } else {
        PaneMiniButton(label: "stage s") {
          model.actions?.stageHunk(
            path: path, diff: hunk.diff, hunkIndex: hunk.hunkIndex, untracked: hunk.untracked)
        }
        .layoutPriority(1)
        if collapsed {
          HStack(spacing: 3) {
            AddDelText(add: stat.add, del: stat.del)
          }
          .font(Font.theme.paneSegment)
          .layoutPriority(1)
        }
      }
    }
    .font(Font.theme.paneAnnotation)
    .padding(.horizontal, 12)
    .frame(height: 24)
    .paneRowClipped()
    .background(
      hunk.staged ? Color.theme.diffAdded.opacity(0.06) : Color.theme.surfaceInk.opacity(0.02)
    )
    .overlay(alignment: .top) {
      if !isFirst {
        Rectangle().fill(Color.theme.surfaceInk.opacity(0.04)).frame(height: 1)
      }
    }
    .overlay(alignment: .bottom) {
      if !collapsed {
        Rectangle().fill(Color.theme.surfaceInk.opacity(0.04)).frame(height: 1)
      }
    }
  }

  private func toggleCollapse(_ hunk: PaneMergedHunk) {
    if model.ui.collapsedHunks.contains(hunk.id) {
      model.ui.collapsedHunks.remove(hunk.id)
    } else {
      model.ui.collapsedHunks.insert(hunk.id)
    }
  }
}

/// diff 1 行（DiffLineRow）。追加=緑背景・削除=赤背景＋打ち消し線。
/// 行番号は新側（削除行は空欄）。
struct DiffLineRow: View {
  let line: DiffLine

  var body: some View {
    HStack(spacing: 0) {
      Text(verbatim: line.newLine.map(String.init) ?? " ")
        .foregroundStyle(numberColor)
        .frame(width: 30, alignment: .trailing)
        .padding(.trailing, 8)
      Text(verbatim: sign ?? " ")
        .foregroundStyle(line.kind == .added ? Color.theme.diffAdded : Color.theme.diffRemoved)
        .frame(width: 11, alignment: .leading)
      Text(verbatim: line.text.isEmpty ? " " : line.text)
        .foregroundStyle(textColor)
        .strikethrough(line.kind == .removed)
        .lineLimit(1)
        .textSelection(.enabled)
      Spacer(minLength: 0)
    }
    .font(Font.theme.paneRow)
    .frame(height: FileBodyView.lineHeight)
    .paneRowClipped()
    .background(background)
  }

  private var sign: String? {
    switch line.kind {
    case .added: return "+"
    case .removed: return "−"
    case .context: return nil
    }
  }

  private var numberColor: Color {
    switch line.kind {
    case .added: return .theme.diffAdded.opacity(0.65)
    case .removed: return .theme.diffRemoved.opacity(0.6)
    case .context: return .theme.textMuted.opacity(0.55)
    }
  }

  private var textColor: Color {
    switch line.kind {
    case .added: return .theme.textPrimary
    case .removed: return .theme.textMuted
    case .context: return .theme.textSecondary
    }
  }

  private var background: Color {
    switch line.kind {
    case .added: return .theme.diffAdded.opacity(0.1)
    case .removed: return .theme.diffRemoved.opacity(0.09)
    case .context: return .clear
    }
  }
}
