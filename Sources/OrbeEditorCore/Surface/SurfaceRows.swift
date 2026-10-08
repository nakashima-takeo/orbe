import Foundation

/// 面の縦の並びに、文書の行と行の間へ差し込むもの（→ `TextSurface.setRows`）と、文書の行の見え方。差し込みは行に数えない
/// 描画で、本文にも undo にも載らない——行番号・見えている範囲・選択・編集は、文書の行だけを見る。
public struct SurfaceRows: Equatable {
  /// 境の昇順の差し込みの列。同じ境の差し込みは、列の順に上から並ぶ。
  public var insertions: [RowInsertion]
  /// 文書の行の区間の見え方（始まりの行の昇順）。最初の区間より上の行は、型も「もう一方の番号」も持たない。
  public var spans: [LineSpan]

  public init(insertions: [RowInsertion] = [], spans: [LineSpan] = []) {
    self.insertions = insertions
    self.spans = spans
  }
}

/// 文書の行の区間 1 つの見え方——行 `line` から次の区間の始まりの前まで（最後の区間は最終行まで）。区間の始まりは差し込みの
/// 境と同じ規則で、面自身の編集で上の行に付いて動く。
public struct LineSpan: Equatable, Sendable {
  /// 区間の始まりの行。置く時点の文書の写しの行で書く。
  public var line: Int
  /// 行の型（`SurfacePresentation.lineStyles` の番号。nil なら型なし）。
  public var style: Int?
  /// 区間の始まりの行の「もう一方の番号」（2 列の面の左の列。区間の中の行 r は `otherNumber + (r − line)`。nil なら描かない）。
  public var otherNumber: Int?

  public init(line: Int, style: Int? = nil, otherNumber: Int? = nil) {
    self.line = line
    self.style = style
    self.otherNumber = otherNumber
  }
}

/// 文書の行の境 1 つに置く差し込みの塊。
public struct RowInsertion: Equatable {
  /// 境——文書の行 `line`−1 の後（行 `line` の前。0 は先頭、行数なら最終行の後）。置く時点の文書の写しの行で書く（行の
  /// 印と同じ規約）。
  public var line: Int
  public var content: Content

  public enum Content: Equatable {
    /// 文書に無い行の列。面が本文と同じ字で描くが、選べず、写せず、当たらない。
    case lines([InsertedLine])
    /// 区画。面が本文の区画の幅で区画の絵を問い、絵の高さで並べ、本文と同じコマに描く（→ `SurfaceZone`）。
    case zone(SurfaceZone)

    public static func == (lhs: Content, rhs: Content) -> Bool {
      switch (lhs, rhs) {
      case (.lines(let a), .lines(let b)): a == b
      case (.zone(let a), .zone(let b)): a === b
      default: false
      }
    }
  }

  public init(line: Int, content: Content) {
    self.line = line
    self.content = content
  }
}

/// 文書に無い行 1 つ。
public struct InsertedLine: Equatable, Sendable {
  /// 行の中身（改行を含まない）。
  public var text: String
  /// 行の型（`SurfacePresentation.lineStyles` の番号。nil なら型なし）。
  public var style: Int?
  /// 2 列の面の左の列に描く番号（nil なら描かない）。
  public var number: Int?

  public init(_ text: String, style: Int? = nil, number: Int? = nil) {
    self.text = text
    self.style = style
    self.number = number
  }
}
