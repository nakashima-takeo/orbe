import Foundation

/// 受信バイト列を改行（`\n`）区切りの行へ切り出す。1 行が `maxLineBytes` を超えても
/// 改行が来ない場合は `.overflow` を報告し、呼び出し側がその接続を切断する。
/// 非ブロッキング read のドレインで分割到着するため、改行をまたぐ持ち越しを内部 buffer で吸収する。
/// queue 上でのみ触る前提（同期は持たない）。
struct LineFramer {
  private var buffer = Data()
  /// `buffer` の先頭から「改行は無い」と確定済みのバイト数。
  private var scanned = 0
  private let maxLineBytes: Int

  init(maxLineBytes: Int) { self.maxLineBytes = maxLineBytes }

  enum Outcome: Equatable {
    case lines([Data])
    case overflow
  }

  mutating func feed(_ bytes: Data) -> Outcome {
    buffer.append(bytes)
    var out: [Data] = []
    // 改行は未走査の範囲にしか現れ得ない。毎回先頭から探すと、改行の来ない長い行で走査量が
    // 受信量の二乗になり、詰まった 1 接続が共有シリアルキューの CPU を焼く（非ブロッキング化で
    // 断ったはずの head-of-line blocking が CPU 側で戻ってしまう）。
    while let nl = buffer[buffer.index(buffer.startIndex, offsetBy: scanned)...]
      .firstIndex(of: 0x0A)
    {
      let line = buffer.subdata(in: buffer.startIndex..<nl)
      buffer.removeSubrange(buffer.startIndex...nl)
      scanned = 0
      if !line.isEmpty { out.append(line) }
    }
    scanned = buffer.count
    // 改行が来ないまま残バッファが上限超 → 枯渇防止のため切断シグナル。
    if buffer.count > maxLineBytes { return .overflow }
    return .lines(out)
  }
}
