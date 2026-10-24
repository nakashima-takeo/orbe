import Foundation

/// 部品の 1 回の結果を、1 度に出した分ずつ確かめて溜める。agent は Orbe の MCP の道具で何度かに分けて、コマンドは標準出力で
/// 1 度に出す——どちらも同じ決まりで確かめ、1 度に出した分（1 件 1 つの JSON。道具の 1 件はここで 1 行にする）は全部受けるか
/// 全部断る。一部だけ受けると、外れた分が黙って落ちるため。
struct AutomationOutputs {
  /// 残す報告・仕事の文の上限（字）。回の記録は部品ごとに 20 回残る。
  static let reportLimit = 2000
  /// 下流へ渡す行 1 つの大きさの上限（UTF-8 のバイト、KiB）。行を見る agent は行を Orbe の口（`read_run_rows`）で読み、claude
  /// は道具の 1 回の結果が閾値（Orbe の口は 500,000 字に上げてある）を超えるとファイルに書き出して agent に見せないので、
  /// どの行も 1 ページで届く大きさにする。上限は閾値から返事の頭と JSON の逃がしの膨らみ（最大 6 倍）を引いて余裕を持たせた値。
  static let rowKiB = 64

  let input: AutomationPartPass.Input
  /// 受けた行（取得・処理）。取得は書かれた id と書かれたままの 1 行（余分な欄も残す）、処理は入力と `id` で照らせた行だけが
  /// その入力を引き継ぎ、出どころも引き継ぐ。
  private(set) var rows: [AutomationPartRow] = []
  /// 判定の案と、対応済みにする判断待ちの候補のリンク。
  private(set) var proposals: [AutomationPartPass.Proposal] = []
  private(set) var resolved: [String] = []
  /// 報告・仕事の文。
  private(set) var report: String?
  private var ids = Set<String>()
  private var judgeSeen = JudgeSeen()

  init(_ input: AutomationPartPass.Input) {
    self.input = input
  }

  /// 受けた件数——取得は項目、処理・判定は行、報告・仕事は文があれば 1。
  var count: Int {
    switch input {
    case .fetch, .process: rows.count
    case .judge: proposals.count + resolved.count
    case .report, .work: report == nil ? 0 : 1
    case .sideEffect: 0
    }
  }

  /// 行を出す役割（取得・処理・判定）の 1 度の分（1 件 1 行の JSON）。外れた件（`line` は分の中の 1 始まりの位置。空行も
  /// 数える）をすべて返し、1 件でもあれば何も受けない。`judging` は判定の 1 件の形。
  mutating func put(_ text: String, judging shape: JudgeShape = .decisions)
    -> [AutomationBrokenLine]
  {
    var next = self
    let broken: [AutomationBrokenLine]
    switch input {
    case .fetch: broken = next.fetched(text)
    case .process(let input, let reachesJudge):
      broken = next.processed(text, input, reachesJudge: reachesJudge)
    case .judge(let input, let choices): broken = next.judged(text, shape, input, choices)
    case .report, .work, .sideEffect:
      preconditionFailure("only a part that passes rows on puts rows")
    }
    if broken.isEmpty { self = next }
    return broken
  }

  /// 報告・仕事の文。前後の空白を除いて上限で切り（切ったら「…」を付ける）、空なら受けない。出し直した報告は前の報告を
  /// 置き換える——報告は 1 つの文なので、直した中身を受ける。
  mutating func putReport(_ text: String) {
    guard let kept = Self.kept(text) else { return }
    report = kept
  }

  /// 受けたものからの結果。`nothing` は何も無い回の理由（仕事の「何もしなかった」に使う）。
  func output(nothing: String?) -> AutomationPartPass.Output {
    switch input {
    case .fetch: .fetch(rows)
    case .process: .process(rows)
    case .judge: .judge(proposals: proposals, resolved: resolved)
    case .report: .report(report)
    case .work: report.map { .work(.done($0)) } ?? .work(.nothing(nothing ?? ""))
    case .sideEffect: .sideEffect
    }
  }

  static func kept(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed.count > reportLimit ? String(trimmed.prefix(reportLimit)) + "…" : trimmed
  }

  // MARK: - 役割ごとの確かめ

  /// 項目として読めない件と、同じ `id` の 2 つ目（前に受けた分との重なりも）は外れた件。
  private mutating func fetched(_ text: String) -> [AutomationBrokenLine] {
    let read = JSONLines<AutomationItem>(text)
    var broken = read.rejected.map {
      AutomationBrokenLine(line: $0.line, fault: AutomationLineFault($0.reason))
    }
    for accepted in read.accepted {
      guard Self.fits(accepted.text) else {
        broken.append(AutomationBrokenLine(line: accepted.line, fault: .tooLarge))
        continue
      }
      guard ids.insert(accepted.item.id).inserted else {
        broken.append(AutomationBrokenLine(line: accepted.line, fault: .idTwice(accepted.item.id)))
        continue
      }
      rows.append(
        AutomationPartRow(id: accepted.item.id, text: accepted.text, origin: nil, source: nil))
    }
    return broken.sorted { ($0.line ?? 0) < ($1.line ?? 0) }
  }

  /// `id` の無い件・同じ `id` の 2 つ目・判定へ届くときの入力の行の `id` でない件は外れた件。
  private mutating func processed(
    _ text: String, _ input: [AutomationPartRow], reachesJudge: Bool
  ) -> [AutomationBrokenLine] {
    var (objects, broken) = Self.objectRows(text)
    let inputs = Dictionary(input.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    for object in objects {
      guard Self.fits(object.text) else {
        broken.append(AutomationBrokenLine(line: object.line, fault: .tooLarge))
        continue
      }
      guard let id = AutomationPrompts.id(of: object.text) else {
        broken.append(AutomationBrokenLine(line: object.line, fault: .missingKey("id")))
        continue
      }
      guard !reachesJudge || inputs[id] != nil else {
        broken.append(AutomationBrokenLine(line: object.line, fault: .notInputId(id)))
        continue
      }
      guard ids.insert(id).inserted else {
        broken.append(AutomationBrokenLine(line: object.line, fault: .idTwice(id)))
        continue
      }
      rows.append(
        AutomationPartRow(
          id: id, text: object.text, origin: inputs[id]?.origin, source: inputs[id]?.source))
    }
    return broken.sorted { ($0.line ?? 0) < ($1.line ?? 0) }
  }

  /// 案は取った行の `id` を指すものだけを受け、指した行の出どころを付ける。
  private mutating func judged(
    _ text: String, _ shape: JudgeShape, _ input: [AutomationSourcedRow],
    _ choices: AutomationJudgeChoices
  ) -> [AutomationBrokenLine] {
    let (objects, malformed) = Self.objectRows(text)
    let origins = Dictionary(input.map { ($0.id, $0.origin) }, uniquingKeysWith: { $1 })
    var broken = malformed
    for reading in Self.judgeRows(
      objects, shape, itemIds: Set(origins.keys), choices: choices, seen: &judgeSeen)
    {
      switch reading {
      case .success(.propose(let itemId, let title, let due, let workspace, let reason)):
        guard let origin = origins[itemId] else {
          preconditionFailure("an accepted proposal points at one of the rows")
        }
        proposals.append(
          AutomationPartPass.Proposal(
            origin: origin, title: title, due: due, workspace: workspace, reason: reason))
      case .success(.resolve(let link)):
        resolved.append(link)
      case .failure(let line):
        broken.append(line)
      }
    }
    return broken.sorted { ($0.line ?? 0) < ($1.line ?? 0) }
  }

  /// 下流へ渡す行が大きさの上限に収まるか。
  static func fits(_ row: String) -> Bool {
    row.utf8.count <= rowKiB << 10
  }

  /// 1 件 1 行の JSON をオブジェクトとして読む。読めない件はすべて位置と理由で返す。
  static func objectRows(_ text: String) -> (rows: [AutomationRow], broken: [AutomationBrokenLine])
  {
    let lines = JSONLines<AnyObjectLine>(text)
    return (
      lines.accepted.map { AutomationRow(line: $0.line, text: $0.text) },
      lines.rejected.map {
        AutomationBrokenLine(line: $0.line, fault: AutomationLineFault($0.reason))
      }
    )
  }
}

/// 結果の 1 件（JSON オブジェクト）。`line` は 1 度に出した分の中の 1 始まりの位置。
struct AutomationRow: Equatable {
  let line: Int
  let text: String
}

/// どんな JSON オブジェクトも受ける行（オブジェクトかは `JSONLines` が見る）。
private struct AnyObjectLine: Decodable {
  init(from decoder: Decoder) throws {}
}
