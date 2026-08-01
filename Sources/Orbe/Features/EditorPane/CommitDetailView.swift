import SwiftUI

/// 履歴タブの右ビューア（CommitDetail）。hash・メッセージ・日時・author・
/// files 集計・変更ファイルリスト・選択ファイルの diff プレビュー・checkout/revert（無配線）・
/// hash⧉（コピー）。「未コミットの変更」ノード選択時は現在の変更を同レイアウトで出す。
struct CommitDetailView: View {
  @Bindable var model: EditorPaneModel
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  /// リストに出すファイル数の上限（超過分は gitMoreFiles）。
  private static let fileListCap = 8

  @State private var previewPath: String?

  var body: some View {
    Group {
      switch model.resolvedHistorySelection {
      case .uncommitted:
        uncommittedDetail
      case .commit(let oid):
        commitDetail(oid: oid)
      case nil:
        Text(l10n.string(.gitNoCommits))
          .font(Font.theme.paneRow)
          .foregroundStyle(Color.theme.textMuted)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: model.resolvedHistorySelection) { previewPath = nil }
  }

  // MARK: - コミット詳細

  @ViewBuilder private func commitDetail(oid: String) -> some View {
    if let detail = model.commitDetail, detail.commit.oid == oid {
      let files = detail.files
      let stat = Self.stat(of: files)
      let selectedPath = previewPath ?? files.first?.displayPath
      VStack(spacing: 0) {
        headerRow(
          lead: Text(detail.commit.shortOid).foregroundColor(.theme.accentPrimary),
          subject: detail.commit.subject,
          trailing:
            "\(RelativeDate.string(from: detail.commit.date, l10n)) · \(detail.commit.author)")
        statRow(fileCount: files.count, add: stat.add, del: stat.del) {
          PaneMiniButton(label: "checkout", font: Font.theme.paneSegment) {}  // unwired (follow-up)
          PaneMiniButton(label: "revert", font: Font.theme.paneSegment) {}  // unwired (follow-up)
          PaneMiniButton(label: "hash⧉", font: Font.theme.paneSegment) {
            model.actions?.copyToPasteboard(detail.commit.oid)
          }
        }
        fileList(
          rows: files.map { diff in
            FileRowData(
              badge: Self.badge(of: diff), path: diff.displayPath,
              stat: Self.stat(of: [diff]))
          },
          selectedPath: selectedPath)
        diffPreview(diffs: files, path: selectedPath, mergedFallback: false)
      }
    } else {
      Text(l10n.string(.commonLoading))
        .font(Font.theme.paneRow)
        .foregroundStyle(Color.theme.textMuted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - 未コミットの変更

  private var uncommittedDetail: some View {
    let stat = model.totalStat
    let selectedPath = previewPath ?? model.files.first?.path
    return VStack(spacing: 0) {
      headerRow(
        lead: Text(l10n.string(.gitUncommitted)).foregroundColor(.theme.accentPrimary),
        subject: l10n.string(.gitUncommittedChanges), trailing: "")
      statRow(fileCount: model.files.count, add: stat.add, del: stat.del) {}
      fileList(
        rows: model.files.map { change in
          FileRowData(
            badge: ChangeBadge.of(change), path: change.path,
            stat: model.diffStat(of: change.path))
        },
        selectedPath: selectedPath)
      diffPreview(diffs: [], path: selectedPath, mergedFallback: true)
    }
  }

  // MARK: - 部品

  private func headerRow(lead: Text, subject: String, trailing: String) -> some View {
    HStack(spacing: 7) {
      lead
        .lineLimit(1)
        .layoutPriority(1)
      Text(subject)
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      Text(trailing)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .layoutPriority(1)
    }
    .font(Font.theme.paneControl)
    .padding(.horizontal, 12)
    .frame(height: 30)
    .paneRowClipped()
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.theme.surfaceInk.opacity(0.05)).frame(height: 1)
    }
  }

  private func statRow<Buttons: View>(
    fileCount: Int, add: Int, del: Int, @ViewBuilder buttons: () -> Buttons
  ) -> some View {
    HStack(spacing: 6) {
      HStack(spacing: 3) {
        Text(verbatim: "\(fileCount) files ·")
        AddDelText(add: add, del: del)
      }
      .lineLimit(1)
      .layoutPriority(1)
      Spacer(minLength: 0)
      buttons()
    }
    .font(Font.theme.paneSegment)
    .foregroundStyle(Color.theme.textMuted)
    .padding(.horizontal, 12)
    .frame(height: 24)
    .paneRowClipped()
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.theme.surfaceInk.opacity(0.05)).frame(height: 1)
    }
  }

  private struct FileRowData {
    let badge: ChangeBadge
    let path: String
    let stat: (add: Int, del: Int)
  }

  private func fileList(rows: [FileRowData], selectedPath: String?) -> some View {
    VStack(spacing: 0) {
      ForEach(rows.prefix(Self.fileListCap), id: \.path) { row in
        fileRow(row, selected: row.path == selectedPath)
      }
      if rows.count > Self.fileListCap {
        HStack {
          Text(
            l10n.plural(
              rows.count - Self.fileListCap, one: .gitMoreFilesOne, other: .gitMoreFilesOther)
          )
          .font(Font.theme.paneFootnote)
          .foregroundStyle(Color.theme.stateIdle)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 18)
      }
    }
    .padding(.vertical, 5)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.theme.surfaceInk.opacity(0.05)).frame(height: 1)
    }
  }

  private func fileRow(_ row: FileRowData, selected: Bool) -> some View {
    HStack(spacing: 7) {
      StatusBadgeView(badge: row.badge, size: 12, font: Font.theme.paneBadge)
      fontResolver.text(row.path, base: Theme.Typography.paneControl)
        .foregroundStyle(selected ? Color.theme.textPrimary : Color.theme.textSecondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
      HStack(spacing: 3) {
        AddDelText(add: row.stat.add, del: row.stat.del)
      }
      .font(Font.theme.paneFootnote)
    }
    .font(Font.theme.paneControl)
    .padding(.horizontal, 12)
    .frame(height: 20)
    .paneRowClipped()
    .background(selected ? Color.theme.surfaceInk.opacity(0.05) : Color.clear)
    .contentShape(Rectangle())
    .onTapGesture { previewPath = row.path }
  }

  /// 選択ファイルの diff プレビュー（残り高をスクロール）。
  /// mergedFallback は未コミットノード用（model の統合 hunks から描く）。
  @ViewBuilder private func diffPreview(
    diffs: [FileDiff], path: String?, mergedFallback: Bool
  ) -> some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        if let path {
          if mergedFallback {
            ForEach(model.mergedHunks(for: path)) { hunk in
              previewHunk(path: path, header: hunk.header, lines: hunk.hunk.lines)
            }
          } else if let diff = diffs.first(where: { $0.displayPath == path }) {
            ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
              previewHunk(
                path: path,
                header:
                  "@@ −\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@",
                lines: hunk.lines)
            }
          }
        }
      }
      .padding(.vertical, 5)
    }
  }

  private func previewHunk(path: String, header: String, lines: [DiffLine]) -> some View {
    VStack(spacing: 0) {
      HStack {
        Text(verbatim: "\(path) · \(header)")
          .font(Font.theme.paneAnnotation)
          .foregroundStyle(Color.theme.stateIdle)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 2)
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        DiffLineRow(line: line)
      }
    }
  }

  private static func badge(of diff: FileDiff) -> ChangeBadge {
    if diff.isNew { return .added }
    if diff.isDeleted { return .deleted }
    return .modified
  }

  private static func stat(of diffs: [FileDiff]) -> (add: Int, del: Int) {
    let lines = diffs.flatMap(\.hunks).flatMap(\.lines)
    return (
      lines.filter { $0.kind == .added }.count, lines.filter { $0.kind == .removed }.count
    )
  }
}
