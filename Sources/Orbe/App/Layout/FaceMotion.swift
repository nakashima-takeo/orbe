import Foundation

/// 面の動き（純粋な値型）。境の位置 hx を行き先へ運ぶ位置のばねと、位置が決める形の目標を追う形のばね 2 本（左右）を、
/// 表示のフレームごとに進める。位置のばねは `flying` の間だけ動き、行き先は持たない——呼び手が毎回、確定した配置から渡す。
struct FaceMotion: Equatable {
  var hx: CGFloat
  var v: CGFloat = 0
  /// 位置のばねが行き先へ運んでいる途中か。
  var flying = false
  var sL: CGFloat
  var vL: CGFloat = 0
  var sR: CGFloat
  var vR: CGFloat = 0

  /// 位置 `hx` に、形も目標どおりで止まっている動き。
  static func rest(at hx: CGFloat, width: CGFloat) -> FaceMotion {
    let (l, r) = FaceGeometry.targets(hx, width: width)
    return FaceMotion(hx: hx, sL: l, sR: r)
  }

  var shape: FaceGeometry.Shape { FaceGeometry.Shape(hx: hx, sL: sL, sR: sR) }

  /// ばね（硬さ・減衰比）を dt 秒だけ進める（4ms 刻みの半陰的積分で安定させる）。
  static func spring(
    x: CGFloat, v: CGFloat, target: CGFloat,
    _ spring: (stiffness: CGFloat, damping: CGFloat), dt: CGFloat
  ) -> (x: CGFloat, v: CGFloat) {
    let k = spring.stiffness
    let c = 2 * spring.damping * k.squareRoot()
    let n = max(1, Int((dt / 0.004).rounded(.up)))
    let h = dt / CGFloat(n)
    var x = x
    var v = v
    for _ in 0..<n {
      let a = k * (target - x) - c * v
      v += a * h
      x += v * h
    }
    return (x, v)
  }

  /// dt 秒進める: 位置のばね（`flying` の間だけ。端で止め、行き先に十分近く遅ければ着地）→ 形のばね 2 本 → 形が目標に
  /// 十分近く遅ければ目標にぴったり合わせる。
  mutating func step(dt: CGFloat, width: CGFloat, goal: CGFloat) {
    let dt = min(0.05, max(0, dt))
    let maxX = FaceGeometry.maxPosition(width)
    if flying {
      (hx, v) = Self.spring(x: hx, v: v, target: goal, Theme.Motion.facePositionSpring, dt: dt)
      if hx < 0 {
        hx = 0
        v = 0
      }
      if hx > maxX {
        hx = maxX
        v = 0
      }
      if abs(goal - hx) < 0.2 && abs(v) < 2 {
        hx = goal
        v = 0
        flying = false
      }
    }
    let (tl, tr) = FaceGeometry.targets(hx, width: width)
    let shape = Theme.Motion.faceShapeSpring
    (sL, vL) = Self.spring(x: sL, v: vL, target: tl, shape, dt: dt)
    (sR, vR) = Self.spring(x: sR, v: vR, target: tr, shape, dt: dt)
    if abs(tl - sL) < 0.002 && abs(tr - sR) < 0.002 && abs(vL) < 0.01 && abs(vR) < 0.01 {
      snapShape(width: width)
    }
  }

  /// 位置も形も止まっているか。
  func isAtRest(width: CGFloat) -> Bool {
    let (tl, tr) = FaceGeometry.targets(hx, width: width)
    return !flying && v == 0 && vL == 0 && vR == 0 && sL == tl && sR == tr
  }

  /// 形を目標に直結する。
  mutating func snapShape(width: CGFloat) {
    (sL, sR) = FaceGeometry.targets(hx, width: width)
    vL = 0
    vR = 0
  }
}
