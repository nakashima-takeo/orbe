/// 種を決めた乱数（SplitMix64）。同じ種なら同じ列を返す。
struct SplitMix {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next(below bound: Int) -> Int {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return Int((z ^ (z >> 31)) % UInt64(bound))
  }
}
