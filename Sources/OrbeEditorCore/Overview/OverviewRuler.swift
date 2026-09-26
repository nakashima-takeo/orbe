import Foundation

/// スクロールバーの上の印（overview ruler）の写像——行の区間を縦の区間へ比例で写し、短いものは最小の高さへ広げ、
/// 同じレーンで接するものを結ぶ。VS Code `DecorationsOverviewRuler._renderOneLane` とキャレットの描き方を移したもの。
/// 座標はデバイス px の整数（VS Code は canvas に描く。切り捨てと結合の判定を画素で行うので、pt にすると結果が変わる）。
public struct OverviewRuler: Equatable, Sendable {
  /// 印の最小の高さ（pt）。
  public static let minimumMarkHeight: CGFloat = 6
  /// キャレットの印の高さ（pt）。
  public static let caretHeight: CGFloat = 2
  /// 検索の一致がこれを超えると、ruler は近い行をまとめた近似になり、ミニマップには現在の一致だけが出る。
  public static let approximateFindMatchCount = 1000

  public enum Lane: Sendable {
    case left
    case center
    case full
  }

  /// 縦の区間（デバイス px。`y1..<y2`）。
  public struct Span: Equatable, Sendable {
    public let y1: Int
    public let y2: Int

    public init(y1: Int, y2: Int) {
      self.y1 = y1
      self.y2 = y2
    }
  }

  /// ruler の高さ（デバイス px）。
  public let canvasHeight: Int
  /// スクロール全体の行数（`行数 + max(0, 表示行数 − 1)`）。
  public let scrollLines: CGFloat
  public let scale: CGFloat

  /// `height` は ruler の高さ（pt）、`scale` はデバイス倍率。
  public init(lineCount: Int, visibleLines: CGFloat, height: CGFloat, scale: CGFloat) {
    canvasHeight = Int(max(0, height * scale))
    scrollLines = CGFloat(max(1, lineCount)) + max(0, visibleLines - 1)
    self.scale = scale
  }

  /// レーンの x と幅（デバイス px）。幅 `width` pt の左端 1 デバイス px は縁で、残りを 3 等分する（右の 1/3 は VS Code では
  /// 診断の印の場所で、Orbe は使わない）。
  public static func lane(_ lane: Lane, width: CGFloat, scale: CGFloat) -> (x: Int, width: Int) {
    let remaining = Int(width * scale) - 1
    let side = remaining / 3
    let center = remaining - side * 2
    switch lane {
    case .left: return (1, side)
    case .center: return (1 + side, center)
    case .full: return (1, remaining)
    }
  }

  /// 行の区間（0 始まり・両端を含む。昇順）を縦の区間へ写し、`y1 ≤ 直前の y2 + 1` なら結ぶ。
  public func spans(_ rows: [ClosedRange<Int>]) -> [Span] {
    guard canvasHeight > 0 else { return [] }
    let minimum = Int(Self.minimumMarkHeight * scale)
    let half = minimum / 2
    var result: [Span] = []
    for row in rows {
      var y1 = y(ofRow: row.lowerBound)
      var y2 = y(ofRow: row.upperBound + 1)
      if y2 - y1 < minimum {
        var center = (y1 + y2) / 2
        if center < half {
          center = half
        } else if center + half > canvasHeight {
          center = canvasHeight - half
        }
        y1 = center - half
        y2 = center + half
      }
      if let last = result.last, y1 <= last.y2 + 1 {
        result[result.count - 1] = Span(y1: last.y1, y2: max(last.y2, y2))
      } else {
        result.append(Span(y1: y1, y2: y2))
      }
    }
    return result
  }

  /// キャレットの印（全幅・高 2pt、中心は行の上端）。
  public func caret(row: Int) -> Span {
    let height = Int(Self.caretHeight * scale)
    let half = height / 2
    var center = y(ofRow: row)
    if center < half {
      center = half
    } else if center + half > canvasHeight {
      center = canvasHeight - half
    }
    return Span(y1: center - half, y2: center - half + height)
  }

  private func y(ofRow row: Int) -> Int {
    Int(floor(CGFloat(row) * CGFloat(canvasHeight) / scrollLines))
  }

  /// 1000 件を超える検索の一致の近似——`mergeLinesDelta = max(2, ceil(3 / (高さ / 行数)))` 行以内に続く一致を 1 つの
  /// 区間にまとめる（VS Code `FindDecorations.set`）。`rows` は一致の行の区間（昇順）、`height` はエディターの高さ（pt）。
  public static func approximate(_ rows: [ClosedRange<Int>], lineCount: Int, height: CGFloat)
    -> [ClosedRange<Int>]
  {
    guard var current = rows.first else { return [] }
    let perLine = height / CGFloat(max(1, lineCount))
    let delta = perLine > 0 ? max(2, Int(ceil(3 / perLine))) : 2
    var result: [ClosedRange<Int>] = []
    for row in rows.dropFirst() {
      if current.upperBound + delta >= row.lowerBound {
        current = current.lowerBound...max(current.upperBound, row.upperBound)
      } else {
        result.append(current)
        current = row
      }
    }
    result.append(current)
    return result
  }
}

/// 俯瞰（ミニマップとスクロールバーの印）へ出す、検索と出現の強調。区間は本文のオフセット（昇順・重ならない）。
/// git の変更とキャレットは文書から直接読むので含まない。
public struct OverviewDecorations: Equatable, Sendable {
  public var findMatches: [NSRange]
  public var currentFindMatch: NSRange?
  public var wordOccurrences: [NSRange]

  public init(
    findMatches: [NSRange] = [], currentFindMatch: NSRange? = nil, wordOccurrences: [NSRange] = []
  ) {
    self.findMatches = findMatches
    self.currentFindMatch = currentFindMatch
    self.wordOccurrences = wordOccurrences
  }

  public static let empty = OverviewDecorations()

  /// 検索の一致が多く、ruler は近似・ミニマップは現在の一致だけになる。
  public var approximatesFindMatches: Bool {
    findMatches.count > OverviewRuler.approximateFindMatchCount
  }
}
