import AppKit

/// libghostty が報告する scrollback の状態（SCROLLBAR アクション）。
/// total=総行数 / offset=先頭可視行 / len=可視行数。SurfaceScrollView がつまみに反映する。
struct ScrollbarState {
  let total: Int
  let offset: Int
  let len: Int
}

extension SurfaceView {
  /// CELL_SIZE アクションの取り込み。ピクセル寸法をポイントに直して保持する。
  func updateCellSize(_ pixelSize: CGSize) {
    let scale = backingScale
    cellSize = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
    onScrollbarUpdate?()
  }

  /// SCROLLBAR アクションの取り込み。
  func updateScrollbar(_ state: ScrollbarState) {
    scrollbar = state
    onScrollbarUpdate?()
  }
}
