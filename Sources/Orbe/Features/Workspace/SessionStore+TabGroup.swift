import Foundation

/// タブグループ（隣接不変条件）の導出と、連の単位で動く変異。挿入・並び替え・閉じるは本体側が
/// 同じ導出を読んで不変条件を守る。
extension SessionStore {
  // MARK: - 導出

  /// 隣接する同 `groupKey` の連（Range の列。空配列なら []）。連の分割はこの 1 実装だけが持ち、
  /// chrome はここが導いた連を流し込まれて描く。
  static func segments(of tabs: [TerminalTab]) -> [Range<Int>] {
    var out: [Range<Int>] = []
    var start = 0
    for i in tabs.indices where i + 1 == tabs.count || tabs[i + 1].groupKey != tabs[i].groupKey {
      out.append(start..<(i + 1))
      start = i + 1
    }
    return out
  }

  /// index `i` を含む連。
  static func segment(containing i: Int, in tabs: [TerminalTab]) -> Range<Int> {
    let key = tabs[i].groupKey
    var lo = i
    var hi = i + 1
    while lo > 0, tabs[lo - 1].groupKey == key { lo -= 1 }
    while hi < tabs.count, tabs[hi].groupKey == key { hi += 1 }
    return lo..<hi
  }

  /// `key` の連の右端の挿入 index（無ければ `tabs.count`）。
  static func insertionIndex(forKey key: String, in tabs: [TerminalTab]) -> Int {
    tabs.lastIndex { $0.groupKey == key }.map { $0 + 1 } ?? tabs.count
  }

  /// 初出順の安定分割（不変条件の正規化）。隣接済みの配列はそのまま返る。
  static func grouped(_ tabs: [TerminalTab]) -> [TerminalTab] {
    var order: [String] = []
    var buckets: [String: [TerminalTab]] = [:]
    for tab in tabs {
      if buckets[tab.groupKey] == nil { order.append(tab.groupKey) }
      buckets[tab.groupKey, default: []].append(tab)
    }
    return order.flatMap { buckets[$0] ?? [] }
  }

  // MARK: - 変異

  /// cd 再判定。`tab.groupKey` が変わった後に呼ぶ。不変条件が破れているときだけ動かし、動かしたら
  /// その workspace index、動かさなかった・tab がどの workspace にも無い（閉鎖直後の遅延 OSC 7）なら
  /// nil。破れ = ①同キーのタブが他所にあるのに隣接していない ②左右の隣が同じ別キー（連を割っている）。
  /// 移動先 = ①ならその連の右端 ②ならその連の直右（両方成立なら①）。背景 workspace のタブも扱う。
  @discardableResult func regroup(_ tab: TerminalTab) -> Int? {
    guard
      let wsIndex = workspaces.firstIndex(where: { ws in ws.tabs.contains { $0 === tab } })
    else { return nil }
    let ws = workspaces[wsIndex]
    guard let idx = ws.tabs.firstIndex(where: { $0 === tab }) else { return nil }
    let key = tab.groupKey
    let left = idx > 0 ? ws.tabs[idx - 1] : nil
    let right = idx + 1 < ws.tabs.count ? ws.tabs[idx + 1] : nil
    let attached = left?.groupKey == key || right?.groupKey == key
    let strayPeer = !attached && ws.tabs.contains { $0 !== tab && $0.groupKey == key }
    let splitting = !attached && left != nil && right != nil && left?.groupKey == right?.groupKey
    guard strayPeer || splitting else { return nil }
    let activeTab = ws.tabs.indices.contains(ws.active) ? ws.tabs[ws.active] : nil
    ws.tabs.remove(at: idx)
    // ②の `idx - 1` は除去前 index を除去後配列に当てている——左隣は除去で動かないので同じ位置。
    // `idx > 0` は `splitting` の `left != nil` が含意する（不変条件は大域的に SessionStore が保証する建前）。
    let dest =
      strayPeer
      ? Self.insertionIndex(forKey: key, in: ws.tabs)
      : Self.segment(containing: idx - 1, in: ws.tabs).upperBound
    ws.tabs.insert(tab, at: dest)
    if let activeTab, let i = ws.tabs.firstIndex(where: { $0 === activeTab }) { ws.active = i }
    return wsIndex
  }

  /// `from` を含む連を丸ごと、挿入先 `to`（挿入前 index 基準・0 か各連の upperBound＝セグメント境界）
  /// へ移動する。境界でない・範囲外・自連の両端（実移動なし）は false。active は参照で引き直す。
  @discardableResult func moveSegment(containing from: Int, to: Int) -> Bool {
    let tabs = current.tabs
    guard tabs.indices.contains(from), (0...tabs.count).contains(to) else { return false }
    let r = Self.segment(containing: from, in: tabs)
    guard to == 0 || Self.segments(of: tabs).contains(where: { $0.upperBound == to }) else {
      return false
    }
    guard to != r.lowerBound, to != r.upperBound else { return false }
    let dest = to > r.upperBound ? to - r.count : to
    let ws = current
    let activeTab = ws.tabs.indices.contains(ws.active) ? ws.tabs[ws.active] : nil
    let moved = Array(ws.tabs[r])
    ws.tabs.removeSubrange(r)
    ws.tabs.insert(contentsOf: moved, at: dest)
    if let activeTab, let idx = ws.tabs.firstIndex(where: { $0 === activeTab }) {
      ws.active = idx
    }
    return true
  }
}
