import Foundation
import os

/// シンボルの種類。VS Code の SymbolKind の部分集合と、文書の構造を持つ言語（Markdown・JSON / YAML / TOML・CSS・HTML・
/// Dockerfile）の 5 つ。規則（`.scm`）の `#set! kind` の値と同じ綴り。
public enum OutlineKind: String, CaseIterable, Sendable {
  case `class`, `struct`, `enum`, interface, type, module
  case function, method, constructor
  case property, variable, constant, enumMember, key
  case heading, selector, element, instruction
}

/// シンボルの同一性。祖先の名前と種類の道筋を親の鍵から順に 64bit に畳んだ値で、同じ道筋が並べば出現順の番号で分ける。
/// 取り直しをまたいで同じシンボルを指す（実行中の開閉の状態を持ち越す）ための鍵で、位置を含まない。大きさは祖先の名前に
/// 依らない（深い入れ子や長い名前でも鍵は 1 つ 8 バイト）。種はプロセスごとに変わるので永続しない。まれに衝突すれば
/// 開閉を 1 つ取り違えるだけ。
public struct OutlineKey: Hashable, Sendable {
  let value: Int
}

/// 取り出しの結果を指す値。結果ごとに（どの文書でも）違い、位置の問いに添えて、問いが指す結果が文書の持つ結果と同じかを
/// 確かめる。
public struct OutlineToken: Hashable, Sendable {
  let serial: Int

  private static let counter = OSAllocatedUnfairLock(initialState: 0)

  static func next() -> OutlineToken {
    OutlineToken(
      serial: counter.withLock { serial in
        serial += 1
        return serial
      })
  }
}

/// シンボル 1 つの、位置を含まない面。
public struct OutlineSymbol: Equatable, Sendable {
  public let name: String
  public let kind: OutlineKind
  public let depth: Int
  /// 親の番号（最上位は nil）。
  public let parent: Int?
  /// 部分木の終わり（先行順の番号。この番号から後ろは部分木の外）。
  public let subtreeEnd: Int
  public let key: OutlineKey
}

/// 文書のアウトライン——ある版の本文から取り出したシンボルの列（位置順・先行順）。位置（範囲と名前の範囲）は取り出した
/// 版の座標で、Core の外へは出さない。位置の問いは文書が今の版の座標で答える（`EditorDocument.outlineSymbol` ほか）。
public struct DocumentOutline: Sendable {
  public let token: OutlineToken
  public let symbols: [OutlineSymbol]
  /// 最上位のシンボルの数。
  public let rootCount: Int
  /// 取り出した本文の版。
  let version: Int
  /// シンボルの範囲（`version` の本文の上）。
  let ranges: [NSRange]
  /// 名前の範囲（飛び先。`version` の本文の上）。
  let nameRanges: [NSRange]
  private let indices: [OutlineKey: Int]

  init(version: Int, symbols: [OutlineSymbol], ranges: [NSRange], nameRanges: [NSRange]) {
    token = .next()
    self.version = version
    self.symbols = symbols
    self.ranges = ranges
    self.nameRanges = nameRanges
    var indices: [OutlineKey: Int] = [:]
    indices.reserveCapacity(symbols.count)
    var rootCount = 0
    for (index, symbol) in symbols.enumerated() {
      indices[symbol.key] = index
      if symbol.parent == nil { rootCount += 1 }
    }
    self.indices = indices
    self.rootCount = rootCount
  }

  /// 鍵のシンボルの番号（この結果に無ければ nil）。
  public func index(of key: OutlineKey) -> Int? {
    indices[key]
  }

  public func hasChildren(_ index: Int) -> Bool {
    symbols[index].subtreeEnd > index + 1
  }

  /// `offset`（`version` の本文の上）を含む最も深いシンボル。同じ範囲の兄弟なら先頭のもの。
  func deepest(containing offset: Int) -> Int? {
    var low = 0
    var high = ranges.count
    while low < high {
      let middle = (low + high) / 2
      if ranges[middle].location <= offset { low = middle + 1 } else { high = middle }
    }
    var candidate: Int? = low > 0 ? low - 1 : nil
    while let index = candidate {
      let range = ranges[index]
      if offset <= NSMaxRange(range) { break }
      candidate = symbols[index].parent
    }
    guard var found = candidate else { return nil }
    while found > 0, ranges[found - 1] == ranges[found],
      symbols[found - 1].depth == symbols[found].depth
    {
      found -= 1
    }
    return found
  }
}
