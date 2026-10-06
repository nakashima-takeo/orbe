import Foundation

/// 人が積み上げた内容を持つ state ファイル（workspaces.json・tasks.json）の、「在るのに使えなかった原本」を
/// 守る規律。退避 → 最新 1 件だけ残す → 退避できなければその場所へ書かない、を 1 か所で持つ。
///
/// 読み手は使えなかった原本を見つけたら `quarantine(_:)` を呼び、書き手は `permitsWrite(to:)` を通す。
/// 直後の既定起動が打つ `.atomic` write は原本を完全に潰すので、退避しないと復元手段が消える。
struct StateFileQuarantine {
  /// 退避に失敗して原位置に残っている原本の場所。場所で持つので、保存先が変われば古い判断を引きずらない。
  private var unsalvagedOriginal: URL?

  /// 読み込みのたびに呼ぶ。前回の判断を持ち越さない。
  mutating func reset() {
    unsalvagedOriginal = nil
  }

  /// 保全できていない原本を潰す書き込みでないか。
  func permitsWrite(to url: URL) -> Bool {
    url != unsalvagedOriginal
  }

  /// 使えなかった原本を隣の `<名前>-broken-<日時>.<拡張子>` へ退避する（最新 1 件だけ残す）。
  /// 先に古い退避物を消してから move するので、退避先の名前は常に空いている——秒精度の
  /// タイムスタンプが同一秒で衝突する問題を構造的に持たない。消えるのは常により古い控えで、
  /// 退避が 2 回起きる系列では 1 件目（＝ユーザーの内容）が消えて 2 件目（＝1 回目の後に書かれた
  /// 既定の内容）だけが残るが、毎起動のゴミを積まない方を採る（prune の失敗はゴミが 1 件残るだけ
  /// なので退避ガードを立てない）。
  mutating func quarantine(_ url: URL) {
    let fm = FileManager.default
    let dir = url.deletingLastPathComponent()
    let prefix = url.deletingPathExtension().lastPathComponent + "-broken-"
    let suffix = "." + url.pathExtension
    let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
    for name in names where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
      try? fm.removeItem(at: dir.appendingPathComponent(name))
    }

    let stamp = DateFormatter()
    stamp.locale = Locale(identifier: "en_US_POSIX")
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    let dest = dir.appendingPathComponent(prefix + stamp.string(from: Date()) + suffix)
    do {
      try fm.moveItem(at: url, to: dest)
      NSLog("[state] quarantined unreadable \(url.lastPathComponent) to \(dest.path)")
    } catch {
      // 原本が実際に残っているときだけガードを立てる。原本ごと消えていたら守る対象が無く、
      // ここで立てるとそのセッションの内容が無言で一切保存されなくなる。
      guard fm.fileExists(atPath: url.path) else { return }
      unsalvagedOriginal = url
      NSLog("[state] quarantine failed, save disabled: \(url.path)")
    }
  }
}
