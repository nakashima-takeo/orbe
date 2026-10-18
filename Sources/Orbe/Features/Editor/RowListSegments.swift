import Foundation

/// 列の区間の表の幾何——区間ごとの上端（前の余白を含む）を前もって積み、位置 ↔ 行を区間の数に比例する手間で引く（行の数に
/// 依らない）。高さは区間の表の中だけで、最後の行の下の空きと錨の一時の空きは列が足す。
struct RowListSegments {
  let segments: [RowListSegment]
  /// 各区間の最初の行の上端。
  private let tops: [CGFloat]
  /// 区間の表の高さ。
  let height: CGFloat

  init(_ segments: [RowListSegment]) {
    self.segments = segments
    var top: CGFloat = 0
    tops = segments.map { segment in
      top += segment.leading
      defer { top += CGFloat(segment.count) * segment.height }
      return top
    }
    height = top
  }

  /// 区間の表が覆う行の数。
  var rowCount: Int { segments.last.map { $0.start + $0.count } ?? 0 }

  /// 行 `row`（区間の表の中）の上端と高さ。
  func span(ofRow row: Int) -> (top: CGFloat, height: CGFloat) {
    var low = 0
    var high = segments.count
    while high - low > 1 {
      let mid = (low + high) / 2
      if segments[mid].start <= row { low = mid } else { high = mid }
    }
    let segment = segments[low]
    return (tops[low] + CGFloat(row - segment.start) * segment.height, segment.height)
  }

  /// 高さ `y` の行（区間の表の外・区間の前の余白なら nil）。
  func row(atY y: CGFloat) -> Int? {
    guard let low = segment(atY: y), y >= tops[low] else { return nil }
    let segment = segments[low]
    let offset = Int((y - tops[low]) / segment.height)
    return offset < segment.count ? segment.start + offset : nil
  }

  /// 下端が `y` より下にある最初の行（余白の上なら、その下の行）。
  func firstRow(from y: CGFloat) -> Int {
    guard let low = segment(atY: y) else { return 0 }
    let segment = segments[low]
    guard y >= tops[low] else { return segment.start }
    let offset = Int((y - tops[low]) / segment.height)
    if offset < segment.count { return segment.start + offset }
    return low + 1 < segments.count ? segments[low + 1].start : segment.start + segment.count
  }

  /// 高さ `y` を含む区間（前の余白を含めて、上端が `y` 以下の最後の区間）。最初の区間の余白の上も最初の区間。
  private func segment(atY y: CGFloat) -> Int? {
    guard y >= 0, !segments.isEmpty else { return nil }
    var low = 0
    var high = tops.count
    while high - low > 1 {
      let mid = (low + high) / 2
      if tops[mid] - segments[mid].leading <= y { low = mid } else { high = mid }
    }
    return low
  }
}
