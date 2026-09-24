import Foundation

/// 縦スクロールバーのつまみ——長さ・位置と、ドラッグ・トラックの押下から先頭行への写像。VS Code `ScrollbarState`
/// （矢印なし、対のスクロールバー 0）を行の単位へ移したもの。スクロール全体は「最終行を最上段まで送れる」ぶんを含み
/// `行数 + max(0, 表示行数 − 1)` 行。
public struct ScrollbarGeometry: Equatable, Sendable {
  /// つまみの最小の長さ（pt。掴めるように）。
  public static let minimumSliderLength: CGFloat = 20

  public let firstLine: CGFloat
  public let visibleLines: CGFloat
  /// スクロール全体の行数。
  public let scrollLines: CGFloat
  /// つまみが要るか（スクロールできる）。
  public let isNeeded: Bool
  public let sliderLength: CGFloat
  public let sliderPosition: CGFloat
  /// 先頭行 1 行あたりのつまみの動き（pt / 行）。
  private let ratio: CGFloat

  public init(lineCount: Int, firstLine: CGFloat, visibleLines: CGFloat, height: CGFloat) {
    let scrollLines = CGFloat(max(1, lineCount)) + max(0, visibleLines - 1)
    self.firstLine = firstLine
    self.visibleLines = visibleLines
    self.scrollLines = scrollLines
    isNeeded = scrollLines > visibleLines && height > 0
    guard isNeeded else {
      sliderLength = max(0, height)
      sliderPosition = 0
      ratio = 0
      return
    }
    let length = max(Self.minimumSliderLength, floor(height * visibleLines / scrollLines)).rounded()
    sliderLength = length
    ratio = (height - length) / (scrollLines - visibleLines)
    sliderPosition = (firstLine * ratio).rounded()
  }

  /// 先頭行の上限（最終行が最上段）。
  public var maxFirstLine: CGFloat { max(0, scrollLines - visibleLines) }

  public func sliderContains(y: CGFloat) -> Bool {
    isNeeded && y >= sliderPosition && y < sliderPosition + sliderLength
  }

  /// つまみを `delta` pt 動かしたときの先頭行（この状態を起点にする）。
  public func firstLine(afterDragging delta: CGFloat) -> CGFloat {
    clamp((sliderPosition + delta) / ratio)
  }

  /// トラックの y につまみの中央が来る先頭行。
  public func firstLine(centeringSliderAt y: CGFloat) -> CGFloat {
    clamp((y - sliderLength / 2) / ratio)
  }

  private func clamp(_ line: CGFloat) -> CGFloat {
    guard isNeeded, ratio > 0 else { return 0 }
    return min(max(0, line), maxFirstLine)
  }
}
