import AppKit

/// 取っ手の操作: 掴む・引く・押す・離す。
extension TabFacesView {
  /// 掴んだ: 位置のばねを止めて手に渡す（動いていたかを覚える）。焦点の面へ first responder を戻す。寸法は配らない。
  func grab(at x0: CGFloat) {
    let wasFlying = motion.flying
    motion.flying = false
    motion.v = 0
    let ratio0 = maxPosition > 0 ? motion.hx / maxPosition : 0
    interaction = .pressed(x0: x0, ratio0: ratio0, wasFlying: wasFlying)
    window?.makeFirstResponder(focusTarget)
    updateClock()
  }

  /// 引いている: 位置はポインタに 1:1 で付き、形は時計が追う（Reduce Motion なら直結）。鏡は書き換えない。
  func drag(to x: CGFloat, at time: CFTimeInterval) {
    var samples: [Sample]
    let x0: CGFloat
    let ratio0: CGFloat
    switch interaction {
    case .pressed(let px0, let pratio0, _):
      (x0, ratio0, samples) = (px0, pratio0, [])
    case .dragging(let dx0, let dratio0, let dsamples):
      (x0, ratio0, samples) = (dx0, dratio0, dsamples)
    case .settled, .moving:
      return
    }
    motion.hx = min(max(ratio0 * maxPosition + x - x0, 0), maxPosition)
    samples.append(Sample(time: time, hx: motion.hx))
    while samples.count > 2, time - samples[0].time > FaceGeometry.releaseVelocityWindow {
      samples.removeFirst()
    }
    interaction = .dragging(x0: x0, ratio0: ratio0, samples: samples)
    if reduceMotion { motion.snapShape(width: bounds.width) }
    let g = dragResolved()
    pendingDragSizes = g
    showDrag(g)
    updateClock()
  }

  /// 引いている間の形を解く（割合は位置から、焦点は鏡のまま）。
  func dragResolved() -> FaceGeometry.Resolved {
    let ratio = FaceGeometry.ratio(hx: motion.hx, width: bounds.width) ?? 0
    return FaceGeometry.resolve(
      FaceLayout(editorRatio: ratio, focus: faces.focus).normalized, shape: motion.shape,
      size: bounds.size)
  }

  func flushDragSizes() {
    guard let g = pendingDragSizes else { return }
    pendingDragSizes = nil
    applySizes(g)
    place(g.frames)
  }

  /// 動かさずに離した: 位置のばねが動いていたなら、その位置で速度 0 で離したことにする。そうでなければ押した——端なら
  /// 反対の全面へ、分割中なら焦点の側の全面へ。
  func click() {
    guard case .pressed(_, _, let wasFlying) = interaction else { return }
    if wasFlying { return release(at: nil, time: nil) }
    interaction = .settled
    onFacesRequested?(FaceGeometry.handleClick(committed), true)
  }

  /// 離した: 直前の勢いで少し先を見て、端の近くなら閉じる配置へ勢いのまま滑らせ、それ以外は離した位置（点に丸める）で
  /// 分割として確定する（行き過ぎない）。
  func release(at x: CGFloat?, time: CFTimeInterval?) {
    var velocity: CGFloat = 0
    switch interaction {
    case .dragging(let x0, let ratio0, let samples):
      if let x { motion.hx = min(max(ratio0 * maxPosition + x - x0, 0), maxPosition) }
      if let time {
        velocity = Self.velocity(samples + [Sample(time: time, hx: motion.hx)], at: time)
      }
      flushDragSizes()
    case .pressed(_, _, wasFlying: true):
      break
    case .pressed, .settled, .moving:
      return
    }
    let maxX = maxPosition
    let final: FaceLayout
    if let goal = FaceGeometry.release(hx: motion.hx, velocity: velocity, width: bounds.width) {
      motion.v = velocity
      motion.flying = true
      final = FaceLayout(editorRatio: maxX > 0 ? Double(goal / maxX) : 0, focus: faces.focus)
    } else {
      motion.hx = motion.hx.rounded()
      motion.v = 0
      motion.flying = false
      let ratio = FaceGeometry.ratio(hx: motion.hx, width: bounds.width) ?? 0
      final = FaceLayout(editorRatio: ratio, focus: faces.focus)
    }
    interaction = .moving
    if final.normalized != faces {
      onFacesRequested?(final.normalized, true)
    } else {
      beginMove(to: committed)
    }
  }

  /// 離したときの速度（点/秒）。`releaseVelocityWindow` より古い標本は捨て、2 件に満たないか間隔が短すぎれば 0。
  private static func velocity(_ samples: [Sample], at time: CFTimeInterval) -> CGFloat {
    let recent = samples.filter { time - $0.time <= FaceGeometry.releaseVelocityWindow }
    guard recent.count >= 2, let first = recent.first, let last = recent.last else { return 0 }
    let span = last.time - first.time
    guard span > 0.004 else { return 0 }
    return (last.hx - first.hx) / CGFloat(span)
  }
}
