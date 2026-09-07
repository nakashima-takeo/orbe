import SwiftUI

/// タブ行の幅計算とセグメント幾何（純関数・単体テスト可能）。寸法は `Chrome` と `DSSegmentBar.width`。
enum StatusTabLayout {
  /// 全タブ単独の連（テスト・ギャラリー用 `TabStrip.init(titles:...)` の既定）。
  static func singletons(count: Int) -> [Range<Int>] {
    (0..<count).map { $0..<($0 + 1) }
  }

  /// 連がグループ＝2 枚以上か。識別色の地・外側 1px 枠・識別バー・区切り線と room・x 積算が
  /// 共有する唯一の述語。
  static func isGroup(_ range: Range<Int>) -> Bool { range.count >= 2 }

  /// shrink-to-fit の幅計算。自然幅を床 40〜上限 140 に収め（数文字の短い名前でも 40 の幅を持つ）、
  /// 合計が room に収まればそのまま、溢れれば**その幅に比例して縮め、床に達したセルは凍結して
  /// 残りの不足を残りのセルへ再配分**する。
  /// 再配分の単位は**行**であって連ではない——連は識別バー・区切り線・角丸を持つ視覚の単位で、幅の
  /// 取り分は持たない。同じ長さのタブは、どの連にいても、単独でも同じ幅になる（溢れたら全タブが
  /// 等しく縮む、という見本の規則）。
  /// room は available からセグメント間の隙間・＋ボタン・2 枚以上の連の識別バー幅を引いた値
  /// （バー幅は器の床に含む）。全タブが床でも溢れる時だけ合計が room を超え横スクロールへ。
  /// `naturals` と同じ要素数を返す。
  static func widths(naturals: [CGFloat], segments: [Range<Int>], available: CGFloat) -> [CGFloat] {
    let capped = naturals.map { min(max($0, Chrome.tabMinWidth), Chrome.tabMaxWidth) }
    guard !capped.isEmpty else { return [] }
    let gaps = Chrome.tabGap * CGFloat(segments.count)  // 要素は n 連 + ＋ボタンで計 n+1、その間の隙間は n 個
    let bars = DSSegmentBar.width * CGFloat(segments.filter(isGroup).count)
    let room = available - gaps - Chrome.tabHeight - bars  // ＋ボタンは tabHeight 角
    if capped.reduce(0, +) <= room { return capped }

    var result = capped
    var frozen = [Bool](repeating: false, count: capped.count)
    while true {
      let flexTotal = zip(capped, frozen).filter { !$0.1 }.map(\.0).reduce(0, +)
      let frozenTotal = zip(result, frozen).filter { $0.1 }.map(\.0).reduce(0, +)
      let target = room - frozenTotal
      guard flexTotal > 0 else { break }
      let scale = target / flexTotal
      var changed = false
      for i in result.indices where !frozen[i] {
        let w = capped[i] * scale
        if w < Chrome.tabMinWidth {
          result[i] = Chrome.tabMinWidth
          frozen[i] = true
          changed = true
        } else {
          result[i] = w
        }
      }
      if !changed { break }
    }
    return result
  }

  /// セル 1 枚の x 範囲。
  struct CellFrame {
    let x: CGFloat
    let width: CGFloat
    var midX: CGFloat { x + width / 2 }
    var maxX: CGFloat { x + width }
  }

  /// セグメント 1 本の x 範囲（バーを含む）。
  struct SegmentFrame {
    let range: Range<Int>
    let x: CGFloat
    let width: CGFloat
    /// 2 枚以上の連＝グループ（左端に識別バーを持つ）。
    let isGroup: Bool
    var midX: CGFloat { x + width / 2 }
    var maxX: CGFloat { x + width }
  }

  /// 行内の x 配置（scroll offset に依らない同一レイアウト空間の相対量）。
  struct Geometry {
    let cells: [CellFrame]
    let segments: [SegmentFrame]
    /// 最後のセグメントの右端。
    var rowEnd: CGFloat { segments.last?.maxX ?? 0 }
    /// セル `i` を含むセグメント。cells と segments は同じ連から組むので必ず 1 つある。
    func segment(containing i: Int) -> SegmentFrame {
      guard let seg = segments.first(where: { $0.range.contains(i) }) else {
        preconditionFailure("cell \(i) belongs to no segment")
      }
      return seg
    }
    /// タブ総数（＝末尾への挿入 index）。
    var count: Int { cells.count }
  }

  /// x 積算: セグメント x0 → (グループなら +バー幅) → セルを隙間なし → セグメント幅 = バー + Σセル
  /// → 次は +tabGap。
  static func geometry(widths: [CGFloat], segments: [Range<Int>]) -> Geometry {
    var cells: [CellFrame] = []
    var segs: [SegmentFrame] = []
    var x: CGFloat = 0
    for r in segments {
      let group = isGroup(r)
      let x0 = x
      if group { x += DSSegmentBar.width }
      for i in r {
        let w = widths.indices.contains(i) ? widths[i] : 0
        cells.append(CellFrame(x: x, width: w))
        x += w
      }
      segs.append(SegmentFrame(range: r, x: x0, width: x - x0, isGroup: group))
      x += Chrome.tabGap
    }
    return Geometry(cells: cells, segments: segs)
  }
}
