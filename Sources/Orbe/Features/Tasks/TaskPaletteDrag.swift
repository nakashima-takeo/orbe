import CoreGraphics

/// 一覧のタスクの行を掴んで、同じ欄の中で並べ替える掴みの状態。掴み中はストアを変えず、離した瞬間に
/// 1 回だけ確定する。
enum TaskPaletteDrag: Equatable {
  /// 掴み始めの兄弟 1 つ（欄のタスクの行は連続して並び、高さは行ごとに違いうる）。
  struct Sibling: Equatable {
    let id: Int
    let height: CGFloat
  }

  /// 掴み 1 回ぶん。落ちる位置・行のずれ・線は、掴み始めに固めた兄弟の並びと高さ、移動量から決まる。
  struct Session: Equatable {
    let taskID: Int
    /// 掴み始めの位置（同じ掴みの続きを見分ける印）。
    let start: CGPoint
    /// 掴み始めの、同じ欄の見えている未完了のタスク（一覧の順）。
    let siblings: [Sibling]
    /// `siblings` の中の自分の番号。
    let from: Int
    /// 掴み始めの、掴んだ行の上端（一覧の中身の先頭から、上の行の高さの和）。
    let top: CGFloat
    /// 掴み始めからの縦の移動量。
    var translation: CGFloat = 0

    /// 兄弟 `index` の上端の、掴んだ行の元の上端からの縦の位置。
    private func offset(of index: Int) -> CGFloat {
      index >= from
        ? siblings[from..<index].reduce(0) { $0 + $1.height }
        : -siblings[index..<from].reduce(0) { $0 + $1.height }
    }

    /// 落ちる番号（`siblings` の中）。下へは掴んだ行の下端が、上へは上端が、隣の行の中点を越えた数だけ進む。
    var target: Int {
      let height = siblings[from].height
      var target = from
      while target + 1 < siblings.count,
        translation + height >= offset(of: target + 1) + siblings[target + 1].height / 2
      {
        target += 1
      }
      while target - 1 >= 0, translation <= offset(of: target - 1) + siblings[target - 1].height / 2
      {
        target -= 1
      }
      return target
    }

    /// 掴んだ行の表示上のずれ。欄の先頭の行の上端から末尾の行の下端までに収める。
    var offset: CGFloat {
      let last = siblings.count - 1
      return min(
        max(translation, offset(of: 0)),
        offset(of: last) + siblings[last].height - siblings[from].height)
    }

    /// 落ちる位置の線の中心の、掴んだ行の元の上端からの縦の位置。下へは落ちる先の行の下端、上へは上端。
    /// 元の位置に落ちるなら nil。
    var indicatorY: CGFloat? {
      let target = target
      guard target != from else { return nil }
      return target > from ? offset(of: target) + siblings[target].height : offset(of: target)
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
