import AppKit
import OrbeEditorCore
import cmark_gfm
import cmark_gfm_extensions

/// コメントの本文の段 1 つ——段落・見出し・箇条書きの項目の段・引用の中の段は字の段、コードブロックはコードの段。どの
/// スレッドへも渡せる値。
struct PrCommentBlock: Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    case text
    case code
  }

  /// 引用の線——x（本文の左端から）と、どの引用のものか（同じ引用の続く段の間で線を繋ぐ）。
  struct QuoteBar: Sendable, Equatable {
    let x: CGFloat
    let quote: Int
  }

  /// 箇条書きの印——字と、字の左端の x（本文の左端から）。
  struct Marker: Sendable, Equatable {
    let text: String
    let x: CGFloat
  }

  var kind: Kind
  /// 本文の左端からの字下げ（pt）。箇条書きの段と引用の段ごとに深くなる。
  var indent: CGFloat
  /// 引用の線（外側の引用から順に）。
  var quoteBars: [QuoteBar]
  /// 箇条書きの印（項目の最初の段だけ。最初の子が箇条書きの項目なら、外側と内側の印を 1 行に並べる）。
  var markers: [Marker]
  var text: ZoneStyledText
  /// 見え方の番号 → リンクの行き先。
  var links: [Int: URL]
  /// 取り消し線を引く見え方の番号。
  var strikes: Set<Int>
}

/// コメントの本文（GitHub の Markdown）を段の列に変換する（純関数。どのスレッドからも呼べる）。描くのは段落・インライン
/// コード・太字・斜体・取り消し線・リンク（本文に直接書いた http(s) の URL を含む）・コードブロック・箇条書き・引用・見出し
/// までで、ほかの記法（表・画像・HTML・suggestion・脚注など）は書かれた字のまま段落かインラインの字にする——字は欠けない。
///
/// 解析は cmark-gfm（GitHub と同じ表・取り消し線・タスクの拡張。smart punctuation は付けない）で、木は cmark の走査で平らに
/// たどる——仕事も stack の深さも、入れ子の深さに依らない（深い引用の本文 1 つでスレッドの stack が溢れない）。字下げは
/// 入れ子 `maxDepth` 段までで、それより深い段はその段と同じ字下げで出す。
enum PrCommentMarkdown {
  /// 字下げする入れ子（引用と箇条書き）の段の数の上限。
  static let maxDepth = 8

  static func blocks(_ source: String) -> [PrCommentBlock] {
    cmark_gfm_core_extensions_ensure_registered()
    // 脚注を脚注として読む（読まないと、脚注の定義の行を参照の定義として取り込み、字が出ない）。描くのは書かれた字のまま。
    guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT | CMARK_OPT_FOOTNOTES) else { return [] }
    defer { cmark_parser_free(parser) }
    for name in ["table", "strikethrough", "tasklist"] {
      if let syntax = cmark_find_syntax_extension(name) {
        cmark_parser_attach_syntax_extension(parser, syntax)
      }
    }
    source.utf8CString.withUnsafeBufferPointer { buffer in
      cmark_parser_feed(parser, buffer.baseAddress, buffer.count - 1)
    }
    guard let document = cmark_parser_finish(parser) else { return [] }
    defer { cmark_node_free(document) }
    var converter = Converter(source: source)
    converter.walk(document)
    return converter.blocks
  }
}
