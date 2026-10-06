import Foundation

/// 面の縦の並びに、文書の行と行の間へ差し込むもの（→ `TextSurface.setRows`）。差し込みは行に数えない描画で、本文にも
/// undo にも載らない——行番号・見えている範囲・選択・編集は、文書の行だけを見る。
public struct SurfaceRows: Equatable {
  /// 境の昇順の差し込みの列。同じ境の差し込みは、列の順に上から並ぶ。
  public var insertions: [RowInsertion]

  public init(insertions: [RowInsertion] = []) {
    self.insertions = insertions
  }
}

/// 文書の行の境 1 つに置く差し込みの塊。
public struct RowInsertion: Equatable {
  /// 境——文書の行 `line` の前（行数なら最終行の後）。載せる側は、面が最後に引いた写しの行で書く（行の印と同じ規約）。
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

  public init(_ text: String) {
    self.text = text
  }
}
