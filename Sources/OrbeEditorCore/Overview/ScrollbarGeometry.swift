import Foundation

/// スクロールバーのつまみ——長さ・位置と、ドラッグ・トラックの押下から位置への写像。VS Code `ScrollbarState`（矢印なし）を
/// 向きに依らない形で移したもの。量（見えている量・全体の量・位置）は同じ単位ならどの単位でもよく（縦は行、横は pt）、
/// つまみの長さと位置はトラックの pt。
public struct ScrollbarGeometry: Equatable, Sendable {
  /// つまみの最小の長さ（pt。掴めるように）。
  public static let minimumSliderLength: CGFloat = 20

  /// 位置（見えている先頭）。
  public let position: CGFloat
  /// 見えている量。
  public let visible: CGFloat
  /// スクロール全体の量。
  public let total: CGFloat
  /// つまみが要るか（スクロールできる）。
  public let isNeeded: Bool
  public let sliderLength: CGFloat
  public let sliderPosition: CGFloat
  /// 位置の 1 単位あたりのつまみの動き（pt / 単位）。
  private let ratio: CGFloat

  public init(visible: CGFloat, total: CGFloat, position: CGFloat, trackLength: CGFloat) {
    self.position = position
    self.visible = visible
    self.total = total
    isNeeded = total > visible && trackLength > 0
    guard isNeeded else {
      sliderLength = max(0, trackLength)
      sliderPosition = 0
      ratio = 0
      return
    }
    let length = max(Self.minimumSliderLength, floor(trackLength * visible / total)).rounded()
    sliderLength = length
    ratio = (trackLength - length) / (total - visible)
    sliderPosition = (position * ratio).rounded()
  }

  /// 縦——行の単位。スクロール全体は「最終行を最上段まで送れる」ぶんを含み `行数 + max(0, 表示行数 − 1)` 行。
  public init(lineCount: Int, firstLine: CGFloat, visibleLines: CGFloat, height: CGFloat) {
    self.init(
      visible: visibleLines, total: CGFloat(max(1, lineCount)) + max(0, visibleLines - 1),
      position: firstLine, trackLength: height)
  }

  /// 位置の上限。
  public var maxPosition: CGFloat { max(0, total - visible) }

  /// トラックの座標 `at` がつまみの上か。
  public func sliderContains(_ at: CGFloat) -> Bool {
    isNeeded && at >= sliderPosition && at < sliderPosition + sliderLength
  }

  /// つまみを `delta` pt 動かしたときの位置（この状態を起点にする）。
  public func position(afterDragging delta: CGFloat) -> CGFloat {
    clamp((sliderPosition + delta) / ratio)
  }

  /// トラックの座標 `at` につまみの中央が来る位置。
  public func position(centeringSliderAt at: CGFloat) -> CGFloat {
    clamp((at - sliderLength / 2) / ratio)
  }

  private func clamp(_ value: CGFloat) -> CGFloat {
    guard isNeeded, ratio > 0 else { return 0 }
    return min(max(0, value), maxPosition)
  }
}
