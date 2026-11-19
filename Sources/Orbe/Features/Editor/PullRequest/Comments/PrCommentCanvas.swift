import AppKit
import OrbeEditorCore

/// スレッドの絵の層を積む。描き直しのたびに組む要素（頭・メタの行・返信の行・失敗の文。座標は絵の差し込みの左上から）は
/// 本文の層の間ごとに 1 つの層にまとめ、コメントの本文は組んだ本文の層をそのまま置く——箱の重ね順（層の順）は要素を積んだ
/// 順のまま。
@MainActor
struct PrCommentCanvas {
  let state: PrCommentPicture.State
  /// 今の層に積んでいる要素。
  var elements: [ZoneElement] = []
  private var layers: [(origin: CGPoint, layer: ZoneLayer)] = []
  private var links: [String: [Int: URL]] = [:]

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

  /// コメント `comment` の組んだ本文の層を、左上 `origin` に置く（それまでに積んだ要素は 1 つの層にして閉じる）。
  mutating func place(_ body: PrCommentBody, comment: String, at origin: CGPoint) {
    close()
    layers.append((origin, body.layer))
    links[comment] = body.links
  }

  /// 積んでいる要素を 1 つの層にして閉じる。
  private mutating func close() {
    guard !elements.isEmpty else { return }
    layers.append((.zero, ZoneLayer(elements: elements)))
    elements = []
  }

  /// 箱（地・枠・影）と頭の帯（無ければ帯なし）を下に敷き、絵にする。`bottom` は箱の下端。
  mutating func finish(_ frame: CGRect, bottom: CGFloat, head: PrCommentPicture.Head?)
    -> PrCommentPicture.Composed
  {
    close()
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
        height: outer.maxY + Theme.Layout.editorPrThreadBottom,
        layers: [(.zero, ZoneLayer(elements: ground))] + layers),
      links: links)
  }
}
