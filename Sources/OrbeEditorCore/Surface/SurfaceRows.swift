import Foundation

/// 面の縦の並びに、文書の行と行の間へ差し込むもの（→ `TextSurface.setRows`）と、文書の行の見え方。差し込みは行に数えない
/// 描画で、本文にも undo にも載らない——行番号・選択・編集は、文書の行だけを見る（見えている範囲は縦の並びの中の位置で
/// 表す。→ `TextViewport`）。
public struct SurfaceRows {
  /// 境の昇順の差し込みの列。同じ境の差し込みは、列の順に上から並ぶ。
  public var insertions: [RowInsertion]
  /// 文書の行の区間の見え方（始まりの行の昇順）。最初の区間より上の行は、型も「もう一方の番号」も持たない。
  public var spans: [LineSpan]
  /// 差し込んだ行が指す行の出どころ（行を指す差し込んだ行が無ければ nil でよい）。
  public var source: (any SurfaceRowSource)?
  /// 行の頭の印の知らせを受けるもの（面は弱く持つ。並びを置き直せば、置き直した並びの受け手だけが受ける）。
  public var leadingMarkTarget: (any SurfaceLeadingMarkTarget)?

  public init(
    insertions: [RowInsertion] = [], spans: [LineSpan] = [], source: (any SurfaceRowSource)? = nil,
    leadingMarkTarget: (any SurfaceLeadingMarkTarget)? = nil
  ) {
    self.insertions = insertions
    self.spans = spans
    self.source = source
    self.leadingMarkTarget = leadingMarkTarget
  }
}

/// 行の頭の印（→ `SurfacePresentation.leadingMark`）の知らせを受けるもの。
@MainActor
public protocol SurfaceLeadingMarkTarget: AnyObject {
  /// 印を押して離した——並びの順で最初の行 `first` から最後の行 `last` まで（押して離しただけなら、2 つは同じ行。引いた
  /// なら、押した行と、最後にポインタの下に在った同じ組の行）。離した所が印の外でも知らせる。引いている間に並びを置き
  /// 直されたら、知らせない。
  func surface(
    _ surface: any TextSurface, didMarkFrom first: LeadingMarkLine, to last: LeadingMarkLine)
}

/// 印の行——文書の行か、差し込んだ行が指す出どころの行（どちらも 0 始まり）。
public enum LeadingMarkLine: Equatable, Sendable {
  case document(Int)
  case source(Int)
}

/// 差し込んだ行の出どころ——差し込んだ行が指す行の本文と役割の写しを持つもの（diff の古い側の版）。面は並びを置いたときと、
/// 出どころの役割が変わったと知らされたとき（`TextSurface.rowSourceRolesDidChange`）に写しを引いて描く。写しの本文は
/// 並びを置いてから置き直すまで変わらない（変わるなら、新しい出どころで並びを置き直す）。
@MainActor
public protocol SurfaceRowSource: AnyObject {
  var rowSourceContent: SurfaceContent { get }
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
  /// 区間の行の、行の頭の印の組（nil なら印を出さない）。引いて作る範囲は、同じ組の行の中に収まる。
  public var markGroup: Int?
  /// 行の上書き（`SurfacePresentation.lineOverrides` の番号。nil なら上書きなし）。
  public var override: Int?

  public init(
    line: Int, style: Int? = nil, otherNumber: Int? = nil, markGroup: Int? = nil,
    override: Int? = nil
  ) {
    self.line = line
    self.style = style
    self.otherNumber = otherNumber
    self.markGroup = markGroup
    self.override = override
  }
}

/// 文書の行の境 1 つに置く差し込みの塊。
public struct RowInsertion: Equatable {
  /// 境——文書の行 `line`−1 の後（行 `line` の前。0 は先頭、行数なら最終行の後）。置く時点の文書の写しの行で書く（行の
  /// 印と同じ規約）。
  public var line: Int
  public var content: Content

  public enum Content: Equatable {
    /// 文書に無い行の列。面が出どころの行を本文と同じ字・出どころの役割の色・空白の点で描くが、選べず、写せず、当たらない。
    case lines([InsertedLine])
    /// 絵の差し込み。面は本文の区画の幅を渡して絵を問い、返った高さで並べ、本文と同じコマに描く（→ `SurfaceZone`）。
    case zone(SurfaceZone)
    /// スクロールを共にする相手の面（→ `TextSurface.shareScroll`）に置いた絵の差し込みと同じ高さの空き（並列の diff の、
    /// スレッドの反対側）。高さは面が相手の絵の高さから解き、相手の絵の高さが変わった取引の中で揃える。相手が無い間と、
    /// 相手の面にその絵の差し込みが無い間は高さ 0。文書の行でも絵でもなく、何も描かず、選べず、当たらない。
    case gap(SurfaceZone)

    public static func == (lhs: Content, rhs: Content) -> Bool {
      switch (lhs, rhs) {
      case (.lines(let a), .lines(let b)): a == b
      case (.zone(let a), .zone(let b)): a === b
      case (.gap(let a), .gap(let b)): a === b
      default: false
      }
    }
  }

  public init(line: Int, content: Content) {
    self.line = line
    self.content = content
  }
}

/// 文書に無い行 1 つ——出どころ（`SurfaceRows.source`）の行を指すか、何も指さない（字の無い詰め物）。2 列の面では、出どころの
/// 行を指す行の左の列に、その行の番号（1 始まり）を描く。
public struct InsertedLine: Equatable, Sendable {
  /// 指す出どころの行（0 始まり。nil なら何も指さない）。
  public var line: Int?
  /// 行の型（`SurfacePresentation.lineStyles` の番号。nil なら型なし）。
  public var style: Int?
  /// 行の頭の印の組（nil なら印を出さない。出どころの行を指す行だけが出せる）。
  public var markGroup: Int?
  /// 行の上書き（`SurfacePresentation.lineOverrides` の番号。nil なら上書きなし）。
  public var override: Int?

  public init(line: Int? = nil, style: Int? = nil, markGroup: Int? = nil, override: Int? = nil) {
    self.line = line
    self.style = style
    self.markGroup = markGroup
    self.override = override
  }
}
