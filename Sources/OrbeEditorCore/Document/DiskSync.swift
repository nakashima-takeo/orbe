import CryptoKit

/// 文書がディスクと揃えた時点の姿と、今の本文がその本文と同じか（未保存）。姿を置けば必ず「揃っている」になり、姿と
/// 状態が食い違う道を持たない。立てるのは即時（長さが違えば違う、同じなら確かめ中）、下ろすのは裏の比較が同じと
/// 答えてから——誤るときは未保存の側。
struct DiskSync {
  /// 揃えた時点の本文・ファイルのバイト列のダイジェスト・BOM の有無。開く・保存・受け入れ・差し替えで一度に置き換える
  /// （1 つでも古いまま残ると、揃っていない本文と比べて未保存を誤って下ろしうる）。
  struct Snapshot {
    let text: TextRope
    let digest: SHA256Digest
    let hasBOM: Bool
  }

  enum Dirtiness {
    case synced
    /// 違うと分かっている（長さが違う、または裏の比較が違うと答えた）。
    case differs
    /// 長さが同じで、今の版の比較を裏で待っている。
    case checking
  }

  private(set) var snapshot: Snapshot
  private(set) var dirtiness = Dirtiness.synced

  init(_ snapshot: Snapshot) {
    self.snapshot = snapshot
  }

  var isDirty: Bool { dirtiness != .synced }

  /// 揃えた姿を置く。
  mutating func sync(_ snapshot: Snapshot) {
    self.snapshot = snapshot
    dirtiness = .synced
  }

  /// 本文が変わった。長さが同じなら確かめ中にして true（呼び手が裏へ比較を頼む）。
  mutating func textDidChange(length: Int) -> Bool {
    dirtiness = length == snapshot.text.length ? .checking : .differs
    return dirtiness == .checking
  }

  /// 裏の比較の結果を当てる——確かめ中で、結果が今の版のときだけ（その後の編集で同じかは変わる）。揃ったら true。
  mutating func settle(_ outcome: ComparisonOutcome, version: Int) -> Bool {
    guard dirtiness == .checking, outcome.version == version else { return false }
    dirtiness = outcome.same ? .synced : .differs
    return outcome.same
  }

  /// 閉じるときに本文を手放す（状態は変えない）。
  mutating func releaseText() -> TextRope {
    defer {
      snapshot = Snapshot(text: TextRope(), digest: snapshot.digest, hasBOM: snapshot.hasBOM)
    }
    return snapshot.text
  }
}
