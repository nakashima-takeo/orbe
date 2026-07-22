import Foundation

/// 受信バイト列を改行（`\n`）区切りの行へ切り出す。1 行が `maxLineBytes` を超えても
/// 改行が来ない場合は `.overflow` を報告し、呼び出し側がその接続を切断する。
/// 非ブロッキング read のドレインで分割到着するため、改行をまたぐ持ち越しを内部 buffer で吸収する。
/// queue 上でのみ触る前提（同期は持たない）。
struct LineFramer {
  private var buffer = Data()
  private let maxLineBytes: Int

  init(maxLineBytes: Int) { self.maxLineBytes = maxLineBytes }

  enum Outcome: Equatable {
    case lines([Data])
    case overflow
  }

  mutating func feed(_ bytes: Data) -> Outcome {
    buffer.append(bytes)
    var out: [Data] = []
    while let nl = buffer.firstIndex(of: 0x0A) {
      let line = buffer.subdata(in: buffer.startIndex..<nl)
      buffer.removeSubrange(buffer.startIndex...nl)
      if !line.isEmpty { out.append(line) }
    }
    // 改行が来ないまま残バッファが上限超 → 枯渇防止のため切断シグナル。
    if buffer.count > maxLineBytes { return .overflow }
    return .lines(out)
  }
}
