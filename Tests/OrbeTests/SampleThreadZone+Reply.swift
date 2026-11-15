import AppKit
import OrbeEditorCore

extension SampleThreadZone {
  /// 返信の行——入力欄（枠 tint(accent, 0.55)・地 sunk(0.35)。行の数だけ高くなる）と、押せる「レビューに追加」
  /// 「解決して返信」。高さを返す。
  func reply(_ frame: CGRect, top: CGFloat, into canvas: inout Canvas) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    let plain = NSFont.systemFont(ofSize: 11.5)
    let lineHeight = field.style.lineHeight
    let height = 26 + CGFloat(field.lineCount - 1) * lineHeight
    var right = frame.maxX - 12
    let buttons: [(AnyHashable, NSFont)] = [(Self.resolveReply, plain), (Self.add, font)]
    for (id, buttonFont) in buttons {
      let label = Self.label(of: id)
      let width = Self.width(label, buttonFont) + 20
      right -= width
      let box = CGRect(x: right, y: top, width: width, height: 26)
      let baseline = Self.baseline(top: top, height: 26, font: buttonFont)
      if id == Self.add {
        canvas.elements.append(.box(ZoneBox(frame: box, radius: 4, fill: Self.accent)))
        canvas.text(
          label, font: buttonFont, color: Self.tabActiveText, x: right + 10, baseline: baseline)
      } else {
        canvas.elements.append(
          .box(
            ZoneBox(
              frame: box, radius: 4, fill: hovered == id ? Self.fill(0.06) : nil,
              stroke: .init(color: Self.hairline(0.12), width: 1))))
        canvas.text(label, font: buttonFont, color: Self.text2, x: right + 10, baseline: baseline)
      }
      canvas.elements.append(.button(ZoneButton(id: id, frame: box)))
      right -= 8
    }
    let input = CGRect(x: frame.minX + 12, y: top, width: right - (frame.minX + 12), height: height)
    canvas.elements.append(
      .box(
        ZoneBox(
          frame: input, radius: 4, fill: Self.sunk(0.35),
          stroke: .init(color: Self.tint(Self.accent, 0.55), width: 1))))
    let text = CGRect(
      x: input.minX + 9, y: input.minY + (26 - lineHeight) / 2, width: input.width - 18,
      height: CGFloat(field.lineCount) * lineHeight)
    if field.string.isEmpty {
      canvas.text(
        "返信…", font: field.style.font, color: Self.tertiary, x: text.minX,
        baseline: Self.baseline(top: text.minY, height: lineHeight, font: field.style.font))
    }
    canvas.elements.append(.field(ZoneField(frame: text, field: field)))
    return height
  }
}
