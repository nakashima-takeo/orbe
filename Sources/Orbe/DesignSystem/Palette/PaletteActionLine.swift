import SwiftUI

/// 「このキーで何が起きるか」を言う 1 行。言語ごとの語順をテンプレート（`%1$@`…の位置指定）が持ち、
/// 差し込む値だけを色分けして 1 つの Text に連結する（単位で truncate し、狭幅で個々に折り返して崩れない）。
/// 先頭のキーと地の語は muted、強調の値は textPrimary、accent の値は accent。
struct PaletteActionLine: View {
  enum Slot {
    case emphasis(String)
    case accent(String)
  }

  /// 先頭に置くキー（`↵`・`space` など）。nil は置かない。
  let key: String?
  let template: String
  let slots: [Slot]
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    Self.segments(template, count: slots.count).reduce(
      Text(key.map { $0 + " " } ?? "").foregroundStyle(Color.theme.textMuted)
    ) { line, segment in
      switch segment {
      case .literal(let text):
        line + Text(text).foregroundStyle(Color.theme.textMuted)
      case .slot(let index):
        line + text(for: slots[index])
      }
    }
    .font(Font.theme.meta)
    .lineLimit(1)
    .truncationMode(.tail)
  }

  private func text(for slot: Slot) -> Text {
    switch slot {
    case .emphasis(let value):
      fontResolver.text(value, base: Theme.Typography.meta).foregroundStyle(Color.theme.textPrimary)
    case .accent(let value):
      Text(value).foregroundStyle(Color.theme.accentPrimary)
    }
  }

  enum Segment: Equatable {
    case literal(String)
    case slot(Int)
  }

  /// `%N$@` を差し込み位置（0 始まり）に、それ以外を地の語に分ける。範囲外の位置は地の語のまま残す。
  static func segments(_ template: String, count: Int) -> [Segment] {
    var segments: [Segment] = []
    var rest = Substring(template)
    while let match = rest.firstMatch(of: #/%(\d)\$@/#) {
      let index = Int(match.output.1)! - 1
      let before = String(rest[..<match.range.lowerBound])
      if !before.isEmpty { segments.append(.literal(before)) }
      segments.append(
        (0..<count).contains(index) ? .slot(index) : .literal(String(rest[match.range])))
      rest = rest[match.range.upperBound...]
    }
    if !rest.isEmpty { segments.append(.literal(String(rest))) }
    return segments
  }
}
