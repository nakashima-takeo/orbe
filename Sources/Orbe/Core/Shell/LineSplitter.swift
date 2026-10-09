import Foundation

/// 届いた塊を改行で割って 1 行ずつ渡す。`maxLength` を超えた行は渡さずに捨て、数える（貯める量を 1 行の上限で抑える）。
struct LineSplitter {
  let maxLength: Int
  private(set) var dropped = 0
  private var buffer = Data()
  private var discarding = false

  init(maxLength: Int) {
    self.maxLength = maxLength
  }

  /// 完成した行を順に `onLine` へ渡す。`onLine` が偽を返したら、そこで止めて偽を返す。
  mutating func feed(_ data: Data, onLine: (Data) -> Bool) -> Bool {
    var rest = data[...]
    while let newline = rest.firstIndex(of: UInt8(ascii: "\n")) {
      append(rest[..<newline])
      guard complete(onLine) else { return false }
      rest = rest[rest.index(after: newline)...]
    }
    append(rest)
    return true
  }

  /// 改行で終わらなかった最後の行を渡す。
  mutating func finish(onLine: (Data) -> Bool) -> Bool {
    guard discarding || !buffer.isEmpty else { return true }
    return complete(onLine)
  }

  private mutating func append(_ chunk: Data.SubSequence) {
    guard !discarding else { return }
    guard buffer.count + chunk.count <= maxLength else {
      discarding = true
      buffer = Data()
      return
    }
    buffer.append(contentsOf: chunk)
  }

  private mutating func complete(_ onLine: (Data) -> Bool) -> Bool {
    defer {
      buffer = Data()
      discarding = false
    }
    if discarding {
      dropped += 1
      return true
    }
    return buffer.isEmpty || onLine(buffer)
  }
}
