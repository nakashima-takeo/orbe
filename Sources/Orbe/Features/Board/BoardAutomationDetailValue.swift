import Foundation

/// 地図の部品の点の見え方。
enum BoardNodeLook: Equatable {
  case idle
  /// 最新の回が失敗。
  case failed
  /// 走っている（点の代わりに回る輪）。
  case running
}

/// 地図の部品の行。文言まで解いた値。
struct BoardMapNode: Equatable {
  let id: AutomationNodeID
  /// 役割の名前（「取得」「判定」）。
  let role: String
  let name: String
  /// 予定の札（「30分ごと」「手動」）。前の部品に連動する部品は札を持たない。
  let schedule: String?
  /// 入力の部品の名前（「A・B」）。入力の無い部品は nil。
  let inputs: String?
  /// 未処理の件数。入力のある部品だけ。
  let pending: Int?
  /// 出力の形式エラーの印があるか。
  let breached: Bool
  let look: BoardNodeLook
  /// 前回の列。まだ動いていなければ nil。
  let last: Last?
  /// 最新の回が失敗なら、その理由（「日本語（原文）」）。行の下に出す。
  let failure: String?

  struct Last: Equatable {
    let mark: BoardRunMark
    /// 「16:40」「昨日 23:00」。
    let at: String
    /// 「新着 2 件」「1 件を出力」「候補 2 件」「失敗」。報告・作業・外部操作は量を言わない。
    let amount: (text: String, shade: BoardRunShade)?

    static func == (a: Last, b: Last) -> Bool {
      a.mark == b.mark && a.at == b.at && a.amount?.text == b.amount?.text
        && a.amount?.shade == b.amount?.shade
    }
  }
}

/// 地図の 1 行の溝の線。番号は左からの線の位置。
struct BoardMapLanes: Equatable {
  /// 点を置く線。
  let node: Int
  /// 点の線が上から点へ届く（この行で最後の受け手を迎える入力）。
  let fromAbove: Bool
  /// 点から下へ続く（出力を受ける行が下にある）。
  let below: Bool
  /// 上から点へ曲がり込む線（点の線を除く入力の線）。
  let bends: [Int]
  /// 上から下まで通る線（曲がり込みつつ下の受け手へも続く線を含む）。
  let through: [Int]

  /// この行の下へ続く線（行の下に足す理由の行は、これをそのまま縦に続ける）。
  var continuing: [Int] { (through + (below ? [node] : [])).sorted() }
}

/// 地図の 1 行。部品の行に続けて、出力先の行（タスク候補・報告の出し先。その出力先の部品がある分だけ）が並ぶ。
struct BoardMapRow: Equatable {
  enum Content: Equatable {
    case node(BoardMapNode)
    /// `open` はこの自動化の棚に出ている判断待ちの候補の数。
    case taskCandidates(open: Int)
    /// 報告と作業の文の出し先（「メニューバー」）。
    case reports(String)
  }

  let content: Content
  let lanes: BoardMapLanes
}

/// 選んだ自動化の詳細の値（見出し・帯・地図）。地図は部品を入力の深さ順（同じ深さは定義の順）に 1 行ずつ並べ、溝の線で
/// 入力のつながりを `git log --graph` の流儀で描く。
struct BoardAutomationDetailValue: Equatable {
  /// 「通知：メニューバー」。
  let notify: String
  /// 「次回 16:50」「手動」。止めていれば nil（見出しは一時停止中を出す）。
  let next: String?
  /// 直近の回の区分（全部品を混ぜた新しい `stripLength` 回。古い回が左）。
  let strip: [BoardRunTone]
  let rows: [BoardMapRow]
  /// 溝の線の本数（自動化ごと。溝の幅はこれで決まる）。
  let laneCount: Int
  let nodeCount: Int

  static let stripLength = 20
}

extension BoardAutomationDetailValue {
  /// `running` は部品が走っているか、`open` はこの自動化の棚に出ている判断待ちの候補の数、`next` は次に予定で回る時刻。
  init(
    _ automation: Automation, text: AutomationText, running: (AutomationNodeID) -> Bool, open: Int,
    next: Date?
  ) {
    let l10n = text.l10n
    let graph = automation.graph
    let ordered = graph.byDepth
    let judges = graph.judges.map { "\($0.id)" }
    let reports = graph.nodes.filter { $0.action.destination == .report }.map { "\($0.id)" }

    var plans = ordered.map { node in
      BoardMapLayout.Row(
        key: "\(node.id)", inputs: node.inputNodeIds.map { "\($0)" },
        continues: node.action.destination != .sideEffect)
    }
    if !judges.isEmpty {
      plans.append(.init(key: Self.taskCandidatesKey, inputs: judges, continues: false))
    }
    if !reports.isEmpty {
      plans.append(.init(key: Self.reportsKey, inputs: reports, continues: false))
    }
    let layout = BoardMapLayout(plans)
    laneCount = layout.laneCount

    var rows = zip(ordered, layout.lanes).map { node, lanes in
      BoardMapRow(
        content: .node(Self.mapNode(node, in: automation, text: text, running: running(node.id))),
        lanes: lanes)
    }
    var ends = layout.lanes.dropFirst(ordered.count).makeIterator()
    if !judges.isEmpty, let lanes = ends.next() {
      rows.append(BoardMapRow(content: .taskCandidates(open: open), lanes: lanes))
    }
    if !reports.isEmpty, let lanes = ends.next() {
      rows.append(
        BoardMapRow(content: .reports(Self.reports(automation.notify, l10n)), lanes: lanes))
    }
    self.rows = rows
    nodeCount = graph.nodes.count
    notify = l10n.format(
      .boardNotifyLine, l10n.string(automation.notify?.labelKey ?? .boardNotifyNone))
    let summary = BoardAutomationSummary(automation, text: text, next: next)
    self.next = summary.next
    strip = automation.runs.prefix(Self.stripLength).reversed().map(BoardAutomationSummary.tone)
  }

  /// 報告と作業の文の出し先（「メニューバー」）。役割の名前（報告・作業）は使わない。
  static func reports(_ notify: AutomationNotify?, _ l10n: LocalizationStore) -> String {
    switch notify {
    case .menuBar: l10n.string(.boardOutputMenuBar)
    case .notificationCenter: l10n.string(.boardOutputNotificationCenter)
    case nil: l10n.string(.boardOutputBoard)
    }
  }

  /// 地図の部品の行。
  private static func mapNode(
    _ node: AutomationGraph.Node, in automation: Automation, text: AutomationText, running: Bool
  ) -> BoardMapNode {
    let l10n = text.l10n
    let state = automation.state(node.id)
    let latest = state.runs.first
    let inputs = node.inputNodeIds
    let schedule: String? =
      switch node.entity.trigger {
      case .arrival: nil
      case .scheduled, .manual: text.schedule(node.entity.trigger)
      }
    return BoardMapNode(
      id: node.id, role: text.role(node.role), name: node.entity.name, schedule: schedule,
      inputs: inputs.isEmpty
        ? nil
        : inputs.map { automation.graph.node($0)?.entity.name ?? "\($0)" }.joined(
          separator: l10n.string(.automationListSeparator)),
      pending: inputs.isEmpty ? nil : state.pending.count, breached: state.breach != nil,
      look: running ? .running : latest?.failed == true ? .failed : .idle,
      last: latest.map {
        BoardMapNode.Last(
          mark: $0.failed ? .failure : .success, at: text.recent($0.startedAt),
          amount: $0.run.flatMap { BoardAutomationSummary.amount($0, text: text) })
      },
      failure: latest?.run.flatMap { text.failure($0, node: node) })
  }

  /// 出力先の行の鍵（部品の鍵は空でないので、空の鍵と区切りの文字は部品と重ならない）。
  private static let taskCandidatesKey = "\u{0}taskCandidates"
  private static let reportsKey = "\u{0}reports"
}

/// 地図の溝の線の割り当て。定義だけから決まる純粋な計算。行を上から見て、この行で最後の受け手を迎える入力の線のうち最も
/// 左の線に点を置き、無ければ空いている最も左の線に置く。この行で終わった線は空き、次の行から使える。点の出力を受ける行が
/// 下にあれば、点の線はその行のものとして下へ続く。
struct BoardMapLayout: Equatable {
  struct Row: Equatable {
    let key: String
    /// 上の行の鍵（入力）。
    let inputs: [String]
    /// 出力を受ける行が下にあるか。
    let continues: Bool
  }

  let lanes: [BoardMapLanes]
  let laneCount: Int

  init(_ rows: [Row]) {
    var lastReceiver: [String: Int] = [:]
    for (index, row) in rows.enumerated() {
      for input in row.inputs { lastReceiver[input] = index }
    }
    var owners: [Int: String] = [:]
    var lanes: [BoardMapLanes] = []
    var widest = 0
    for (index, row) in rows.enumerated() {
      let inputs = Set(row.inputs)
      let inputLanes = owners.filter { inputs.contains($0.value) }
      let ending = Set(inputLanes.filter { lastReceiver[$0.value] == index }.keys)
      var node = ending.min() ?? 0
      if ending.isEmpty {
        while owners[node] != nil { node += 1 }
      }
      let through = owners.keys.filter { !ending.contains($0) }.sorted()
      for lane in ending { owners[lane] = nil }
      if row.continues { owners[node] = row.key }
      widest = max(widest, node + 1, (through.last ?? -1) + 1)
      lanes.append(
        BoardMapLanes(
          node: node, fromAbove: ending.contains(node), below: row.continues,
          bends: inputLanes.keys.filter { $0 != node }.sorted(), through: through))
    }
    self.lanes = lanes
    laneCount = widest
  }
}
