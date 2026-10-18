import SwiftUI

/// 詳細の「地図」。部品を入力の深さ順に 1 行ずつ縦に並べ、左の溝に入力のつながりを線で描き、続けて Orbe への終わりの行を
/// 並べる。行は溝・役割・名前と予定の札と入力・決まりを外した札・溜まり・前回。地図に居る間は選ばれている部品の行に濃い地を
/// 敷く。部品の行のクリックはその部品を選ぶ。線の割り当ても行の文言も読み替えが解いた値で、ここは描くだけ。
struct BoardAutomationMapView: View {
  let model: BoardAutomationModel
  let detail: BoardAutomationDetailValue
  let selected: String?
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    let roles = detail.rows.map { row in
      if case .part(let part) = row.content { return part.role }
      return BoardMapRowView.endRole
    }
    let roleWidth = max(
      BoardMapRowView.minRoleWidth,
      (roles.map { fontResolver.width($0, base: Theme.Typography.codeSmall) }.max()?.rounded(.up)
        ?? 0) + BoardMapRowView.roleGap)
    VStack(alignment: .leading, spacing: 0) {
      BoardSectionHeader(title: .boardAutomationFlow) {
        Text(l10n.format(.boardMapParts, detail.partCount))
        Text(l10n.string(.boardPartInbox))
          .frame(width: BoardMapRowView.inboxWidth, alignment: .trailing)
        Text(l10n.string(.boardMapLast))
          .padding(.trailing, BoardMapRowView.lastInset)
          .frame(width: BoardMapRowView.lastWidth, alignment: .trailing)
      }
      ForEach(Array(detail.rows.enumerated()), id: \.offset) { _, row in
        let view = BoardMapRowView(
          row: row, laneCount: detail.laneCount, roleWidth: roleWidth, selected: selected)
        if case .part(let part) = row.content {
          view.contentShape(Rectangle()).onTapGesture { model.tapPart(part.key) }
        } else {
          view
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 地図の 1 行。
struct BoardMapRowView: View {
  let row: BoardMapRow
  let laneCount: Int
  /// 役割の列の幅（地図の行で揃える）。
  let roleWidth: CGFloat
  let selected: String?
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    HStack(spacing: 0) {
      BoardMapGutter(lanes: row.lanes, node: node)
        .frame(width: BoardMapGutter.width(laneCount), height: Self.height)
      switch row.content {
      case .part(let part): partCells(part)
      case .taskCandidates(let open):
        endCells(
          l10n.string(.boardOutputTaskCandidates), note: l10n.format(.boardMapOpen, open))
      case .report:
        endCells(l10n.string(.boardOutputReport), note: nil)
      }
    }
    .lineLimit(1)
    .frame(height: Self.height)
    .background(
      isSelected ? Color.theme.selectionFill : Color.clear,
      in: RoundedRectangle(cornerRadius: Self.radius))
  }

  private var isSelected: Bool {
    if case .part(let part) = row.content { return part.key == selected }
    return false
  }

  private var node: BoardMapGutter.Node {
    switch row.content {
    case .part(let part): .part(part.look)
    case .taskCandidates, .report: .end
    }
  }

  @ViewBuilder private func partCells(_ part: BoardMapPart) -> some View {
    role(part.role)
    HStack(spacing: Self.cellGap) {
      fontResolver.text(part.name, base: Theme.Typography.code)
        .font(Font.theme.code)
        .foregroundStyle(Color.theme.textPrimary)
        .padding(.trailing, Theme.Space.hair)
        .layoutPriority(1)
      BoardScheduleChip(text: part.schedule, arrival: part.arrival).fixedSize()
      if let inputs = part.inputs {
        fontResolver.text("← " + inputs, base: Theme.Typography.codeSmall)
          .font(Font.theme.codeSmall)
          .foregroundStyle(Color.theme.textMuted)
          .truncationMode(.tail)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .clipped()
    if part.breached {
      BoardChip(
        text: l10n.string(.boardMapBreach), foreground: Color.theme.danger,
        fill: Color.theme.tintRed
      )
      .fixedSize()
      .padding(.leading, Self.cellGap)
    }
    Text(part.inbox.map { "\($0)" } ?? "")
      .font(Font.theme.workspaceName)
      .foregroundStyle((part.inbox ?? 0) > 0 ? Color.theme.accentBright : Color.theme.textMuted)
      .frame(width: Self.inboxWidth, alignment: .trailing)
    Text(part.last)
      .font(Font.theme.codeSmall)
      .foregroundStyle(BoardRunColors.last(part.lastShade))
      .padding(.trailing, Self.lastInset)
      .frame(width: Self.lastWidth, alignment: .trailing)
  }

  @ViewBuilder private func endCells(_ name: String, note: String?) -> some View {
    role(Self.endRole)
    HStack(spacing: Self.cellGap) {
      Text(name)
        .font(Font.theme.code)
        .foregroundStyle(Color.theme.textPrimary)
        .padding(.trailing, Theme.Space.hair)
      if let note {
        Text(note).font(Font.theme.codeSmall).foregroundStyle(Color.theme.textMuted)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func role(_ text: String) -> some View {
    Text(text)
      .font(Font.theme.codeSmall)
      .foregroundStyle(Color.theme.textMuted)
      .frame(width: roleWidth, alignment: .leading)
  }

  static let height: CGFloat = 26
  static let inboxWidth: CGFloat = 44
  static let lastWidth: CGFloat = 96
  static let lastInset: CGFloat = 6
  /// 役割の列の幅の下限（見本）と、長い役割の名前（英語）の後ろに空ける幅。
  static let minRoleWidth: CGFloat = 44
  static let roleGap: CGFloat = 6
  /// 終わりの行の役割の欄。
  static let endRole = "Orbe"
  private static let cellGap: CGFloat = 6
  private static let radius: CGFloat = 6
}

/// 地図の行の溝。線は 1 行の高さの中で、上の行から来る線・下の行へ続く線・点へ曲がり込む線を描き、点（部品の見え方か、
/// 終わりの行の塗った点）を重ねる。点の線は点の縁で止める（線が点の中に入らない）。
struct BoardMapGutter: View {
  enum Node: Equatable {
    case part(BoardNodeLook)
    case end
  }

  let lanes: BoardMapLanes
  let node: Node

  static func width(_ laneCount: Int) -> CGFloat {
    CGFloat(max(laneCount, 1)) * spacing + first
  }

  var body: some View {
    let x = Self.x(lanes.node)
    let mid = BoardMapRowView.height / 2
    let edge = BoardNodeView.size / 2
    ZStack(alignment: .topLeading) {
      Canvas { context, size in
        var path = Path()
        for lane in lanes.through {
          path.move(to: CGPoint(x: Self.x(lane), y: 0))
          path.addLine(to: CGPoint(x: Self.x(lane), y: size.height))
        }
        if lanes.fromAbove {
          path.move(to: CGPoint(x: x, y: 0))
          path.addLine(to: CGPoint(x: x, y: mid - edge))
        }
        if lanes.below {
          path.move(to: CGPoint(x: x, y: mid + edge))
          path.addLine(to: CGPoint(x: x, y: size.height))
        }
        for lane in lanes.bends {
          let from = Self.x(lane)
          let toward: CGFloat = from < x ? 1 : -1
          path.move(to: CGPoint(x: from, y: 0))
          path.addQuadCurve(
            to: CGPoint(x: from + toward * Self.bend, y: mid), control: CGPoint(x: from, y: mid))
          path.addLine(to: CGPoint(x: x - toward * edge, y: mid))
        }
        context.stroke(path, with: .color(Self.rail), lineWidth: Self.line)
      }
      Group {
        switch node {
        case .part(let look): BoardNodeView(look: look)
        case .end:
          Circle().fill(Color.theme.accentPrimary)
            .frame(width: BoardNodeView.size, height: BoardNodeView.size)
        }
      }
      .position(x: x, y: mid)
    }
  }

  private static func x(_ lane: Int) -> CGFloat {
    first + CGFloat(lane) * spacing
  }

  /// 線の間隔。
  private static let spacing: CGFloat = 14
  /// 最も左の線の中心。
  private static let first: CGFloat = 8
  /// 曲がり込む線が横へ折れるまでの幅。
  private static let bend: CGFloat = 7
  private static let line: CGFloat = 1.5
  private static let rail = Color.theme.borderInk.opacity(0.26)
}

/// 部品の点。普段は強調色の輪、最新の回が失敗なら赤の輪と淡い赤の地、走っている間は回る輪。
struct BoardNodeView: View {
  let look: BoardNodeLook
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let size: CGFloat = 9

  var body: some View {
    switch look {
    case .idle:
      Circle().strokeBorder(Color.theme.accentPrimary, lineWidth: Self.ring)
        .frame(width: Self.size, height: Self.size)
    case .failed:
      Circle().fill(Color.theme.tintRed)
        .overlay(Circle().strokeBorder(Color.theme.danger, lineWidth: Self.ring))
        .frame(width: Self.size, height: Self.size)
    case .running:
      if reduceMotion {
        spinner(angle: 0)
      } else {
        TimelineView(.animation) { context in
          let t = context.date.timeIntervalSinceReferenceDate
          spinner(
            angle: t.truncatingRemainder(dividingBy: Theme.Motion.spin) / Theme.Motion.spin * 360)
        }
      }
    }
  }

  private func spinner(angle: Double) -> some View {
    Circle()
      .trim(from: 0, to: Self.arc)
      .stroke(Color.theme.stateWorking, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
      .frame(width: 7, height: 7)
      .rotationEffect(.degrees(angle))
      .frame(width: 11, height: 11)
  }

  private static let ring: CGFloat = 1.5
  /// 回る輪の弧の割合（見本の dasharray 6 / 周 22）。
  private static let arc: CGFloat = 6 / 22
}

/// 予定の札。「届いたら」は沈めて、時刻の予定と見分ける。
struct BoardScheduleChip: View {
  let text: String
  let arrival: Bool

  var body: some View {
    Text(text)
      .font(Font.theme.meta)
      .foregroundStyle(arrival ? Color.theme.textMuted : Color.theme.textSecondary)
      .padding(.horizontal, 7)
      .frame(minHeight: 18)
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.sm)
          .strokeBorder(Color.theme.inputBorder, lineWidth: Theme.Stroke.hairline))
  }
}

/// 塗りの札（モデル・ツール・決まりを外した）。
struct BoardChip: View {
  let text: String
  var foreground = Color.theme.textSecondary
  var fill = Color.theme.plainPillFill

  var body: some View {
    Text(text)
      .font(Font.theme.meta)
      .foregroundStyle(foreground)
      .padding(.horizontal, 7)
      .frame(minHeight: 18)
      .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
  }
}

/// 回の結果の文の色。
enum BoardRunColors {
  static func result(_ shade: BoardRunShade) -> Color {
    switch shade {
    case .plain: Color.theme.textPrimary
    case .sunk: Color.theme.textMuted
    case .failed: Color.theme.danger
    case .running: Color.theme.accentBright
    }
  }

  /// 地図の前回の列。何かが起きた回は本文より一段沈めた色。
  static func last(_ shade: BoardRunShade) -> Color {
    shade == .plain ? Color.theme.textSecondary : result(shade)
  }

  static func strip(_ tone: BoardRunTone) -> Color {
    switch tone {
    case .produced: Color.theme.accentPrimary
    case .quiet: Color.theme.editorGhost
    case .failed: Color.theme.danger
    }
  }
}
