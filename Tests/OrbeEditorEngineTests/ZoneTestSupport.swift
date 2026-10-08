import AppKit
import OrbeEditorCore

/// 高さの決まった区画——区画いっぱいの箱 1 つ（色 `color`）。
@MainActor
final class BoxZone: SurfaceZone {
  var height: CGFloat
  var color: NSColor
  private(set) var widths: [CGFloat] = []

  init(height: CGFloat, color: NSColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)) {
    self.height = height
    self.color = color
  }

  func picture(width: CGFloat) -> ZonePicture {
    widths.append(width)
    return ZonePicture(
      height: height,
      elements: [
        .box(ZoneBox(frame: CGRect(x: 0, y: 0, width: width, height: height), fill: color))
      ])
  }

  func zone(_ event: ZoneEvent) {}
}

/// スレッドの形の区画（テストと性能の場面の区画）——影と枠線の付いた角丸の枠・頭の帯と字・アバターの円と頭文字と画像・
/// 幅で折り返す選べる本文・押せる場所 2 つ・入力欄（`field` があれば。行の数だけ高くなる）。
/// 押せる場所はホバーで地の色を変え、押下を `events` に残す。
@MainActor
final class ThreadZone: SurfaceZone {
  static let bodyFont = NSFont.systemFont(ofSize: 12)
  static let headFont = NSFont.systemFont(ofSize: 11)
  static let ink = NSColor(srgbRed: 0.85, green: 0.85, blue: 0.9, alpha: 1)
  static let accent = NSColor(srgbRed: 0.55, green: 0.45, blue: 0.95, alpha: 1)
  static let glyph: NSImage = {
    let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
      ThreadZone.accent.setFill()
      NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
      return true
    }
    return image
  }()

  /// 本文の区画の外側の余白・枠の中の余白・本文の行の高さ。
  static let margin = CGSize(width: 40, height: 4)
  static let inset: CGFloat = 12
  static let lineHeight: CGFloat = 19

  var comment: String
  let field: ZoneTextField?
  /// 入力欄の行の数が変われば描き直させる面（載せた後に置く。打鍵ごとには描き直さない）。
  weak var surface: (any TextSurface)?
  private(set) var hovered: AnyHashable?
  private(set) var events: [ZoneEvent] = []
  /// 絵を問われた幅（問われた順）。
  private(set) var widths: [CGFloat] = []
  private var fieldLines = 0

  init(comment: String, field: ZoneTextField? = nil) {
    self.comment = comment
    self.field = field
    fieldLines = field?.lineCount ?? 0
    field?.didChange = { [weak self] field in
      guard let self, field.lineCount != self.fieldLines else { return }
      self.fieldLines = field.lineCount
      self.surface?.redrawZone(self)
    }
  }

  /// 本文の文のまとまりの id と、押せる場所の id。
  static let commentText: AnyHashable = "comment"
  static let resolve: AnyHashable = "resolve"
  static let collapse: AnyHashable = "collapse"

  func picture(width: CGFloat) -> ZonePicture {
    widths.append(width)
    let frame = CGRect(
      x: Self.margin.width, y: Self.margin.height,
      width: max(80, width - Self.margin.width - 16), height: 0)
    var body: [ZoneElement] = []
    let bottom = layOutComment(in: frame, into: &body)
    let height = bottom - frame.minY
    return ZonePicture(
      height: frame.minY + height + 8,
      elements: chrome(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: height))
        + body,
      texts: [ZoneText(id: Self.commentText, string: comment)])
  }

  /// 頭の帯の高さ。
  private static let head: CGFloat = 26

  /// 枠（影・枠線つき）と頭（帯・字・押せる場所 2 つ）。
  private func chrome(_ frame: CGRect) -> [ZoneElement] {
    var elements: [ZoneElement] = [
      .box(
        ZoneBox(
          frame: frame, radius: 6,
          fill: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.2, alpha: 0.85),
          stroke: .init(color: Self.accent.withAlphaComponent(0.35), width: 1),
          shadow: .init(color: NSColor(white: 0, alpha: 0.35), offset: 10, blur: 30))),
      .box(
        ZoneBox(
          frame: CGRect(
            x: frame.minX + 1, y: frame.minY + 1, width: frame.width - 2, height: Self.head),
          fill: Self.accent.withAlphaComponent(0.08))),
      .text(
        ZoneTextLine(
          origin: CGPoint(x: frame.minX + Self.inset, y: frame.minY + 17),
          runs: [ZoneTextRun("行 12 · 試し", font: Self.headFont, color: Self.ink)])),
    ]
    for (index, id) in [Self.resolve, Self.collapse].enumerated() {
      let button = CGRect(
        x: frame.maxX - Self.inset - CGFloat(2 - index) * 60, y: frame.minY + 4, width: 52,
        height: 18)
      let fill =
        hovered == id ? Self.accent.withAlphaComponent(0.3) : NSColor(white: 1, alpha: 0.06)
      elements += [
        .box(ZoneBox(frame: button, radius: 3, fill: fill)),
        .text(
          ZoneTextLine(
            origin: CGPoint(x: button.minX + 8, y: button.minY + 13),
            runs: [ZoneTextRun(index == 0 ? "解決" : "畳む", font: Self.headFont, color: Self.ink)])),
        .button(ZoneButton(id: id, frame: button)),
      ]
    }
    return elements
  }

  /// アバター（円・頭文字・画像）・折り返す本文・入力欄を積み、下端の y を返す。
  private func layOutComment(in frame: CGRect, into body: inout [ZoneElement]) -> CGFloat {
    let inner = frame.width - 2 * Self.inset
    var y = frame.minY + Self.head + 10
    body += [
      .box(
        ZoneBox(
          frame: CGRect(x: frame.minX + Self.inset, y: y, width: 20, height: 20), radius: 10,
          fill: NSColor(srgbRed: 0.3, green: 0.3, blue: 0.35, alpha: 1))),
      .text(
        ZoneTextLine(
          origin: CGPoint(x: frame.minX + Self.inset + 6, y: y + 14),
          runs: [ZoneTextRun("T", font: Self.headFont, color: Self.ink)])),
      .image(
        ZoneImage(
          frame: CGRect(x: frame.minX + Self.inset + 4, y: y + 24, width: 12, height: 12),
          image: Self.glyph)),
    ]
    let lines = ZoneTextLayout.lines(
      comment, styles: Self.styles(comment), width: max(10, inner - 30))
    for line in lines {
      body.append(
        .selectable(
          ZoneSelectableLine(
            origin: CGPoint(x: frame.minX + Self.inset + 30, y: y + 14), text: Self.commentText,
            range: line.range, styles: line.styles)))
      y += Self.lineHeight
    }
    y += 8
    guard let field else { return y }
    let box = CGRect(
      x: frame.minX + Self.inset, y: y, width: inner - 120,
      height: max(26, CGFloat(field.lineCount) * field.style.lineHeight + 8))
    body += [
      .box(
        ZoneBox(
          frame: box, radius: 4, fill: NSColor(white: 0, alpha: 0.35),
          stroke: .init(color: Self.accent.withAlphaComponent(0.55), width: 1))),
      .field(ZoneField(frame: box.insetBy(dx: 8, dy: 4), field: field)),
    ]
    return box.maxY + 10
  }

  func zone(_ event: ZoneEvent) {
    events.append(event)
    switch event {
    case .entered(let id): hovered = id
    case .exited(let id) where hovered == id: hovered = nil
    default: break
    }
  }

  /// 本文の見え方（全体を本文の字体で）。
  static func styles(_ string: String) -> [ZoneTextStyle] {
    [ZoneTextStyle(length: string.utf16.count, font: bodyFont, color: ink)]
  }

  /// 入力欄の見え方。
  static func fieldStyle() -> ZoneTextField.Style {
    ZoneTextField.Style(
      font: .systemFont(ofSize: 12), lineHeight: 18, textColor: ink, caretColor: .white,
      selectionColor: NSColor(srgbRed: 0.15, green: 0.31, blue: 0.47, alpha: 1),
      inactiveSelectionColor: NSColor(srgbRed: 0.23, green: 0.24, blue: 0.26, alpha: 1))
  }
}
