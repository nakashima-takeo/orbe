import Markdown
import SwiftUI

/// インライン markup の見た目。コードスパンだけが地の本文と違う描かれ方をするので、
/// 持つのはその 2 値（等幅フォントと背景）に限る。
struct MarkdownInlineStyle {
  var inlineCodeFont: Font = Font.theme.code
  var inlineCodeBackground: Color = Color.theme.bgSunken
}

/// インライン markup（強調・コードスパン・リンク・取り消し線）を `AttributedString` へ畳む。
enum MarkdownInline {
  /// インラインコンテナ（段落・見出し）の中身を `AttributedString` へ畳む。
  static func attributed(
    of container: Markup, style: MarkdownInlineStyle = MarkdownInlineStyle()
  ) -> AttributedString {
    var result = AttributedString()
    for child in container.children { result += render(child, style: style) }
    return result
  }

  // MARK: - 再帰

  private static func render(_ markup: Markup, style: MarkdownInlineStyle) -> AttributedString {
    switch markup {
    case let text as Markdown.Text:
      return AttributedString(text.string)
    case let code as InlineCode:
      var s = AttributedString(code.code)
      s.font = style.inlineCodeFont
      s.backgroundColor = style.inlineCodeBackground
      return s
    case let emphasis as Emphasis:
      return apply(attributed(of: emphasis, style: style), intent: .emphasized)
    case let strong as Strong:
      return apply(attributed(of: strong, style: style), intent: .stronglyEmphasized)
    case let strike as Strikethrough:
      var s = attributed(of: strike, style: style)
      for run in s.runs { s[run.range].strikethroughStyle = .single }
      return s
    case let link as Markdown.Link:
      var s = attributed(of: link, style: style)
      for run in s.runs {
        s[run.range].foregroundColor = Color.theme.accentPrimary
        s[run.range].underlineStyle = .single
      }
      return s
    case is SoftBreak:
      return AttributedString(" ")
    case is LineBreak:
      return AttributedString("\n")
    default:
      // Image / InlineHTML 等は素の plainText で落とさず描く。
      return AttributedString((markup as? InlineMarkup)?.plainText ?? markup.format())
    }
  }

  /// 子の attributed に強調 intent を重ねる（ネストした強調を潰さず union する）。
  private static func apply(_ attributed: AttributedString, intent: InlinePresentationIntent)
    -> AttributedString
  {
    var s = attributed
    for run in s.runs {
      let existing = s[run.range].inlinePresentationIntent ?? []
      s[run.range].inlinePresentationIntent = existing.union(intent)
    }
    return s
  }
}
