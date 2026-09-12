/// capture 名 → 役割の正規化表。dotted 名の最長一致（`keyword.conditional.ternary` は
/// `keyword.conditional` に当たる）。表に無い名前は plain（nil）。
///
/// 見本の 8 色に対し 16 文法の highlights.scm が使う名前を割り当てる。数値・定数・ラベル・
/// マークアップの強調は plain＝素の文字色で、見本に無い色を増やさない。
public enum CaptureRoleMap {
  public static func role(for captureName: String) -> SyntaxRole? {
    var components = captureName.split(separator: ".").map(String.init)
    while !components.isEmpty {
      if let role = table[components.joined(separator: ".")] { return role }
      components.removeLast()
    }
    return nil
  }

  private static let table: [String: SyntaxRole?] = [
    // 制御の流れ
    "keyword.control": .keywordControl,
    "keyword.return": .keywordControl,
    "keyword.conditional": .keywordControl,
    "keyword.repeat": .keywordControl,
    "keyword.import": .keywordControl,
    "keyword.include": .keywordControl,
    "keyword.exception": .keywordControl,
    "keyword.coroutine": .keywordControl,
    "conditional": .keywordControl,
    "repeat": .keywordControl,
    "include": .keywordControl,
    "exception": .keywordControl,
    // それ以外のキーワード
    "keyword": .keyword,
    "storage": .keyword,
    "constant.builtin": .keyword,
    "boolean": .keyword,
    "attribute": .keyword,
    "tag": .keyword,
    "tag.attribute": .variable,
    "markup.heading": .keyword,
    "text.title": .keyword,
    // CSS の at-rule
    "supports": .keyword,
    "media": .keyword,
    "keyframes": .keyword,
    "import": .keyword,
    "charset": .keyword,
    // 型
    "type": .type,
    "constructor": .type,
    "namespace": .type,
    "module": .type,
    // 関数
    "function": .function,
    "method": .function,
    // 文字列
    "string": .string,
    "escape": .string,
    "character": .string,
    "markup.raw": .string,
    "text.literal": .string,
    // コメント
    "comment": .comment,
    // 変数
    "variable": .variable,
    "parameter": .variable,
    "property": .variable,
    "field": .variable,
    "markup.link": .variable,
    "text.uri": .variable,
    "text.reference": .variable,
    // 記号
    "punctuation": .punctuation,
    "operator": .punctuation,
    "delimiter": .punctuation,
    "markup.list": .punctuation,
  ]
}
