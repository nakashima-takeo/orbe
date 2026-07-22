import SwiftUI

/// 左レール: 履歴タブ（HistoryRail・幅 240）。first-parent 基準の簡易2レーン
/// グラフ＋コミット行（HEAD/ref/tag バッジ・相対日時・未push）＋先頭の「未コミットの変更」ノード。
/// スクロール末尾で追加読み込み。フッタに凡例＋`<upstream> から +N`。
struct HistoryRailView: View {
  @Bindable var model: EditorPaneModel
  @Environment(\.localization) private var l10n

  private static let rowHeight: CGFloat = 34
  private static let laneX: [CGFloat] = [8, 22]  // 見本のドット x（lane 0 / 1）
  private static let dotSize: CGFloat = 9

  var body: some View {
    let rows = model.historyRows()
    VStack(spacing: 0) {
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            rowView(row)
              .onAppear {
                if index == rows.count - 1, !model.historyExhausted {
                  model.actions?.loadMoreHistory()
                }
              }
          }
        }
        .background(alignment: .topLeading) {
          graphEdges(rows: rows)
        }
        .padding(.top, 6)
      }
      footer
    }
  }

  // MARK: - 行

  private func rowView(_ row: PaneHistoryRow) -> some View {
    let selected = model.resolvedHistorySelection == row.selection
    return VStack(alignment: .leading, spacing: 1) {
      titleLine(row, selected: selected)
      subLine(row)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding(.top, 4)
    .padding(.leading, 40)
    .padding(.trailing, 8)
    .frame(height: Self.rowHeight, alignment: .top)
    .background(selected ? Color.theme.accentPrimary.opacity(0.1) : Color.clear)
    .overlay(alignment: .topLeading) {
      dot(row)
        .offset(x: Self.laneX[row.lane], y: 13)
    }
    .contentShape(Rectangle())
    .onTapGesture { model.actions?.selectHistory(row.selection) }
  }

  @ViewBuilder private func titleLine(
    _ row: PaneHistoryRow, selected: Bool
  ) -> some View {
    let dim = row.lane == 1
    HStack(spacing: 5) {
      Text(title(of: row))
        .font(Font.theme.paneControl)
        .foregroundStyle(
          selected || isUncommitted(row)
            ? Color.theme.textPrimary : dim ? Color.theme.textMuted : Color.theme.textSecondary
        )
        .lineLimit(1)
        .truncationMode(.tail)
      ForEach(row.badges) { badge in
        refBadge(badge)
      }
    }
  }

  private func isUncommitted(_ row: PaneHistoryRow) -> Bool {
    if case .uncommitted = row.kind { return true }
    return false
  }

  private func title(of row: PaneHistoryRow) -> String {
    switch row.kind {
    case .uncommitted: return l10n.string(.gitUncommittedChanges)
    case .commit(let commit): return "\(commit.shortOid) \(commit.subject)"
    }
  }

  @ViewBuilder private func subLine(_ row: PaneHistoryRow) -> some View {
    let dim = row.lane == 1
    Group {
      switch row.kind {
      case .uncommitted(let fileCount, let add, let del):
        HStack(spacing: 3) {
          Text(verbatim: "\(fileCount) files ·")
          AddDelText(add: add, del: del)
        }
      case .commit(let commit):
        (Text(verbatim: "\(RelativeDate.string(from: commit.date, l10n)) · \(commit.author)")
          + (row.unpushed
            ? Text(verbatim: " · ")
              + Text(l10n.string(.gitUnpushed)).foregroundColor(.theme.accentPrimary)
            : Text("")))
          .lineLimit(1)
      }
    }
    .font(Font.theme.paneFootnote)
    .foregroundStyle(dim ? Color.theme.stateIdle : Color.theme.textMuted)
  }

  private func refBadge(_ badge: PaneRefBadge) -> some View {
    Group {
      switch badge.style {
      case .head:
        Text(badge.label)
          .foregroundStyle(Color.theme.tabActiveText)
          .padding(.horizontal, 5)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color.theme.textPrimary))
      case .remote:
        Text(badge.label)
          .foregroundStyle(Color.theme.stateIdle)
          .padding(.horizontal, 5)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(Color.theme.stateIdle.opacity(0.4), lineWidth: 1))
      case .tag:
        Text(badge.label)
          .foregroundStyle(Color.theme.stateWaiting)
          .padding(.horizontal, 5)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(Color.theme.stateWaiting.opacity(0.35), lineWidth: 1))
      }
    }
    .font(Font.theme.paneTag)
    .lineLimit(1)
    .fixedSize()
  }

  @ViewBuilder private func dot(_ row: PaneHistoryRow) -> some View {
    let size = Self.dotSize
    switch row.dot {
    case .uncommitted:
      Circle().fill(Color.theme.accentPrimary)
        .frame(width: size, height: size)
        .background(
          Circle().fill(Color.theme.accentPrimary.opacity(0.2))
            .frame(width: size + 6, height: size + 6))
    case .head:
      Circle().fill(Color.theme.textPrimary).frame(width: size, height: size)
    case .unpushed:
      Circle().fill(Color.theme.accentPrimary.opacity(0.85)).frame(width: size, height: size)
    case .merge:
      Circle().fill(Color.theme.bgBase)
        .overlay(Circle().strokeBorder(Color.theme.accentPrimary, lineWidth: 1.5))
        .frame(width: size, height: size)
    case .other:
      Circle().fill(Color.theme.stateIdle).frame(width: size, height: size)
    }
  }

  // MARK: - グラフエッジ（コミット → 可視な親を結ぶ。同レーンは直線・跨ぎは曲線）

  private func graphEdges(rows: [PaneHistoryRow]) -> some View {
    // 行 index（= y 位置）を id で引けるように。
    var rowIndex: [String: Int] = [:]
    var lanes: [String: Int] = [:]
    for (i, row) in rows.enumerated() {
      rowIndex[row.id] = i
      lanes[row.id] = row.lane
    }
    func center(_ index: Int, lane: Int) -> CGPoint {
      CGPoint(
        x: Self.laneX[lane] + Self.dotSize / 2,
        y: CGFloat(index) * Self.rowHeight + 13 + Self.dotSize / 2)
    }
    return Canvas { context, _ in
      for (i, row) in rows.enumerated() {
        let from = center(i, lane: row.lane)
        let targets: [String]
        switch row.kind {
        case .uncommitted:
          targets = model.commits.first.map { [$0.oid] } ?? []
        case .commit(let commit):
          targets = commit.parents
        }
        for parentOid in targets {
          guard let j = rowIndex[parentOid], let parentLane = lanes[parentOid] else { continue }
          let to = center(j, lane: parentLane)
          var path = Path()
          path.move(to: from)
          let color: Color
          let opacity: CGFloat
          if parentLane == row.lane {
            path.addLine(to: to)
            color = row.lane == 0 ? .theme.accentPrimary : .theme.stateIdle
            opacity = row.lane == 0 ? 0.75 : 0.8
          } else {
            // レーン跨ぎは縦3分割の制御点で緩く曲げる（見本のベジェ相当）。
            let third = (to.y - from.y) / 3
            path.addCurve(
              to: to,
              control1: CGPoint(x: from.x, y: from.y + third * 2),
              control2: CGPoint(x: to.x, y: to.y - third * 2))
            color = row.lane == 0 ? .theme.accentPrimary : .theme.stateIdle
            opacity = row.lane == 0 ? 0.55 : 0.8
          }
          context.stroke(
            path, with: .color(color.opacity(opacity)), lineWidth: 1.5)
        }
      }
    }
    .frame(height: CGFloat(rows.count) * Self.rowHeight)
    .allowsHitTesting(false)
  }

  // MARK: - フッタ（凡例＋ ahead）

  private var footer: some View {
    HStack(spacing: 8) {
      legend("feature", color: .theme.accentPrimary)
      legend("main", color: .theme.stateIdle)
      Spacer(minLength: 0)
      if let upstream = model.upstream, let ahead = model.ahead {
        (Text(l10n.format(.gitAheadOfUpstream, upstream))
          + Text(verbatim: "+\(ahead)").foregroundColor(.theme.accentPrimary))
          .lineLimit(1)
      }
    }
    .font(Font.theme.paneFootnote)
    .foregroundStyle(Color.theme.textMuted)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .overlay(alignment: .top) {
      Rectangle().fill(Color.theme.surfaceInk.opacity(0.06)).frame(height: 1)
    }
  }

  private func legend(_ label: String, color: Color) -> some View {
    HStack(spacing: 4) {
      RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 8, height: 2)
      Text(label)
    }
  }
}
