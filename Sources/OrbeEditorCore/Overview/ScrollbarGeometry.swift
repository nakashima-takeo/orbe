import Foundation

/// スクロールバーのつまみ——長さ・位置と、ドラッグ・トラックの押下から位置への写像。VS Code `ScrollbarState`（矢印なし）を
/// 向きに依らない形で移したもの。量（見えている量・全体の量・位置）は同じ単位ならどの単位でもよく（縦は表示の単位、横は pt）、
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

  /// 縦——表示の単位（行高を 1 とする縦の位置。→ `TextReveal`）。`contentLines` は最後の項目の上端 + 1（差し込みの
  /// 無い面では行数）で、スクロール全体は「最後の項目を最上段まで送れる」ぶんを含み `contentLines + max(0, 表示行数 − 1)`。
  public init(contentLines: CGFloat, firstLine: CGFloat, visibleLines: CGFloat, height: CGFloat) {
    self.init(
      visible: visibleLines, total: max(1, contentLines) + max(0, visibleLines - 1),
      position: firstLine, trackLength: height)
  }

  /// 位置の上限。
  public var maxPosition: CGFloat { max(0, total - visible) }

  /// トラックの座標 `coordinate` がつまみの上か。
  public func sliderContains(_ coordinate: CGFloat) -> Bool {
    isNeeded && coordinate >= sliderPosition && coordinate < sliderPosition + sliderLength
  }

  /// つまみを `delta` pt 動かしたときの位置（この状態を起点にする）。
  public func position(afterDragging delta: CGFloat) -> CGFloat {
    clamp((sliderPosition + delta) / ratio)
  }

  /// トラックの座標 `coordinate` につまみの中央が来る位置。
  public func position(centeringSliderAt coordinate: CGFloat) -> CGFloat {
    clamp((coordinate - sliderLength / 2) / ratio)
  }

  private func clamp(_ value: CGFloat) -> CGFloat {
    guard isNeeded, ratio > 0 else { return 0 }
    return min(max(0, value), maxPosition)
  }
}
