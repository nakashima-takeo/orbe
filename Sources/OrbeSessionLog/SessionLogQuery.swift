import Foundation

/// 同じ事故で閉じた同一性の群。`at` は群の最初（最古）の closed の `ts` で、群の一部を復元しても動かない。
public struct SessionBurst: Equatable {
  public var at: Date
  public var origin: SessionEvent.CloseOrigin
  public var sessions: [SessionEvent]

  public init(at: Date, origin: SessionEvent.CloseOrigin, sessions: [SessionEvent]) {
    self.at = at
    self.origin = origin
    self.sessions = sessions
  }

  /// 群の同一性を文字列で引くための wire 形（`orb session restore --at` はこれと完全一致で解く）。
  public var atISO: String { SessionEvent.iso8601(at) }
}

/// ログからの派生（純関数）。`orb session closed` / `restore --at` と ⇧⌘T パレットが共用する。
public enum SessionLogQuery {
  /// 同じ origin の closed をこの秒数以内で 1 群にまとめる。
  public static let burstWindow: TimeInterval = 5

  /// sessionId ごとの最後のイベントが closed で、かつ `present`（今 Orbe に居る id）に無いもの。
  /// ファイル順（昇順）。
  public static func closedNotPresent(events: [SessionEvent], present: Set<String>)
    -> [SessionEvent]
  {
    lastEvents(events).compactMap { entry in
      guard entry.event.closeOrigin != nil, !present.contains(entry.event.sessionId) else {
        return nil
      }
      return entry.event
    }
  }

  /// closed だけを受け取り `ts` 昇順に走査して群を切る。gesture は常に単独。それ以外は直前と同じ origin
  /// で `window` 秒以内に続くものを同じ群にする。同時刻の closed は入力順（ファイル順）を保つ。
  public static func bursts(_ closed: [SessionEvent], window: TimeInterval = burstWindow)
    -> [SessionBurst]
  {
    var out: [SessionBurst] = []
    let ordered = closed.enumerated()
      .sorted { ($0.element.ts, $0.offset) < ($1.element.ts, $1.offset) }
      .map(\.element)
    for event in ordered {
      guard let origin = event.closeOrigin else { continue }
      if origin != .gesture, let last = out.last, last.origin == origin,
        let tail = last.sessions.last, event.ts.timeIntervalSince(tail.ts) <= window
      {
        out[out.count - 1].sessions.append(event)
      } else {
        out.append(SessionBurst(at: event.ts, origin: origin, sessions: [event]))
      }
    }
    return out
  }

  /// 「閉じたまま戻っていない」群。全 closed で群を切ってから、各メンバーを「その closed がその id の
  /// 最後のイベントで、かつ present に無い」で残し、空の群を落とす。
  public static func closedGroups(
    events: [SessionEvent], present: Set<String>, window: TimeInterval = burstWindow
  ) -> [SessionBurst] {
    let gone = closedNotPresent(events: events, present: present)
    let keep = Dictionary(gone.map { ($0.sessionId, $0) }, uniquingKeysWith: { _, last in last })
    return bursts(events.filter { $0.closeOrigin != nil }, window: window).compactMap { burst in
      let sessions = burst.sessions.filter { keep[$0.sessionId] == $0 }
      guard !sessions.isEmpty else { return nil }
      return SessionBurst(at: burst.at, origin: burst.origin, sessions: sessions)
    }
  }

  private static func lastEvents(_ events: [SessionEvent]) -> [(index: Int, event: SessionEvent)] {
    var last: [String: (index: Int, event: SessionEvent)] = [:]
    for (index, event) in events.enumerated() { last[event.sessionId] = (index, event) }
    return last.values.sorted { $0.index < $1.index }
  }
}
