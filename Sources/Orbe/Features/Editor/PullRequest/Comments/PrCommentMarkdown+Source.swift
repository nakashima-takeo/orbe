import AppKit
import OrbeEditorCore
import cmark_gfm

/// cmark の節の値と、節の範囲の書かれた字（→ `PrCommentMarkdown.Converter`）。
extension PrCommentMarkdown {
  /// 段の記法の範囲の、書かれた字（行ごとに、入れ物の前置き——引用の `>` と字下げ——を外す。末尾の空白だけの行は含めない
  /// ——入れ物の終わりの行は、後ろに続く空行を含む）。
  static func writtenText(of node: Node, utf8: [UInt8], lineStarts: [Int]) -> String {
    let start = Int(cmark_node_get_start_line(node))
    let last = Int(cmark_node_get_end_line(node))
    let column = Int(cmark_node_get_start_column(node))
    // 空行なしで段落に続く表は、表の拡張が段落の型だけを替えるので、始まりの行が段落の 1 行目のまま。表の始まりは、終わりの
    // 行から行の子（頭の行と本体の行。区切りの行は子でない）の数だけ戻った行。
    var first = start
    if typeName(node) == "table" {
      var rows = 0
      var child = cmark_node_first_child(node)
      while let row = child {
        rows += 1
        child = cmark_node_next(row)
      }
      first = max(start, last - rows)
    }
    guard first >= 1, last >= first, last <= lineStarts.count else { return "" }
    var lines: [String] = []
    for line in first...last {
      let lineStart = lineStarts[line - 1]
      let end = line < lineStarts.count ? lineStarts[line] - 1 : utf8.count
      var from = lineStart
      if line == start {
        // 段の始まりの行は、始まりの桁から（項目の印・引用の `>` を含む前置きを外す）。
        from = min(end, lineStart + column - 1)
      } else {
        // 続きの行の前置きは、始まりの桁の前の空白と `>` だけ。
        while from < min(end, lineStart + column - 1), [0x20, 0x09, 0x3E].contains(utf8[from]) {
          from += 1
        }
      }
      lines.append(String(bytes: utf8[from..<max(from, end)], encoding: .utf8) ?? "")
    }
    while lines.count > 1, let tail = lines.last, tail.allSatisfy({ $0 == " " || $0 == "\t" }) {
      lines.removeLast()
    }
    return lines.joined(separator: "\n")
  }

  // MARK: - cmark の値

  static func typeName(_ node: Node) -> String {
    string(cmark_node_get_type_string(node))
  }

  static func literal(_ node: Node) -> String {
    string(cmark_node_get_literal(node))
  }

  static func string(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
  }

  /// リンクの行き先。web とメールの URL だけを押せるリンクにする（ほかは字のまま——第三者の書いた本文から、手元の
  /// アプリやファイルを開かせない。判定はファイルシステムを調べない）。
  static func allowed(_ destination: String) -> URL? {
    UntrustedLink(destination, localHosts: []).webURL
  }

  static func style(_ font: NSFont, _ color: NSColor) -> ZoneTextStyle {
    ZoneTextStyle(font: font, color: color)
  }

  /// システムの字体の斜体（本物の斜体の字体。和文は直立のまま）。
  static func italic(_ font: NSFont) -> NSFont {
    CTFontCreateCopyWithSymbolicTraits(font as CTFont, 0, nil, .traitItalic, .traitItalic)
      .map { $0 as NSFont } ?? font
  }
}
