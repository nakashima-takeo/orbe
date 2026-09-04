/// control が emit した全イベントの直近 `capacity` 件と、kind・pane を問わない 1 本の単調増加 seq
/// （1 始まり・永続しない）。seq を振るのは `append` だけで、所有者は control queue。
/// 「保持範囲」の判定はここが唯一持つ。
struct EventHistory {
  enum Replay {
    /// `after` より後で最初に一致した record。
    case match(ControlEventRecord)
    /// `after` 以後に一致は無い（待機を張る）。
    case none
    /// seq `after + 1` が既に落ちている（呼び出し側は seq を取り直す）。
    case evicted
    /// `after` が最新 seq より大きい（観測しえない値＝呼び出し側のバグ）。
    case future
  }

  let capacity: Int
  private var records: [ControlEventRecord] = []
  /// リングの最古の位置（`records` が `capacity` に達した後だけ動く）。
  private var head = 0
  private(set) var latestSeq = 0

  init(capacity: Int) {
    self.capacity = capacity
  }

  mutating func append(_ event: ControlEvent) -> ControlEventRecord {
    latestSeq += 1
    let record = ControlEventRecord(seq: latestSeq, event: event)
    if records.count < capacity {
      records.append(record)
    } else {
      records[head] = record
      head = (head + 1) % capacity
    }
    return record
  }

  /// `after` より後のイベントを seq 昇順に走査し、`matches` する最初の 1 件を返す。
  func replay(after: Int, where matches: (ControlEvent) -> Bool) -> Replay {
    if after > latestSeq { return .future }
    if after == latestSeq { return .none }
    let oldestSeq = latestSeq - records.count + 1
    if after + 1 < oldestSeq { return .evicted }
    for offset in (after + 1 - oldestSeq)..<records.count {
      let record = records[(head + offset) % capacity]
      if matches(record.event) { return .match(record) }
    }
    return .none
  }
}
