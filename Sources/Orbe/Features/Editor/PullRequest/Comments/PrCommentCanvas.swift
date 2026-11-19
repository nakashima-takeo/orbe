import AppKit
import OrbeEditorCore

/// スレッドの絵の要素と選べる文を積む。
@MainActor
struct PrCommentCanvas {
  let state: PrCommentPicture.State
  var elements: [ZoneElement] = []
  var texts: [ZoneText] = []
  var links: [Int: URL] = [:]

  /// 本文の行の高さ（字 12・行高 1.6）。
  static let bodyLineHeight =
    Theme.Typography.editorPrThreadBody.pointSize * Theme.Typography.editorPrThreadBodyLineHeight

  init(state: PrCommentPicture.State) {
    self.state = state
  }

  /// 選べない字の行。
  mutating func label(_ string: String, font: NSFont, color: NSColor, x: CGFloat, baseline: CGFloat)
  {
    guard !string.isEmpty else { return }
    elements.append(
      .text(
        ZoneTextLine(
          origin: CGPoint(x: x, y: baseline), runs: [ZoneTextRun(string, font: font, color: color)])
      ))
  }

  mutating func button(_ control: PrCommentControl, _ frame: CGRect) {
    elements.append(.button(ZoneButton(id: control, frame: frame)))
  }

  /// 押せる姿なら `color`、押せない姿なら薄めた色。
  func enabled(_ color: NSColor, _ enabled: Bool) -> NSColor {
    enabled ? color : PrCommentStyle.disabled(color)
  }

  /// 左上 `origin` の行 `line` の見え方ごとの飾り——インラインコードの地（余白込み・角丸 3）、取り消し線、リンクの押せる場所。
  mutating func decorate(
    _ line: ZoneTextLayout.Line, _ block: PrCommentBlock, at origin: CGPoint, baseline: CGFloat
  ) {
    let (left, top, height) = (origin.x, origin.y, Self.bodyLineHeight)
    let mono = Theme.Typography.editorPrThreadCode
    for (index, style) in block.text.styles.enumerated() {
      let spans = line.spans(of: index)
      guard !spans.isEmpty else { continue }
      if style.leadingPadding > 0 {
        for span in spans {
          elements.append(
            .box(
              ZoneBox(
                frame: CGRect(
                  x: left + span.lowerBound, y: baseline - mono.ascender - 1,
                  width: span.upperBound - span.lowerBound,
                  height: mono.ascender - mono.descender + 2),
                radius: .init(Theme.Layout.editorPrInlineCodeRadius),
                fill: Theme.Color.editorPrInlineCode)))
        }
      }
      if block.strikes.contains(index) {
        let font = style.font
        let y = baseline - CTFontGetXHeight(font) / 2
        for span in spans {
          elements.append(
            .box(
              ZoneBox(
                frame: CGRect(
                  x: left + span.lowerBound, y: y - 0.5, width: span.upperBound - span.lowerBound,
                  height: 1), fill: style.color)))
        }
      }
      if let url = block.links[index] {
        for span in spans {
          let id = links.count
          links[id] = url
          elements.append(
            .button(
              ZoneButton(
                id: PrCommentControl.link(id),
                frame: CGRect(
                  x: left + span.lowerBound, y: top, width: span.upperBound - span.lowerBound,
                  height: height))))
        }
      }
    }
  }

  /// 箱（地・枠・影）と頭の帯（無ければ帯なし）を下に敷き、絵にする。`bottom` は箱の下端。
  func finish(_ frame: CGRect, bottom: CGFloat, head: PrCommentPicture.Head?)
    -> PrCommentPicture.Composed
  {
    let outer = CGRect(
      x: frame.minX, y: frame.minY, width: frame.width, height: bottom - frame.minY)
    let inner = outer.insetBy(dx: 1, dy: 1)
    let radius = Theme.Layout.editorPrThreadRadius
    var ground: [ZoneElement] = [
      .box(
        ZoneBox(
          frame: outer, radius: .init(radius), fill: Theme.Color.editorPrThreadGround,
          stroke: .init(color: Theme.Color.editorPrThreadBorder, width: 1),
          shadow: .init(
            color: Theme.Color.editorPrThreadShadow, offset: Theme.Layout.editorPrThreadShadowY,
            blur: Theme.Layout.editorPrThreadShadowBlur)))
    ]
    switch head {
    case .top:
      let band = Theme.Layout.editorPrThreadHead
      ground.append(
        .box(
          ZoneBox(
            frame: CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: band),
            radius: .init(top: radius - 1, bottom: 0), fill: Theme.Color.editorPrThreadHead)))
      ground.append(
        .box(
          ZoneBox(
            frame: CGRect(x: inner.minX, y: inner.minY + band, width: inner.width, height: 1),
            fill: EditorStyle.hairline(0.08))))
    case .whole:
      ground.append(
        .box(
          ZoneBox(frame: inner, radius: .init(radius - 1), fill: Theme.Color.editorPrThreadHead)))
    case nil: break
    }
    return PrCommentPicture.Composed(
      picture: ZonePicture(
        height: outer.maxY + Theme.Layout.editorPrThreadBottom, elements: ground + elements,
        texts: texts),
      links: links)
  }
}
