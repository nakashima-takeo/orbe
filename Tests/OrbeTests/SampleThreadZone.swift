import AppKit
import OrbeEditorCore

/// 試しのスレッドの区画——見本（orbe_design の `DiffView.tsx` の `Thread`。デザイン台帳 D 節）の構成を、区画の絵で組んだ
/// もの。差し込みの flow（`editor_rows`）と、画面に出す試しの場（`EditorRowsTrialTests`）が載せる。
///
/// 枠（半透明の地・枠線・影）・頭（行と話題・状態の点・押せる「解決」「折りたたむ」）・コメント（アバターの円と頭文字か
/// OrbeGlyph・名前と時刻と保留中の札・幅で折り返す本文とインラインコードの地・関連コミット）・返信の入力欄と 2 つの
/// ボタン。本文と関連コミットは選べる文。押せる場所はホバーで見た目を変え、押すと頭に「押した: …」を出す。入力欄は
/// 行の数か空 ↔ 空でないが変わったときだけ描き直させる（打鍵ごとには描き直さない）。
@MainActor
final class SampleThreadZone: SurfaceZone {
  struct Comment {
    var who: String
    var avatar: Avatar
    var when: String
    var pending: Bool
    var body: [Part]
    var commit: String?
  }

  enum Avatar {
    case initials(String)
    case orbe
  }

  enum Part {
    case text(String)
    case code(String)
  }

  let line: String
  let topic: String
  let status: String
  let comments: [Comment]
  let field: ZoneTextField
  /// 描き直させる面（載せた後に置く）。
  weak var surface: (any TextSurface)?
  private(set) var hovered: AnyHashable?
  private(set) var pressed: String?
  private var fieldShape: (lines: Int, empty: Bool)

  init(line: String, topic: String, status: String, comments: [Comment], reply: String, id: String)
  {
    self.line = line
    self.topic = topic
    self.status = status
    self.comments = comments
    field = ZoneTextField(id: id, text: reply, style: Self.fieldStyle)
    fieldShape = (field.lineCount, field.string.isEmpty)
    field.didChange = { [weak self] field in self?.fieldDidChange(field) }
  }

  /// 見本の展示データ（`editor/data.ts` の `thread`）。
  static func sample(line: Int, id: String) -> SampleThreadZone {
    SampleThreadZone(
      line: "行 \(line)", topic: "coalesce の判定", status: "保留中",
      comments: [
        Comment(
          who: "you", avatar: .initials("yo"), when: "今", pending: true,
          body: [
            .text("tail だけ見ると、間に別種のイベントが挟まったときに畳み損ねない？ "),
            .code("merges(event)"), .text(" の前に種別チェックが要る気がする。"),
          ]),
        Comment(
          who: "claude", avatar: .orbe, when: "agent · agent-hooks", pending: false,
          body: [
            .text("意図的に tail のみです。tail 以外を畳むとキュー順序が崩れます。挟まった場合は畳まず append する分岐を "),
            .code("merges"), .text(" 側に足し、テストを追加しました。"),
          ],
          commit: "c41d8aa · StateHooksTests: testCoalesceSkipsUnrelated"),
      ], reply: "了解。それなら OK", id: id)
  }

  // MARK: - 区画

  func zone(_ event: ZoneEvent) {
    switch event {
    case .entered(let id): hovered = id
    case .exited(let id) where hovered == id: hovered = nil
    case .pressed(let id): pressed = Self.label(of: id)
    default: return
    }
    redraw()
  }

  private func redraw() {
    surface?.redrawZone(self)
  }

  private func fieldDidChange(_ field: ZoneTextField) {
    let shape = (field.lineCount, field.string.isEmpty)
    guard shape != fieldShape else { return }
    fieldShape = shape
    redraw()
  }

  func picture(width: CGFloat) -> ZonePicture {
    var canvas = Canvas()
    let frame = CGRect(x: 0, y: 4, width: max(160, width - 16), height: 0)
    var y = frame.minY
    let head = header(frame, into: &canvas)
    y += head
    y += 10
    for (index, comment) in comments.enumerated() {
      y += self.comment(comment, index: index, top: y, frame: frame, into: &canvas)
      if index < comments.count - 1 { y += 12 }
    }
    y += 10
    y += reply(frame, top: y, into: &canvas)
    y += 10
    let outer = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: y - frame.minY)
    let background: [ZoneElement] = [
      .box(
        ZoneBox(
          frame: outer, radius: 6, fill: Self.panel(0.85),
          stroke: .init(color: Self.tint(Self.accent, 0.35), width: 1),
          shadow: .init(color: Self.shadow(0.35), offset: 10, blur: 30))),
      .box(
        ZoneBox(
          frame: CGRect(
            x: outer.minX + 1, y: outer.minY + 1, width: outer.width - 2, height: head - 1),
          radius: 5, fill: Self.tint(Self.accent, 0.08))),
      .box(
        ZoneBox(
          frame: CGRect(
            x: outer.minX + 1, y: outer.minY + head - 1, width: outer.width - 2, height: 1),
          fill: Self.hairline(0.08))),
    ]
    return ZonePicture(
      height: outer.maxY + 8, elements: background + canvas.elements, texts: canvas.texts)
  }

  /// 描く要素と選べる文を積む。
  struct Canvas {
    var elements: [ZoneElement] = []
    var texts: [ZoneText] = []

    mutating func text(
      _ string: String, font: NSFont, color: NSColor, x: CGFloat, baseline: CGFloat
    ) {
      elements.append(
        .text(
          ZoneTextLine(
            origin: CGPoint(x: x, y: baseline),
            runs: [ZoneTextRun(string, font: font, color: color)])))
    }
  }

  /// 頭（高さ 26）——左に行と話題、右に状態と押せる「解決」「折りたたむ」。高さを返す。
  private func header(_ frame: CGRect, into canvas: inout Canvas) -> CGFloat {
    let height: CGFloat = 26
    let font = NSFont.systemFont(ofSize: 11)
    let baseline = Self.baseline(top: frame.minY, height: height, font: font)
    var x = frame.minX + 12
    let parts =
      [(line, Self.text2), ("·", Self.muted), (topic, Self.muted)]
      + (pressed.map { [("押した: \($0)", Self.accentBright)] } ?? [])
    for (string, color) in parts {
      canvas.text(string, font: font, color: color, x: x, baseline: baseline)
      x += Self.width(string, font) + 8
    }
    var right = frame.maxX - 12
    for id in [Self.collapse, Self.resolve] {
      let label = Self.label(of: id)
      let width = Self.width(label, font)
      right -= width
      canvas.text(
        label, font: font, color: hovered == id ? Self.text2 : Self.muted, x: right,
        baseline: baseline)
      canvas.elements.append(
        .button(
          ZoneButton(
            id: id, frame: CGRect(x: right - 2, y: frame.minY, width: width + 4, height: height))))
      right -= 8
    }
    let mono = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    right -= Self.width(status, mono)
    canvas.text(status, font: mono, color: Self.modified, x: right, baseline: baseline)
    right -= 4 + 6
    canvas.elements.append(
      .box(
        ZoneBox(
          frame: CGRect(x: right, y: frame.minY + (height - 6) / 2, width: 6, height: 6), radius: 3,
          fill: Self.modified)))
    return height
  }

  /// コメント 1 件（アバター 20・名前の行・折り返す本文・関連コミット）。高さを返す。
  private func comment(
    _ comment: Comment, index: Int, top: CGFloat, frame: CGRect, into canvas: inout Canvas
  ) -> CGFloat {
    let avatar = CGRect(x: frame.minX + 12, y: top, width: 20, height: 20)
    switch comment.avatar {
    case .initials(let initials):
      canvas.elements.append(.box(ZoneBox(frame: avatar, radius: 10, fill: Self.ghost)))
      let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
      canvas.text(
        initials, font: font, color: Self.chromeText,
        x: avatar.midX - Self.width(initials, font) / 2,
        baseline: Self.baseline(top: avatar.minY, height: 20, font: font))
    case .orbe:
      canvas.elements.append(
        .box(ZoneBox(frame: avatar, radius: 10, fill: Self.tint(Self.accent, 0.16))))
      canvas.elements.append(
        .image(ZoneImage(frame: avatar.insetBy(dx: 4, dy: 4), image: Self.orbeGlyph)))
    }
    let left = avatar.maxX + 10
    let width = frame.maxX - 12 - left
    var y = top
    let small = NSFont.systemFont(ofSize: 11)
    let name = NSFont.systemFont(ofSize: 11, weight: .semibold)
    let headLine: CGFloat = 11 * 1.6
    let baseline = Self.baseline(top: y, height: headLine, font: small)
    var x = left
    canvas.text(comment.who, font: name, color: Self.chromeText, x: x, baseline: baseline)
    x += Self.width(comment.who, name) + 6
    canvas.text(comment.when, font: small, color: Self.tertiary, x: x, baseline: baseline)
    x += Self.width(comment.when, small) + 6
    if comment.pending {
      let badge = NSFont.systemFont(ofSize: 10)
      let badgeWidth = Self.width(status, badge) + 8 + 2
      canvas.elements.append(
        .box(
          ZoneBox(
            frame: CGRect(x: x, y: baseline - 11, width: badgeWidth, height: 15), radius: 3,
            stroke: .init(color: Self.tint(Self.modified, 0.4), width: 1))))
      canvas.text(status, font: badge, color: Self.modified, x: x + 5, baseline: baseline)
    }
    y += headLine
    y += body(
      comment.body, id: "body-\(index)", in: CGRect(x: left, y: y, width: width, height: 0),
      into: &canvas)
    if let commit = comment.commit {
      y += 4
      let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
      canvas.elements.append(
        .box(
          ZoneBox(
            frame: CGRect(x: left, y: y + (headLine - 7) / 2, width: 7, height: 7), radius: 3.5,
            fill: Self.accentBright)))
      let id = "commit-\(index)"
      canvas.texts.append(ZoneText(id: id, string: commit))
      canvas.elements.append(
        .selectable(
          ZoneSelectableLine(
            origin: CGPoint(x: left + 12, y: Self.baseline(top: y, height: headLine, font: mono)),
            text: id, range: NSRange(location: 0, length: commit.utf16.count),
            styles: [ZoneTextStyle(length: commit.utf16.count, font: mono, color: Self.muted)])))
      y += headLine
    }
    return max(20, y - top)
  }

  /// 本文（12px・行高 1.6・text2。インラインコードは等幅・accentBright・地 tint(accent, 0.12)）を幅で折り返して置く。
  /// 高さを返す。
  private func body(
    _ parts: [Part], id: String, in area: CGRect, into canvas: inout Canvas
  ) -> CGFloat {
    let (left, width, top) = (area.minX, area.width, area.minY)
    let sans = NSFont.systemFont(ofSize: 12)
    let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var string = ""
    var styles: [ZoneTextStyle] = []
    for part in parts {
      switch part {
      case .text(let text):
        string += text
        styles.append(ZoneTextStyle(length: text.utf16.count, font: sans, color: Self.text2))
      case .code(let code):
        string += code
        styles.append(ZoneTextStyle(length: code.utf16.count, font: mono, color: Self.accentBright))
      }
    }
    canvas.texts.append(ZoneText(id: id, string: string))
    let lineHeight: CGFloat = 12 * 1.6
    let lines = ZoneTextLayout.lines(string, styles: styles, width: width)
    let units = Array(string.utf16)
    for (index, line) in lines.enumerated() {
      let lineTop = top + CGFloat(index) * lineHeight
      let baseline = Self.baseline(top: lineTop, height: lineHeight, font: sans)
      var x = left
      var offset = line.range.location
      for style in line.styles {
        let piece = String(
          utf16CodeUnits: Array(units[offset..<offset + style.length]), count: style.length)
        let pieceWidth = Self.width(piece, style.font)
        if style.font == mono {
          canvas.elements.append(
            .box(
              ZoneBox(
                frame: CGRect(
                  x: x - 3, y: baseline - mono.ascender - 1, width: pieceWidth + 6,
                  height: mono.ascender - mono.descender + 2), radius: 3,
                fill: Self.tint(Self.accent, 0.12))))
        }
        x += pieceWidth
        offset += style.length
      }
      canvas.elements.append(
        .selectable(
          ZoneSelectableLine(
            origin: CGPoint(x: left, y: baseline), text: id, range: line.range,
            styles: line.styles)))
    }
    return CGFloat(lines.count) * lineHeight
  }
}
