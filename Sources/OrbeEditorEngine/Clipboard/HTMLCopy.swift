import Foundation
import OrbeEditorCore

/// 色付きで写す HTML（VS Code の `copyWithSyntaxHighlighting` と同じ形）——外の div に地の色・本文の色・フォント・大きさ・
/// 行高・`white-space: pre`、行ごとの div（空の行は `<br>`）、役割ごとの span。メモやメールへ色付きで貼れる。
enum HTMLCopy {
  /// 写すときの見え方（色は `#rrggbb`）。
  struct Style {
    var text: String
    var background: String
    var roles: [SyntaxRole: String]
    /// CSS の `font-family` の値。
    var fontFamily: String
    var fontSize: CGFloat
    var lineHeight: CGFloat
  }

  /// 書き出す上限（UTF-16 の単位。VS Code と同じ 64KB 未満）。
  static let limit = 65_536

  /// `range` の HTML。長すぎるか、範囲に役割が無ければ nil。
  static func html(_ text: TextRope, _ range: NSRange, roles: RoleRuns, style: Style) -> String? {
    guard range.length > 0, range.length < limit else { return nil }
    let spans = roles.roles(in: range)
    guard !spans.isEmpty else { return nil }
    let size = Self.number(style.fontSize)
    var html =
      "<div style=\"color: \(style.text);background-color: \(style.background);"
      + "font-family: \(escape(style.fontFamily));font-weight: normal;"
      + "font-size: \(size)px;line-height: \(Self.number(style.lineHeight))px;white-space: pre;\">"
    var cursor = RoleCursor(spans: spans)
    let rows = text.rows(of: range)
    for row in rows {
      let content = text.contentRange(ofRow: row)
      let start = max(content.location, range.location)
      let end = min(NSMaxRange(content), NSMaxRange(range))
      guard start < end else {
        html += "<br>"
        continue
      }
      html += "<div>"
      var runStart = start
      var runRole = cursor.role(at: start)
      for offset in (start + 1)..<(end + 1) {
        let role = offset < end ? cursor.role(at: offset) : nil
        guard offset == end || role != runRole else { continue }
        let color = runRole.flatMap { style.roles[$0] } ?? style.text
        let piece = text.substring(NSRange(location: runStart, length: offset - runStart))
        html += "<span style=\"color: \(color);\">\(escape(piece))</span>"
        runStart = offset
        runRole = role
      }
      html += "</div>"
    }
    return html + "</div>"
  }

  private static func escape(_ string: String) -> String {
    string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }

  private static func number(_ value: CGFloat) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.1f", Double(value))
  }
}
