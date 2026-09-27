import OrbeEditorCore

/// アウトラインの見えている行と、シンボルの番号の対応。行の列は作らず、畳んだ部分木が隠す区間（昇順）とその累積の数から
/// 二分探索で引く——作るのも引くのも、畳んだ数（すべて折りたたんだときは見えている行の数）にだけ比例し、シンボルの総数に
/// 依らない。絞り込み中は、残るシンボルの番号の列（一致とその祖先）を土台の並びにして同じことをする。
struct OutlineRows {
  /// 畳み方。
  enum Folding {
    /// 並べた番号（昇順）のシンボルを畳む。
    case collapsed([Int])
    /// 集合の番号のシンボルのほかは、子を持つものをすべて畳む（すべて折りたたんだ後）。
    case allExcept(Set<Int>)
  }

  private let outline: DocumentOutline?
  /// 土台の並び（絞り込みで残るシンボルの番号。nil なら全シンボルの順）。
  private let base: [Int]?
  /// 隠す土台の位置の区間（昇順・重ならない）。
  private let hidden: [Range<Int>]
  /// `hidden` の先頭から k 個が隠す位置の数（k = 0...hidden.count）。
  private let hiddenBefore: [Int]
  let count: Int

  static let empty = OutlineRows(outline: nil, filter: nil, folding: .collapsed([]))

  init(outline: DocumentOutline?, filter: OutlineFilterResult?, folding: Folding) {
    self.outline = outline
    base = filter?.visible
    let baseCount = filter?.visible.count ?? outline?.symbols.count ?? 0
    var hidden: [Range<Int>] = []
    if let outline {
      let end: (Int) -> Int = { symbol in
        Self.position(of: outline.symbols[symbol].subtreeEnd, in: filter?.visible)
      }
      switch folding {
      case .collapsed(let symbols):
        for symbol in symbols {
          guard let position = Self.exactPosition(of: symbol, in: filter?.visible),
            hidden.last.map({ !$0.contains(position) }) ?? true
          else { continue }
          let limit = end(symbol)
          if limit > position + 1 { hidden.append((position + 1)..<limit) }
        }
      case .allExcept(let expanded):
        var position = 0
        while position < baseCount {
          let symbol = filter?.visible[position] ?? position
          let limit = end(symbol)
          if limit > position + 1, !expanded.contains(symbol) {
            hidden.append((position + 1)..<limit)
            position = limit
          } else {
            position += 1
          }
        }
      }
    }
    var before = [0]
    before.reserveCapacity(hidden.count + 1)
    for range in hidden { before.append(before.last! + range.count) }
    self.hidden = hidden
    hiddenBefore = before
    count = baseCount - before.last!
  }

  /// 行のシンボルの番号。
  func symbol(at row: Int) -> Int {
    // 行 r の前にある区間の数 = 「区間の頭の行（頭の位置 − それより前に隠れた数）が r 以下」の区間の数。
    var low = 0
    var high = hidden.count
    while low < high {
      let middle = (low + high) / 2
      if hidden[middle].lowerBound - hiddenBefore[middle] <= row {
        low = middle + 1
      } else {
        high = middle
      }
    }
    let position = row + hiddenBefore[low]
    return base?[position] ?? position
  }

  /// シンボルの行（畳まれている・絞り込みで落ちていれば nil）。
  func row(of symbol: Int) -> Int? {
    guard let position = Self.exactPosition(of: symbol, in: base) else { return nil }
    var low = 0
    var high = hidden.count
    while low < high {
      let middle = (low + high) / 2
      if hidden[middle].upperBound <= position { low = middle + 1 } else { high = middle }
    }
    if low < hidden.count, hidden[low].contains(position) { return nil }
    return position - hiddenBefore[low]
  }

  /// 絞り込みで残っているか（畳まれていても）。
  func includes(_ symbol: Int) -> Bool {
    Self.exactPosition(of: symbol, in: base) != nil
  }

  /// 見えている子を持つか（絞り込み中は、残る子があるか）。
  func hasChildren(_ symbol: Int) -> Bool {
    guard let outline, let position = Self.exactPosition(of: symbol, in: base) else {
      return false
    }
    return Self.position(of: outline.symbols[symbol].subtreeEnd, in: base) > position + 1
  }

  /// 土台の並びで、番号が `symbol` 以上の最初の位置。
  private static func position(of symbol: Int, in base: [Int]?) -> Int {
    guard let base else { return symbol }
    var low = 0
    var high = base.count
    while low < high {
      let middle = (low + high) / 2
      if base[middle] < symbol { low = middle + 1 } else { high = middle }
    }
    return low
  }

  /// 土台の並びでのシンボルの位置（並びに無ければ nil）。
  private static func exactPosition(of symbol: Int, in base: [Int]?) -> Int? {
    guard let base else { return symbol }
    let position = position(of: symbol, in: base)
    return position < base.count && base[position] == symbol ? position : nil
  }
}
