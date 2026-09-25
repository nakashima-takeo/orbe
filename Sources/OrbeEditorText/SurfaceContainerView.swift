import AppKit

/// 面の器。上端の余白を空け、左に行番号の列、その右にスクロールビューを並べる（本文は列の下をくぐらない）。器の大きさと
/// 列の幅（行数の桁で決まる）が変わるたびに置き直す（autoresizing は起点が .zero だと余白を保てず、面が器より余白の分だけ
/// 長くなって最下行が切れる）。地は持たない——載せる側の地がそのまま透ける。
final class SurfaceContainerView: NSView {
  /// 器へ渡されたホイールの出来事の行き先（面のスクロール）。
  weak var scrollTarget: NSScrollView?
  weak var column: LineNumbersView?
  var topInset: CGFloat = 0 {
    didSet { needsLayout = true }
  }

  override var isFlipped: Bool { true }

  /// 面の外（俯瞰など）や行番号の列から渡されたホイールを面のスクロールへ（契約: 載せる側は面の view へ渡すだけでよい）。
  override func scrollWheel(with event: NSEvent) {
    guard let scrollTarget else { return super.scrollWheel(with: event) }
    scrollTarget.scrollWheel(with: event)
  }

  override func layout() {
    super.layout()
    let height = max(0, bounds.height - topInset)
    let width = min(column?.fittingWidth ?? 0, bounds.width)
    column?.frame = NSRect(x: 0, y: topInset, width: width, height: height)
    scrollTarget?.frame = NSRect(
      x: width, y: topInset, width: max(0, bounds.width - width), height: height)
  }
}
