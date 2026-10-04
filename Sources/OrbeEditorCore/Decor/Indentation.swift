import Foundation

/// 文書の字下げの作法——単位（1 段のスペース数。タブの表示幅もこの桁数）と、タブで字下げしているか。文書が本文から検出して
/// 面へ押す。
public struct Indentation: Equatable, Sendable {
  public var unit: Int
  public var usesTabs: Bool

  public init(unit: Int, usesTabs: Bool) {
    self.unit = unit
    self.usesTabs = usesTabs
  }

  private static let candidates = [2, 4, 8]
  public static let fallback = Indentation(unit: 4, usesTabs: false)

  /// 本文の UTF-16 単位を先頭から 1 度だけ読む。
  ///
  /// 単位は、隣り合う非空行の行頭スペース数の差のうち 2 / 4 / 8 に当たるものの最頻値。同数なら小さい方、候補が無ければ
  /// 4。行頭がタブの行は差の計算に入れない（タブは単位に依らず 1 段）。空白（スペース・タブ・CR）だけの行は数えない。
  ///
  /// タブかは VS Code の推定（`guessIndentation`）に倣う——行頭の空白にタブを含む行と、スペース 2 個以上で始まる行の数を
  /// 比べ、タブの行が多ければタブ。同数なら空白。
  public static func detect(in units: some Sequence<UInt16>) -> Indentation {
    var scan = Scan()
    for unit in units { scan.read(unit) }
    scan.endLine()
    let unit =
      scan.counts.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }?.key
      ?? fallback.unit
    return Indentation(unit: unit, usesTabs: scan.tabLines > scan.spaceLines)
  }

  /// 1 行ずつ読む状態。
  private struct Scan {
    var counts: [Int: Int] = [:]
    var tabLines = 0
    var spaceLines = 0
    private var previous: Int?
    /// 行頭の連続スペースの数（最初のスペースでない字で止まる）。
    private var spaces = 0
    private var countingSpaces = true
    /// 行頭の空白（スペースとタブ）の中か。
    private var leading = true
    private var startsWithTab = false
    private var leadingTab = false
    private var blank = true
    private var length = 0

    mutating func read(_ unit: UInt16) {
      guard unit != 0x0A else {
        endLine()
        return
      }
      if length == 0, unit == 0x09 { startsWithTab = true }
      length += 1
      if unit != 0x20 && unit != 0x09 && unit != 0x0D { blank = false }
      if countingSpaces {
        if unit == 0x20 { spaces += 1 } else { countingSpaces = false }
      }
      guard leading else { return }
      if unit == 0x09 {
        leadingTab = true
      } else if unit != 0x20 {
        leading = false
      }
    }

    mutating func endLine() {
      defer {
        spaces = 0
        countingSpaces = true
        leading = true
        startsWithTab = false
        leadingTab = false
        blank = true
        length = 0
      }
      guard length > 0, !blank else { return }
      if leadingTab {
        tabLines += 1
      } else if spaces > 1 {
        spaceLines += 1
      }
      guard !startsWithTab else {
        previous = nil
        return
      }
      if let previous, candidates.contains(abs(spaces - previous)) {
        counts[abs(spaces - previous), default: 0] += 1
      }
      previous = spaces
    }
  }
}
