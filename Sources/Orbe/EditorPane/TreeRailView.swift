import SwiftUI

/// 左レール: ツリータブ（TreeRail）。実ワークツリーのファイルツリー
/// （フォルダ開閉・種別アイコン・M/A バッジ・全ファイル選択可）＋フッタの変更集計。
struct TreeRailView: View {
  @Bindable var model: EditorPaneModel
  @Environment(\.localization) private var l10n

  /// depth → 左パディング（見本 INDENT。それ以深は等差で延長）。
  private static func indent(_ depth: Int) -> CGFloat {
    let base: [CGFloat] = [10, 22, 36]
    return depth < base.count ? base[depth] : base[2] + CGFloat(depth - 2) * 14
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(model.treeRows()) { row in
            switch row.kind {
            case .folder(let open):
              folderRow(row, open: open)
            case .file(let badge):
              fileRow(row, badge: badge)
            }
          }
        }
        .padding(.vertical, 5)
      }
      footer
    }
  }

  private func folderRow(_ row: PaneTreeRow, open: Bool) -> some View {
    HStack(spacing: 5) {
      Text(verbatim: open ? "▾" : "▸")
        .foregroundStyle(Color.theme.textMuted)
      FileIconView(name: MochaIcon.name(folder: row.name, open: open), dim: !open)
      Text(row.name)
        .foregroundStyle(open ? Color.theme.textSecondary : Color.theme.textMuted)
      Spacer(minLength: 0)
    }
    .font(Font.theme.paneRow)
    .padding(.leading, Self.indent(row.depth))
    .padding(.trailing, 10)
    .frame(height: 22)
    .contentShape(Rectangle())
    .onTapGesture { model.toggleTreeFolder(row.path) }
  }

  private func fileRow(_ row: PaneTreeRow, badge: ChangeBadge?) -> some View {
    let selected = model.ui.selectedPath == row.path
    return HStack(spacing: 5) {
      FileIconView(name: MochaIcon.name(file: row.name))
      Text(row.name)
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(selected ? Color.theme.textPrimary : Color.theme.textSecondary)
      Spacer(minLength: 0)
      if let badge {
        Text(badge.letter).foregroundStyle(badge.color)
      }
    }
    .font(Font.theme.paneRow)
    .padding(.leading, Self.indent(row.depth))
    .padding(.trailing, 10)
    .frame(height: 22)
    .background(selected ? Color.theme.surfaceInk.opacity(0.07) : Color.clear)
    .contentShape(Rectangle())
    .onTapGesture { model.select(path: row.path) }
  }

  /// フッタ: `変更 N · +A −D`。
  private var footer: some View {
    let stat = model.totalStat
    return HStack(spacing: 6) {
      Text(l10n.format(.gitChangesCount, model.changedFiles.count))
      Text(verbatim: "+\(stat.add)").foregroundStyle(Color.theme.diffAdded)
      Text(verbatim: "−\(stat.del)").foregroundStyle(Color.theme.diffRemoved)
      Spacer(minLength: 0)
    }
    .font(Font.theme.paneFootnote)
    .foregroundStyle(Color.theme.textMuted)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .overlay(alignment: .top) {
      Rectangle().fill(Color.theme.surfaceInk.opacity(0.06)).frame(height: 1)
    }
  }
}
