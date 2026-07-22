import SwiftUI

/// GitHub octicon（`issue-opened` / `git-pull-request`・viewBox 16）を SwiftUI へ移植。
/// issue は同心円 3 枚を even-odd で「輪＋中心ドット」に、branch は octicon の path データを
/// そのまま正典として `OcticonPath` で描く。色は呼び出し側指定（Dispatch では `diffAdded`）。
struct GitGlyphView: View {
  enum Kind { case issue, branch }
  let kind: Kind
  var size: CGFloat = 12
  var color: Color

  var body: some View {
    glyphPath
      .fill(color, style: FillStyle(eoFill: kind == .issue))
      .frame(width: size, height: size)
  }

  private var glyphPath: Path {
    switch kind {
    case .issue: return GitGlyph.issue(size: size)
    case .branch: return GitGlyph.branch(size: size)
    }
  }
}

/// GitHub octicon の path 生成（viewBox 16 → 表示サイズへスケール）。
enum GitGlyph {
  /// issue（octicon issue-opened）: 外輪（r8 外周・r6.5 内周）＋中心ドット（r1.5）を even-odd で塗る。
  static func issue(size: CGFloat) -> Path {
    let k = size / 16
    var path = Path()
    // 外周 r8・内周 r6.5（穴）・中心ドット r1.5（even-odd で輪＋ドットになる）。
    path.addEllipse(in: CGRect(x: 0, y: 0, width: 16 * k, height: 16 * k))
    path.addEllipse(in: CGRect(x: 1.5 * k, y: 1.5 * k, width: 13 * k, height: 13 * k))
    path.addEllipse(in: CGRect(x: 6.5 * k, y: 6.5 * k, width: 3 * k, height: 3 * k))
    return path
  }

  /// branch: octicon の SVG path データ（viewBox 16・nonzero winding）を移植。
  /// パスの実体は octicon git-pull-request（git-branch は別形状）。呼称は UI 上の「branch」に合わせる。
  static func branch(size: CGFloat) -> Path {
    OcticonPath.path(
      "M1.5 3.25a2.25 2.25 0 1 1 3 2.122v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.25 2.25 0 0 1 "
        + "1.5 3.25Zm5.677-.177L9.573.677A.25.25 0 0 1 10 .854V2.5h1A2.5 2.5 0 0 1 13.5 5v5.628a2.251 "
        + "2.251 0 1 1-1.5 0V5a1 1 0 0 0-1-1h-1v1.646a.25.25 0 0 1-.427.177L7.177 3.427a.25.25 0 0 1 "
        + "0-.354ZM3.75 2.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm0 9.5a.75.75 0 1 0 0 1.5.75.75 0 0 "
        + "0 0-1.5Zm8.25.75a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Z",
      size: size)
  }
}

/// octicon（viewBox 16・回転なし・rx==ry の円弧のみ）の path データ文字列を SwiftUI `Path` へ移植する
/// 最小パーサ。対応コマンド: M/m L/l H/h V/v A/a Z/z。octicon の `d` 文字列をそのまま正典に使う。
enum OcticonPath {
  static func path(_ d: String, size: CGFloat) -> Path {
    var path = Path()
    var cursor = Cursor()
    let tokens = tokenize(d)
    var i = 0
    var command: Character = " "
    while i < tokens.count {
      if let ch = tokens[i].first, ch.isLetter {
        command = ch
        i += 1
      }
      i = step(command, tokens, i, &path, &cursor)
    }
    return path.applying(CGAffineTransform(scaleX: size / 16, y: size / 16))
  }

  /// パース中の現在点と subpath 始点（Z の戻り先）。
  private struct Cursor {
    var point = CGPoint.zero
    var start = CGPoint.zero
  }

  /// 1 コマンド分を消費して次の token index を返す。
  private static func step(
    _ command: Character, _ t: [String], _ i0: Int, _ path: inout Path, _ c: inout Cursor
  ) -> Int {
    var i = i0
    let rel = command.isLowercase
    func f() -> CGFloat {
      defer { i += 1 }
      guard i < t.count else { return 0 }  // 引数が途切れた d でも範囲外アクセスしない
      return CGFloat(Double(t[i]) ?? 0)
    }
    switch Character(command.lowercased()) {
    case "m":
      c.point = point(f(), f(), rel: rel, from: c.point)
      c.start = c.point
      path.move(to: c.point)
    case "l":
      c.point = point(f(), f(), rel: rel, from: c.point)
      path.addLine(to: c.point)
    case "h":
      c.point = CGPoint(x: rel ? c.point.x + f() : f(), y: c.point.y)
      path.addLine(to: c.point)
    case "v":
      c.point = CGPoint(x: c.point.x, y: rel ? c.point.y + f() : f())
      path.addLine(to: c.point)
    case "a":
      let r = f()
      _ = f()  // ry（本移植は rx==ry のみ）
      _ = f()  // x軸回転（本移植は 0 のみ）
      let flags = (large: f() != 0, sweep: f() != 0)
      let end = point(f(), f(), rel: rel, from: c.point)
      addArc(&path, from: c.point, to: end, r: r, flags: flags)
      c.point = end
    case "z":
      path.closeSubpath()
      c.point = c.start
    default:
      // 未対応コマンド（C/S/Q 等）は token を消費できず無限ループになるため、パースを打ち切る。
      assertionFailure("OcticonPath: unsupported command '\(command)'")
      return t.count
    }
    return i
  }

  private static func point(_ x: CGFloat, _ y: CGFloat, rel: Bool, from: CGPoint) -> CGPoint {
    rel ? CGPoint(x: from.x + x, y: from.y + y) : CGPoint(x: x, y: y)
  }

  /// 円弧（rx==ry=r・回転 0）を端点→中心へ変換（W3C F.6.5）し、微小線分で近似追加する。
  private static func addArc(
    _ path: inout Path, from p1: CGPoint, to p2: CGPoint, r r0: CGFloat,
    flags: (large: Bool, sweep: Bool)
  ) {
    let x1p = (p1.x - p2.x) / 2
    let y1p = (p1.y - p2.y) / 2
    var r = r0
    let lambda = (x1p * x1p + y1p * y1p) / (r * r)
    if lambda > 1 { r *= lambda.squareRoot() }
    let den = r * r * y1p * y1p + r * r * x1p * x1p
    let num = max(0, r * r * r * r - r * r * y1p * y1p - r * r * x1p * x1p)
    var coef = den > 0 ? (num / den).squareRoot() : 0
    if flags.large == flags.sweep { coef = -coef }
    let cxp = coef * y1p
    let cyp = -coef * x1p
    let center = CGPoint(x: cxp + (p1.x + p2.x) / 2, y: cyp + (p1.y + p2.y) / 2)
    let theta1 = angle(1, 0, (x1p - cxp) / r, (y1p - cyp) / r)
    var delta = angle((x1p - cxp) / r, (y1p - cyp) / r, (-x1p - cxp) / r, (-y1p - cyp) / r)
    if !flags.sweep, delta > 0 { delta -= 2 * .pi }
    if flags.sweep, delta < 0 { delta += 2 * .pi }
    let steps = max(2, Int((abs(delta) / (.pi / 24)).rounded(.up)))
    for s in 1...steps {
      let t = theta1 + delta * CGFloat(s) / CGFloat(steps)
      path.addLine(to: CGPoint(x: center.x + r * cos(t), y: center.y + r * sin(t)))
    }
  }

  /// 2 ベクトルのなす角（符号つき）。
  private static func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
    let len = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
    guard len > 0 else { return 0 }
    let a = acos(min(1, max(-1, (ux * vx + uy * vy) / len)))
    return ux * vy - uy * vx < 0 ? -a : a
  }

  /// `d` を数値・コマンド token へ分解。数値は符号・小数点で区切り、`9.573.677` を 2 値に割る。
  private static func tokenize(_ d: String) -> [String] {
    var out: [String] = []
    let chars = Array(d)
    var i = 0
    while i < chars.count {
      let ch = chars[i]
      if ch.isLetter {
        out.append(String(ch))
        i += 1
      } else if ch == " " || ch == "," {
        i += 1
      } else if ch == "-" || ch == "+" || ch == "." || ch.isNumber {
        var s = ""
        if ch == "-" || ch == "+" {
          s.append(ch)
          i += 1
        }
        var seenDot = false
        while i < chars.count, chars[i].isNumber || (chars[i] == "." && !seenDot) {
          if chars[i] == "." { seenDot = true }
          s.append(chars[i])
          i += 1
        }
        out.append(s)
      } else {
        i += 1
      }
    }
    return out
  }
}

#if DEBUG
  #Preview("GitGlyph — issue / branch") {
    HStack(spacing: Theme.Space.bar) {
      ForEach([CGFloat(12), 24, 48], id: \.self) { size in
        VStack(spacing: Theme.Space.note) {
          GitGlyphView(kind: .issue, size: size, color: .theme.diffAdded)
          GitGlyphView(kind: .branch, size: size, color: .theme.diffAdded)
        }
      }
    }
    .padding(Theme.Space.phrase)
    .background(Color.theme.bgBase)
  }
#endif
