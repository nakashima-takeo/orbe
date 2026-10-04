import CoreGraphics

/// 一覧のタスクの行を掴んで、同じ欄の中で並べ替える掴みの状態。掴み中はストアを変えず、離した瞬間に
/// 1 回だけ確定する。
enum TaskPaletteDrag: Equatable {
  /// 掴み 1 回ぶん。落ちる位置・行のずれ・線は、掴み始めに固めた兄弟の並びと移動量から決まる（欄の
  /// タスクの行は同じ高さで連続して並ぶ）。
  struct Session: Equatable {
    let taskID: Int
    /// 掴み始めの位置（同じ掴みの続きを見分ける印）。
    let start: CGPoint
    /// 掴み始めの、同じ欄の見えている未完了のタスクの ID（一覧の順）。
    let siblings: [Int]
    /// `siblings` の中の自分の番号。
    let from: Int
    /// 掴み始めの、一覧の行の中の自分の番号。
    let rowIndex: Int
    /// 掴み始めからの縦の移動量。
    var translation: CGFloat = 0

    /// 落ちる番号（`siblings` の中）。
    var target: Int {
      let moved = Int((translation / TaskPaletteRowMetrics.height).rounded())
      return min(max(from + moved, 0), siblings.count - 1)
    }

    /// 掴んだ行の表示上のずれ。欄の先頭の行の上端から末尾の行の下端までに収める。
    var offset: CGFloat {
      let height = TaskPaletteRowMetrics.height
      return min(
        max(translation, -CGFloat(from) * height), CGFloat(siblings.count - 1 - from) * height)
    }

    /// 落ちる位置の線の中心の、掴んだ行の元の上端からの縦の位置。元の位置に落ちるなら nil。
    var indicatorY: CGFloat? {
      let target = target
      guard target != from else { return nil }
      return CGFloat(target - from + (target > from ? 1 : 0)) * TaskPaletteRowMetrics.height
    }
  }

  case idle
  case dragging(Session)
  /// 捨てた掴み。掴んだ行が一覧から消えると onEnded が来ないので、同じ掴みの続きを位置で見分けて無視する。
  case discarded(start: CGPoint)

  var session: Session? {
    guard case .dragging(let session) = self else { return nil }
    return session
  }
}
