/// 区間を見せる方針（VS Code の `revealRange*` と同じ考え方）。縦の着地は方針で決まり、横はどの方針でも区間が見える
/// ところまで最小限に寄せる。
public enum TextReveal: Equatable, Sendable {
  /// 区間の先頭の行を見えている高さの中央へ（見えていても送る）。
  case center
  /// 区間の先頭の行が縦に見えていなければ中央へ、見えていれば最小限。
  case centerIfOutside
  /// 区間が縦に見えていなければ上寄りに——見えている高さより高ければ先頭の行を上端へ、そうでなければ先頭の行を上から
  /// max(5 行, 高さの 20%) 下へ（区間の終わりが下へ押し出されない範囲で）。見えていれば動かさない。
  case nearTopIfOutside
  /// 区間が縦に見えるところまで最小限。
  case minimal

  /// 区間の行 `rows`（両端を含む）をこの方針で見せた後の先頭（行の単位の小数）。`first` は今の先頭、`visible` は見えて
  /// いる行の数（どちらも小数）。スクロールできる範囲には収めない（収めるのは呼び手）。
  public func firstLine(showing rows: ClosedRange<Int>, first: Double, visible: Double) -> Double {
    let top = Double(rows.lowerBound)
    let bottom = Double(rows.upperBound + 1)
    let centered = top + 0.5 - visible / 2
    func minimal(from first: Double) -> Double {
      if top < first || bottom - top > visible { return top }
      if bottom > first + visible { return bottom - visible }
      return first
    }
    switch self {
    case .center:
      return minimal(from: centered)
    case .centerIfOutside:
      return minimal(from: top < first || top >= first + visible ? centered : first)
    case .nearTopIfOutside:
      if bottom - top > visible { return top }
      guard top < first || bottom > first + visible else { return first }
      return max(bottom - visible, top - max(5, visible * 0.2))
    case .minimal:
      return minimal(from: first)
    }
  }
}
