import AppKit

/// 分割比を保持する NSSplitView。復元時に保存比率を一度だけ divider に適用する。
/// 現在比 `ratio` は実フレームから算出するため、ユーザーのドラッグ結果も保存値に反映される
/// （未レイアウトの非アクティブ workspace では復元値をそのまま返す）。
final class WorkspaceSplitView: NSSplitView {
  private var restored: Double = 0.5
  private var pending = false

  func restore(ratio: Double) {
    restored = ratio
    pending = true
    needsLayout = true
  }

  var ratio: Double {
    guard arrangedSubviews.count == 2 else { return restored }
    let total = isVertical ? bounds.width : bounds.height
    guard total > 0 else { return restored }
    let first = arrangedSubviews[0].frame
    return Double((isVertical ? first.width : first.height) / total)
  }

  override func layout() {
    super.layout()
    guard pending, arrangedSubviews.count == 2 else { return }
    let total = isVertical ? bounds.width : bounds.height
    guard total > 0 else { return }
    // setPosition は同期的に layout() を再入させる。先に pending を倒さないと
    // 復元比が 0.5 以外（= 実際に divider が動く）のとき無限再帰でスタックを溢れさせる。
    pending = false
    setPosition(total * CGFloat(restored), ofDividerAt: 0)
  }
}
