import Foundation

/// ノードの 1 回の結果を、1 度に出した分ずつ確かめて溜める。agent は Orbe の MCP の道具で何度かに分けて、コマンドは標準出力で
/// 1 度に出す——どちらも同じ決まりで確かめ、1 度に出した分（1 件 1 つの JSON。道具の 1 件はここで 1 行にする）は全部受けるか
/// 全部断る。一部だけ受けると、外れた分が黙って落ちるため。
struct AutomationOutputs {
  /// 下流へ渡す行 1 つと、報告・仕事の文の大きさの上限（KiB）。行は下流へ渡す形の UTF-8 のバイト、文は前後の空白を除いた
  /// UTF-8 のバイトで測る（文は下流へ渡らず、回の記録とカードに全文で出る）。行を見る agent は行を Orbe の口
  /// （`read_run_rows`）で読み、claude は道具の 1 回の結果が閾値（Orbe の口は 500,000 字に上げてある）を超えるとファイルに
  /// 書き出して agent に見せないので、どの行も 1 ページで届く大きさにする。claude は結果を復号後の文字（UTF-16 の単位）で数え、
  /// その数は UTF-8 のバイト数を超えないので、上限は閾値より十分小さく取ってある。
  static let rowKiB = 64

  let input: AutomationNodePass.Input
  /// 行を出すノード（下流へ渡す id の接頭）。
  let writer: AutomationNodeID
  /// 受けた行（取得・処理）。取得は書かれた id と書かれたままの 1 行（余分な欄も残す）、処理は入力と `id` で照らせた行だけが
  /// その入力を引き継ぐ。
  private(set) var rows: [AutomationNodeRow] = []
  /// 判定の案と、対応済みにする判断待ちの候補のリンク。
  private(set) var proposals: [AutomationNodePass.Proposal] = []
  private(set) var resolved: [String] = []
  /// 報告・仕事の文。
  private(set) var report: String?
  private var ids = Set<String>()
  private var judgeSeen = JudgeSeen()

  init(_ input: AutomationNodePass.Input, writer: AutomationNodeID) {
    self.input = input
    self.writer = writer
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
    case .process(let input, _): broken = next.processed(text, input)
    case .judge(let input, let choices): broken = next.judged(text, shape, input, choices)
    case .report, .work, .sideEffect:
      preconditionFailure("only a node that passes rows on puts rows")
    }
    if broken.isEmpty { self = next }
    return broken
  }

  /// 報告・仕事の文。前後の空白を除いて受ける。空なら受けず、大きさの上限を超えれば外れた件（位置無し）を返して受けない。出し直した
  /// 報告は前の報告を置き換える——報告は 1 つの文なので、直した中身を受ける。
  mutating func putReport(_ text: String) -> AutomationBrokenLine? {
    guard let trimmed = Self.trimmedReport(text) else { return nil }
    guard trimmed.utf8.count <= Self.rowKiB << 10 else {
      return AutomationBrokenLine(line: nil, fault: .tooLarge)
    }
    report = trimmed
    return nil
  }

  /// 受けたものからの結果。`nothing` は何も無い回の理由（仕事の「何もしなかった」に使う）。
  func output(nothing: String?) -> AutomationNodePass.Output {
    switch input {
    case .fetch: .fetch(rows)
    case .process: .process(rows)
    case .judge: .judge(proposals: proposals, resolved: resolved)
    case .report: .report(report)
    case .work: report.map { .work(.done($0)) } ?? .work(.nothing(nothing ?? ""))
    case .sideEffect: .sideEffect
    }
  }

  /// 前後の空白を除いた報告の文。空なら nil。
  static func trimmedReport(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  // MARK: - 役割ごとの確かめ

  /// 項目として読めない件と、同じ `id` の 2 つ目（前に受けた分との重なりも）は外れた件。
  private mutating func fetched(_ text: String) -> [AutomationBrokenLine] {
    let read = JSONLines<AutomationItem>(text)
    var broken = read.rejected.map {
      AutomationBrokenLine(line: $0.line, fault: AutomationLineFault($0.reason))
    }
    for accepted in read.accepted {
      guard fits(accepted.text, id: accepted.item.id, inherited: false) else {
        broken.append(AutomationBrokenLine(line: accepted.line, fault: .tooLarge))
        continue
      }
      guard ids.insert(accepted.item.id).inserted else {
        broken.append(AutomationBrokenLine(line: accepted.line, fault: .idTwice(accepted.item.id)))
        continue
      }
      rows.append(
        AutomationNodeRow(id: accepted.item.id, text: accepted.text, ref: nil, source: nil))
    }
    return broken.sorted { ($0.line ?? 0) < ($1.line ?? 0) }
  }

  /// `id` の無い件・同じ `id` の 2 つ目は外れた件。
  private mutating func processed(_ text: String, _ input: [AutomationNodeRow])
    -> [AutomationBrokenLine]
  {
    var (objects, broken) = Self.objectRows(text)
    let inputs = Dictionary(input.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    for object in objects {
      guard let id = AutomationPrompts.id(of: object.text) else {
        broken.append(AutomationBrokenLine(line: object.line, fault: .missingKey("id")))
        continue
      }
      guard fits(object.text, id: id, inherited: inputs[id]?.source != nil) else {
        broken.append(AutomationBrokenLine(line: object.line, fault: .tooLarge))
        continue
      }
      guard ids.insert(id).inserted else {
        broken.append(AutomationBrokenLine(line: object.line, fault: .idTwice(id)))
        continue
      }
      rows.append(
        AutomationNodeRow(id: id, text: object.text, ref: nil, source: inputs[id]?.source))
    }
    return broken.sorted { ($0.line ?? 0) < ($1.line ?? 0) }
  }

  /// 案は取った行の `id` を指し、その行が http か https の URL の `link` を持つものだけを受け、指した行とその欄を付ける。
  private mutating func judged(
    _ text: String, _ shape: JudgeShape, _ input: [AutomationNodeRow],
    _ choices: AutomationJudgeChoices
  ) -> [AutomationBrokenLine] {
    let (objects, malformed) = Self.objectRows(text)
    let rows = Dictionary(input.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    var broken = malformed
    for (object, reading) in zip(
      objects,
      Self.judgeRows(objects, shape, itemIds: Set(rows.keys), choices: choices, seen: &judgeSeen))
    {
      switch reading {
      case .success(.propose(let itemId, let title, let due, let workspace, let reason)):
        guard let row = rows[itemId], let ref = row.ref else {
          preconditionFailure("an accepted proposal points at one of the rows read")
        }
        guard let fields = AutomationRowFields(row: row.text) else {
          broken.append(AutomationBrokenLine(line: object.line, fault: .noLink(itemId)))
          continue
        }
        proposals.append(
          AutomationNodePass.Proposal(
            id: itemId, row: ref, fields: fields, title: title, due: due, workspace: workspace,
            reason: reason))
      case .success(.resolve(let link)):
        resolved.append(link)
      case .failure(let line):
        broken.append(line)
      }
    }
    return broken.sorted { ($0.line ?? 0) < ($1.line ?? 0) }
  }

  /// 書かれた 1 行が、下流へ渡す形（Orbe が下流へ渡す id を入れて組み直した 1 行）で大きさの上限に収まるか。`inherited` は
  /// 入力を引き継いだ行（id をそのまま渡す）。
  private func fits(_ text: String, id: String, inherited: Bool) -> Bool {
    let downstream = AutomationDatabase.downstreamId(id, of: writer, inherited: inherited)
    return AutomationPrompts.replacing(id: downstream, in: text).utf8.count <= Self.rowKiB << 10
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
