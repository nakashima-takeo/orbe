/// 区間を見せる方針の縦の着地（VS Code の `revealRange*` と同じ考え方）。横の寄せ方は方針に依らない（→
/// `TextSurface.reveal`）。
public enum TextReveal: Equatable, Sendable {
  /// 区間の先頭の行を見えている高さの中央へ（見えていても送る）。そこから区間の終わりが下へはみ出せば終わりを下端へ、
  /// 見えている高さより高ければ先頭の行を上端へ。
  case center
  /// 区間の先頭の行が縦に見えていなければ中央へ、見えていれば最小限。
  case centerIfOutside
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
    case .minimal:
      return minimal(from: first)
    }
  }
}
