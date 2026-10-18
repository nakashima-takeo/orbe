import SwiftUI

// 成否・状態の印（自作。形の正はこのファイルの座標で、SwiftUI `Path` を直接組む）。`StatusGlyph` と同じ流儀で、各印の viewBox
// の座標を描く大きさへ乗算して組み、線の太さも同じ比で掛ける（`scaleEffect` は線をぼかすため使わない）。色は呼び手が
// トークンで渡す。文字コードの記号・システムのアイコンは使わない——字形がフォントで変わり、無いことがあるため。
// 実行中の回る輪はエージェントの状態の印（`StatusGlyphView` の working）を使う。

/// 印の種類。
enum MarkGlyphKind: Equatable {
  /// 成功（チェック）。viewBox 10×10。
  case success
  /// 失敗（斜めの十字）。viewBox 10×10。
  case failure
  /// 停止中（縦の 2 本線）。viewBox 10×10。
  case paused
  /// 帯の失敗（細い斜めの十字）。viewBox 8×12。
  case bandFailure
  /// 提案の受け皿（下向きの矢印と受け皿）。viewBox 12×18。
  case tray
  /// 外へ開く（右上向きの矢印）。viewBox 9×9。
  case openOut
  /// 左向きの矢印。viewBox 10×8。
  case arrowLeft
  /// 右向きの矢印。viewBox 10×8。
  case arrowRight

  fileprivate var box: CGSize {
    switch self {
    case .success, .failure, .paused: CGSize(width: 10, height: 10)
    case .bandFailure: CGSize(width: 8, height: 12)
    case .tray: CGSize(width: 12, height: 18)
    case .openOut: CGSize(width: 9, height: 9)
    case .arrowLeft, .arrowRight: CGSize(width: 10, height: 8)
    }
  }

  fileprivate var lineWidth: CGFloat {
    switch self {
    case .success, .failure, .paused, .bandFailure: 1.6
    case .tray: 1.3
    case .openOut, .arrowLeft, .arrowRight: 1.2
    }
  }

  /// viewBox の座標の折れ線（どれも塗らない線）。
  fileprivate var strokes: [[CGPoint]] {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    switch self {
    case .success: return [[p(2, 5.2), p(4.2, 7.4), p(8, 2.8)]]
    case .failure: return [[p(2.6, 2.6), p(7.4, 7.4)], [p(7.4, 2.6), p(2.6, 7.4)]]
    case .paused: return [[p(3.5, 2.4), p(3.5, 7.6)], [p(6.5, 2.4), p(6.5, 7.6)]]
    case .bandFailure: return [[p(1.6, 3.6), p(6.4, 8.4)], [p(6.4, 3.6), p(1.6, 8.4)]]
    case .tray:
      return [
        [p(6, 4), p(6, 9)], [p(3.5, 6.8), p(6, 9.3), p(8.5, 6.8)],
        [p(1.5, 10), p(1.5, 13.5), p(10.5, 13.5), p(10.5, 10)],
      ]
    case .openOut: return [[p(2.5, 6.5), p(6.5, 2.5)], [p(3.3, 2.5), p(6.5, 2.5), p(6.5, 5.7)]]
    case .arrowLeft: return [[p(9, 4), p(1, 4)], [p(4, 1), p(1, 4), p(4, 7)]]
    case .arrowRight: return [[p(1, 4), p(9, 4)], [p(6, 1), p(9, 4), p(6, 7)]]
    }
  }

  /// viewBox の座標を `k` 倍した折れ線と、その線の描き方。
  fileprivate func stroke(scale k: CGFloat) -> (path: Path, style: StrokeStyle) {
    var path = Path()
    for line in strokes {
      guard let first = line.first else { continue }
      path.move(to: CGPoint(x: first.x * k, y: first.y * k))
      for point in line.dropFirst() { path.addLine(to: CGPoint(x: point.x * k, y: point.y * k)) }
    }
    return (path, StrokeStyle(lineWidth: lineWidth * k, lineCap: .round, lineJoin: .round))
  }

  /// 文の中に置く印。文の 1 字として並ぶので、文の色に染まり、幅に収まらなければ文の末尾と一緒に省かれる。`font` の大文字の
  /// 高さの中ほどに揃える。
  func inline(_ font: NSFont) -> Text {
    let box = self.box
    let image = NSImage(size: box, flipped: true) { _ in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      let (path, style) = stroke(scale: 1)
      context.addPath(path.strokedPath(style).cgPath)
      context.setFillColor(NSColor.black.cgColor)
      context.fillPath()
      return true
    }
    image.isTemplate = true
    return Text(Image(nsImage: image).renderingMode(.template))
      .baselineOffset((font.capHeight - box.height) / 2)
  }
}

/// 印 1 つ。`width` は描く幅（高さは viewBox の比で決まる）。
struct MarkGlyph: View {
  let kind: MarkGlyphKind
  var width: CGFloat?
  let color: Color

  var body: some View {
    let box = kind.box
    let k = (width ?? box.width) / box.width
    Canvas { context, _ in
      let (path, style) = kind.stroke(scale: k)
      context.stroke(path, with: .color(color), style: style)
    }
    .frame(width: box.width * k, height: box.height * k)
    .accessibilityHidden(true)
  }
}

/// 地図の部品の点。普段は強調色の輪、最新の回が失敗なら赤の輪に斜めの十字、行き先は塗った点、走っている間は
/// 点の代わりに回る輪。
struct MapNodeGlyph: View {
  enum Look: Equatable {
    case idle
    case failed
    case running
    case destination
  }

  let look: Look

  var body: some View {
    switch look {
    case .idle:
      Circle().strokeBorder(Color.theme.accentPrimary, lineWidth: 1.5)
        .frame(width: 9, height: 9)
    case .destination:
      Circle().fill(Color.theme.accentPrimary).frame(width: 9, height: 9)
    case .failed:
      Canvas { context, _ in
        let ring = Path(ellipseIn: CGRect(x: 1, y: 1, width: 9, height: 9))
        context.stroke(ring, with: .color(Color.theme.danger), lineWidth: 1.5)
        var cross = Path()
        cross.move(to: CGPoint(x: 3.8, y: 3.8))
        cross.addLine(to: CGPoint(x: 7.2, y: 7.2))
        cross.move(to: CGPoint(x: 7.2, y: 3.8))
        cross.addLine(to: CGPoint(x: 3.8, y: 7.2))
        context.stroke(
          cross, with: .color(Color.theme.danger),
          style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
      }
      .frame(width: 11, height: 11)
    case .running:
      StatusGlyphView(kind: .working, size: 11)
    }
  }
}
