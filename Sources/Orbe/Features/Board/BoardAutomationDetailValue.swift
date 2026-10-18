import Foundation

/// 地図の点とカードの頭の点の見え方。
enum BoardNodeLook: Equatable {
  case idle
  /// 最新の回が失敗。
  case failed
  /// 走っている（点の代わりに回る輪）。
  case running
}

/// 地図の部品の行。文言まで解いた値。
struct BoardMapPart: Equatable {
  let key: String
  /// 役割の名前（「取得」「判定」）。
  let role: String
  let name: String
  /// 予定の札（「30分ごと」「手動」「届いたら」）。
  let schedule: String
  /// 予定が「届いたら」か（札を沈める）。
  let arrival: Bool
  /// 入力の部品の名前（「A・B」）。入力の無い部品は nil。
  let inputs: String?
  /// 溜まりの件数。入力のある部品だけ。
  let inbox: Int?
  /// 出力が決まりを外した印があるか。
  let breached: Bool
  let look: BoardNodeLook
  /// 前回の列（「新しい 2 / 18」「失敗」「実行中…」「–」）。
  let last: String
  let lastShade: BoardRunShade
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
}

/// 地図の 1 行。部品の行に続けて、Orbe への終わりの行（タスク候補・報告。その行き先の部品がある分だけ）が並ぶ。
struct BoardMapRow: Equatable {
  enum Content: Equatable {
    case part(BoardMapPart)
    /// `open` はこの自動化の棚に出ている判断待ちの候補の数。
    case taskCandidates(open: Int)
    case report
  }

  let content: Content
  let lanes: BoardMapLanes
}

/// 選んだ自動化の詳細の値（見出し・地図・実行履歴・帯）。地図は部品を入力の深さ順（同じ深さは定義の順）に 1 行ずつ並べ、
/// 溝の線で入力のつながりを `git log --graph` の流儀で描く。実行履歴は全部品の回を新しい順に混ぜる。
struct BoardAutomationDetailValue: Equatable {
  /// 見出しの前回（「前回 今日 16:40　判定: 2件をタスク候補に追加」）。
  let last: String
  /// 見出しの注記（採用・見送りの累計・通知の設定）。
  let notes: [String]
  let rows: [BoardMapRow]
  /// 溝の線の本数（自動化ごと。溝の幅はこれで決まる）。
  let laneCount: Int
  let partCount: Int
  /// 新しい順。
  let runs: [BoardRunLine]
  /// 帯（畳んだ後の直近 `stripLength` 行）。古い行が左。
  let strip: [BoardRunTone]

  static let stripLength = 20
}

extension BoardAutomationDetailValue {
  /// `running` は部品が走っているか、`open` はこの自動化の棚に出ている判断待ちの候補の数。
  init(
    _ automation: Automation, text: AutomationText, running: (String) -> Bool, open: Int
  ) {
    let l10n = text.l10n
    let graph = automation.graph
    let names = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.key, $0.part.name) })
    let ordered = graph.byDepth
    let judges = graph.judges.map(\.key)
    let reports = graph.nodes.filter { $0.part.destination == .report }.map(\.key)

    var plans = ordered.map { node in
      let continues: Bool
      switch node.part.destination {
      case .nextPart, .taskCandidates, .report: continues = true
      case .sideEffect: continues = false
      }
      return BoardMapLayout.Row(key: node.key, inputs: node.part.inputs, continues: continues)
    }
    if !judges.isEmpty {
      plans.append(.init(key: Self.taskCandidatesKey, inputs: judges, continues: false))
    }
    if !reports.isEmpty {
      plans.append(.init(key: Self.reportKey, inputs: reports, continues: false))
    }
    let layout = BoardMapLayout(plans)
    laneCount = layout.laneCount

    var rows = zip(ordered, layout.lanes).map { node, lanes in
      BoardMapRow(
        content: .part(Self.part(node, in: automation, text: text, running: running(node.key))),
        lanes: lanes)
    }
    var ends = layout.lanes.dropFirst(ordered.count).makeIterator()
    if !judges.isEmpty, let lanes = ends.next() {
      rows.append(BoardMapRow(content: .taskCandidates(open: open), lanes: lanes))
    }
    if !reports.isEmpty, let lanes = ends.next() {
      rows.append(BoardMapRow(content: .report, lanes: lanes))
    }
    self.rows = rows
    partCount = graph.nodes.count

    var notes: [String] = []
    if automation.judges {
      notes.append(
        l10n.format(.boardOutputTally, automation.tally.accepted, automation.tally.dismissed))
    }
    if let notify = automation.notify {
      notes.append(l10n.format(.boardOutputNotify, l10n.string(notify.labelKey)))
    }
    self.notes = notes

    let keyed = automation.runs
    runs = BoardAutomationSummary.lines(keyed, name: { names[$0] ?? $0 }, text: text)
    strip = runs.prefix(Self.stripLength).reversed().map(\.tone)
    if let latest = keyed.first {
      last = l10n.format(
        .boardAutomationLast, text.moment(latest.run.startedAt),
        (names[latest.part] ?? latest.part) + ": "
          + BoardAutomationSummary.heading(latest.run, text: text))
    } else {
      last = l10n.string(.automationNeverRan)
    }
  }

  /// 地図の部品の行。
  private static func part(
    _ node: AutomationGraph.Node, in automation: Automation, text: AutomationText, running: Bool
  ) -> BoardMapPart {
    let l10n = text.l10n
    let state = automation.state(node.key)
    let latest = state.runs.first
    let look: BoardNodeLook = running ? .running : latest?.failed == true ? .failed : .idle
    let last: (text: String, shade: BoardRunShade) =
      if running {
        (l10n.string(.automationRunning), .running)
      } else if let latest {
        BoardAutomationSummary.brief(latest, text: text)
      } else {
        ("–", .sunk)
      }
    let inputs = node.part.inputs
    return BoardMapPart(
      key: node.key, role: text.role(node.role), name: node.part.name,
      schedule: text.schedule(node.part.trigger), arrival: node.part.trigger == .arrival,
      inputs: inputs.isEmpty
        ? nil
        : inputs.map { automation.graph.node($0)?.part.name ?? $0 }.joined(
          separator: l10n.string(.automationListSeparator)),
      inbox: inputs.isEmpty ? nil : state.inbox, breached: state.breach != nil, look: look,
      last: last.text, lastShade: last.shade)
  }

  /// 終わりの行の鍵（部品の鍵は空でないので、空の鍵と区切りの文字は部品と重ならない）。
  private static let taskCandidatesKey = "\u{0}taskCandidates"
  private static let reportKey = "\u{0}report"
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
