/// 色付けの意味ラベル。capture 名（文法ごとに揺れる）をこの 8 つへ正規化し、色はこの役割にだけ付く。
/// 役割を持たない文字（plain）は区間を持たず、面の素の文字色で描かれる。
public enum SyntaxRole: CaseIterable, Hashable, Sendable {
  case keyword
  case keywordControl
  case type
  case function
  case string
  case comment
  case variable
  case punctuation
}
