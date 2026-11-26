import CoreGraphics

/// 右シート左端ドラッグのリサイズ・全面吸着・右投げ閉じの純粋計算。
struct BrowserResizeSession: Equatable {
  static let defaultRatio: CGFloat = 0.52
  static let minRatio: CGFloat = 0.28
  static let maxRatio: CGFloat = 0.84
  static let fullSnapRatio: CGFloat = 0.86
  static let closeThresholdWidth: CGFloat = 240
  static let minClosePreviewWidth: CGFloat = 120

  /// ドラッグ中のプレビュー状態。
  enum PreviewState: Equatable {
    case normal(width: CGFloat, ratio: CGFloat)
    case snapFull(width: CGFloat)
    case snapClose(width: CGFloat)

    var previewWidth: CGFloat {
      switch self {
      case .normal(let width, _), .snapFull(let width), .snapClose(let width):
        width
      }
    }

    var badgeKind: SnapBadgeKind {
      switch self {
      case .normal(_, let ratio): .percent(Int((ratio * 100).rounded()))
      case .snapFull: .snapFull
      case .snapClose: .snapClose
      }
    }
  }

  /// ドラッグ中に左端へ表示するスナップバッジの種別。
  enum SnapBadgeKind: Equatable {
    case percent(Int)
    case snapFull
    case snapClose
  }

  /// ドラッグ確定時の遷移結果。
  enum CommitResult: Equatable {
    case keepSheet(ratio: CGFloat)
    case snapFull(preservedRatio: CGFloat)
    case close(preservedRatio: CGFloat)
  }

  /// ドラッグ開始時の確定比率。全面吸着・右投げ閉じ・ドラッグ中断時はこの比率を復元する。
  let startRatio: CGFloat
  private(set) var current: PreviewState

  init(initialRatio: CGFloat, containerWidth: CGFloat) {
    let clamped = Self.clampRatio(initialRatio)
    startRatio = clamped
    current = .normal(
      width: Self.sheetWidth(ratio: clamped, containerWidth: containerWidth), ratio: clamped)
  }

  /// ポインタ X 座標（ブラウザ層座標）から次のプレビュー状態を計算する。
  @discardableResult
  mutating func update(pointerX: CGFloat, containerWidth: CGFloat) -> PreviewState {
    guard containerWidth > 0 else {
      current = .normal(width: 0, ratio: startRatio)
      return current
    }
    let rawWidth = containerWidth - pointerX
    let ratio = rawWidth / containerWidth
    if ratio > Self.fullSnapRatio {
      current = .snapFull(width: containerWidth)
    } else if rawWidth < Self.closeThresholdWidth {
      let width = min(containerWidth, max(Self.minClosePreviewWidth, rawWidth))
      current = .snapClose(width: width)
    } else {
      let clamped = Self.clampRatio(ratio)
      current = .normal(
        width: Self.sheetWidth(ratio: clamped, containerWidth: containerWidth), ratio: clamped)
    }
    return current
  }

  /// ドラッグ離脱時の最終結果を返す。
  func commit() -> CommitResult {
    switch current {
    case .snapFull: .snapFull(preservedRatio: startRatio)
    case .snapClose: .close(preservedRatio: startRatio)
    case .normal(_, let ratio): .keepSheet(ratio: ratio)
    }
  }

  static func clampRatio(_ ratio: CGFloat) -> CGFloat {
    min(maxRatio, max(minRatio, ratio))
  }

  /// ウィンドウ幅と記憶比率から右シート幅を算出する。狭幅ウィンドウでも破綻させない。
  static func sheetWidth(ratio: CGFloat, containerWidth: CGFloat) -> CGFloat {
    guard containerWidth > 0 else { return 0 }
    return min(containerWidth, max(closeThresholdWidth, clampRatio(ratio) * containerWidth))
  }
}
