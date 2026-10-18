import SwiftUI

/// 詳細の「地図」。部品を入力の深さ順に 1 行ずつ縦に並べ、左の溝に入力のつながりを線で描き、続けて行き先の行を並べる。行は
/// 溝・役割・名前と予定の札と入力・未処理・前回（成否の印・時刻・量）。最新の回が失敗した部品は、行の下に理由の行を足す（溝の
/// 線は途切れずに続く）。地図に居る間は選ばれている部品の行に濃い地を敷く。部品の行のクリックはその部品を選ぶ。線の割り当ても
/// 行の文言も読み替えが解いた値で、ここは描くだけ。
struct BoardAutomationMapView: View {
  let model: BoardAutomationModel
  let detail: BoardAutomationDetailValue
  let selected: String?
  @Environment(\.localization) private var l10n

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      BoardSectionHeader(title: .boardAutomationFlow) {
        Text(l10n.format(.boardMapParts, detail.partCount))
        Text(l10n.string(.boardMapPending))
          .frame(width: BoardMapRowView.inboxWidth, alignment: .trailing)
        Text(l10n.string(.boardMapLast))
          .padding(.trailing, BoardMapRowView.lastInset)
          .frame(width: BoardMapRowView.lastWidth, alignment: .trailing)
      }
      ForEach(Array(detail.rows.enumerated()), id: \.offset) { _, row in
        let view = BoardMapRowView(row: row, laneCount: detail.laneCount, selected: selected)
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

/// 地図の 1 行と、失敗した部品なら下の理由の行。
struct BoardMapRowView: View {
  let row: BoardMapRow
  let laneCount: Int
  let selected: String?
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        BoardMapGutter(lanes: row.lanes, node: node)
          .frame(width: BoardMapGutter.width(laneCount), height: Self.height)
        switch row.content {
        case .part(let part): partCells(part)
        case .taskCandidates(let open):
          destinationCells(
            l10n.string(.boardOutputTaskCandidates), note: l10n.format(.boardMapOpen, open))
        case .reports(let destination):
          destinationCells(destination, note: nil)
        }
      }
      .lineLimit(1)
      .frame(height: Self.height)
      .background(
        isSelected ? Color.theme.selectionFill : Color.clear,
        in: RoundedRectangle(cornerRadius: Self.radius))
      if case .part(let part) = row.content, let failure = part.failure {
        reason(failure)
      }
    }
  }

  private var isSelected: Bool {
    if case .part(let part) = row.content { return part.key == selected }
    return false
  }

  private var node: MapNodeGlyph.Look {
    switch row.content {
    case .part(let part):
      switch part.look {
      case .idle: .idle
      case .failed: .failed
      case .running: .running
      }
    case .taskCandidates, .reports: .destination
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
      if let schedule = part.schedule { BoardScheduleChip(text: schedule).fixedSize() }
      if part.look == .running {
        Text(l10n.string(.automationRunning))
          .font(Font.theme.codeSmall)
          .foregroundStyle(Color.theme.accentBright)
          .fixedSize()
      }
      if part.breached {
        BoardChip(
          text: l10n.string(.boardMapFormatError), foreground: Color.theme.danger,
          fill: Color.theme.tintRed
        )
        .fixedSize()
      }
      if let inputs = part.inputs {
        fontResolver.text("← " + inputs, base: Theme.Typography.codeSmall)
          .font(Font.theme.codeSmall)
          .foregroundStyle(Color.theme.textMuted)
          .truncationMode(.tail)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .clipped()
    Text(part.inbox.map { "\($0)" } ?? "")
      .font(Font.theme.workspaceName)
      .foregroundStyle((part.inbox ?? 0) > 0 ? Color.theme.accentBright : Color.theme.textMuted)
      .frame(width: Self.inboxWidth, alignment: .trailing)
    last(part.last)
      .padding(.trailing, Self.lastInset)
      .frame(width: Self.lastWidth, alignment: .trailing)
  }

  /// 前回の列（成否の印・時刻・量）。まだ動いていなければ「まだ」。
  @ViewBuilder private func last(_ last: BoardMapPart.Last?) -> some View {
    HStack(spacing: 7) {
      if let last {
        BoardRunMarkGlyph(mark: last.mark)
        Text(last.at).foregroundStyle(Color.theme.textMuted)
        if let amount = last.amount {
          Text(amount.text)
            .foregroundStyle(
              amount.shade == .plain
                ? Color.theme.textSecondary : BoardRunColors.result(amount.shade))
        }
      } else {
        Text(l10n.string(.boardMapNever)).foregroundStyle(Color.theme.textMuted)
      }
    }
    .font(Font.theme.codeSmall)
    .foregroundStyle(Color.theme.textSecondary)
  }

  /// 失敗の理由の行。名前の列から書き、溝は下へ続く線を、理由の文の高さのまま縦に続ける。
  private func reason(_ failure: String) -> some View {
    fontResolver.text(failure, base: Theme.Typography.codeSmall)
      .font(Font.theme.codeSmall)
      .foregroundStyle(Color.theme.danger)
      .lineSpacing(Self.reasonLeading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.trailing, Self.lastInset)
      .padding(.bottom, Theme.Space.tick)
      .padding(.leading, BoardMapGutter.width(laneCount) + Self.roleWidth)
      .background(alignment: .leading) {
        BoardMapGutter(
          lanes: BoardMapLanes(
            node: 0, fromAbove: false, below: false, bends: [], through: row.lanes.continuing),
          node: nil
        )
        .frame(width: BoardMapGutter.width(laneCount))
      }
  }

  @ViewBuilder private func destinationCells(_ name: String, note: String?) -> some View {
    role(l10n.string(.boardMapDestination))
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
      .frame(width: Self.roleWidth, alignment: .leading)
  }

  static let height: CGFloat = 26
  static let inboxWidth: CGFloat = 48
  static let lastWidth: CGFloat = 150
  static let lastInset: CGFloat = 6
  private static let roleWidth: CGFloat = 52
  private static let cellGap: CGFloat = 6
  private static let radius: CGFloat = 6
  /// 理由の行の高さ 16（見本）に当たる行間。
  private static let reasonLeading = Theme.Typography.codeSmall.extraLeading(
    lineHeight: 16 / Theme.Typography.codeSmall.pointSize)
}

/// 地図の行の溝。線は 1 行の高さの中で、上の行から来る線・下の行へ続く線・点へ曲がり込む線を描き、点を重ねる。点の線は点の
/// 縁で止める（線が点の中に入らない）。点が無ければ（理由の行）線だけ。
struct BoardMapGutter: View {
  let lanes: BoardMapLanes
  let node: MapNodeGlyph.Look?

  static func width(_ laneCount: Int) -> CGFloat {
    CGFloat(max(laneCount, 1)) * spacing + first
  }

  var body: some View {
    let x = Self.x(lanes.node)
    let mid = BoardMapRowView.height / 2
    let edge: CGFloat = 4.5
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
      if let node {
        MapNodeGlyph(look: node).position(x: x, y: mid)
      }
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

/// 予定の札（枠だけの札）。
struct BoardScheduleChip: View {
  let text: String

  var body: some View {
    Text(text)
      .font(Font.theme.meta)
      .foregroundStyle(Color.theme.textSecondary)
      .padding(.horizontal, 7)
      .frame(minHeight: 18)
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.sm)
          .strokeBorder(Color.theme.inputBorder, lineWidth: Theme.Stroke.hairline))
  }
}

/// 塗りの札（出力の形式エラー）。
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

/// 回の結果の文と帯の色。
enum BoardRunColors {
  static func result(_ shade: BoardRunShade) -> Color {
    switch shade {
    case .plain: Color.theme.textPrimary
    case .sunk: Color.theme.textMuted
    case .failed: Color.theme.danger
    }
  }
}
