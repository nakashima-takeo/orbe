import Foundation

// 回の記録の終わり方・失敗・外れた行・判定の確定で捨てた案。どれも自動化が決めた閉じた種類と、Orbe が組まない文（標準エラーの
// 抜粋・部品の申告の文・CLI のエラー文）だけを値に持つ。保存はこの種類だけで、AI が読む英文（`text`）と画面の日本語
// （`AutomationText`）は同じ種類の 2 つの言い方——英文を保存すると、英文と種類の 2 つの元ができ、AI と画面が別のものを
// 読みうるため。下の層の型（`BackgroundEnding`・`JSONLines.Reason`）は包まず、読みの境界で写す。

/// 手段の終わり方。
enum AutomationEnding: Equatable {
  case exited(Int32)
  case signaled(Int32)
  case timeLimit
  case idleLimit
  case outputLimit
  case stopped
  /// agent の CLI が入っていない（CLI の名前）。
  case agentMissing(String)
  /// 作業ディレクトリが無い。
  case directoryMissing(String)
  /// ほかの理由で起動できなかった（下の層の理由の英文）。
  case notStarted(String)
  /// 指定した MCP のツールが始まりの時点で揃わなかった（揃わなかった名前）。
  case toolsUnavailable([String])
  /// 試走が止めた副作用・作業（手段を起こしていない）。
  case heldByTrial
  /// 試走が外から与えた行を取得の出力にした（手段を起こしていない）。
  case givenToTrial

  init(_ ending: BackgroundEnding) {
    switch ending {
    case .exited(let code): self = .exited(code)
    case .signaled(let signal): self = .signaled(signal)
    case .limited(.elapsed): self = .timeLimit
    case .limited(.idle): self = .idleLimit
    case .limited(.output): self = .outputLimit
    case .stopped: self = .stopped
    case .notStarted(.agentNotFound(let cli)): self = .agentMissing(cli)
    case .notStarted(.directoryMissing(let directory)): self = .directoryMissing(directory)
    case .notStarted(let failure): self = .notStarted(failure.text)
    case .toolsUnavailable(let tools): self = .toolsUnavailable(tools)
    }
  }

  /// AI が読む英文。
  var text: String {
    switch self {
    case .exited(let code): "exited \(code)"
    case .signaled(let signal): "killed by signal \(signal)"
    case .timeLimit: "stopped at the time limit"
    case .idleLimit: "stopped after producing no output for too long"
    case .outputLimit: "stopped at the output limit"
    case .stopped: "stopped"
    case .agentMissing(let cli): "not started (\(cli) is not installed)"
    case .directoryMissing(let directory): "not started (directory missing: \(directory))"
    case .notStarted(let reason): "not started (\(reason))"
    case .toolsUnavailable(let tools): BackgroundEnding.unavailable(tools)
    case .heldByTrial: "held by the trial"
    case .givenToTrial: "rows given to the trial"
    }
  }
}

/// 部品の回の失敗。手段の終わり方による失敗の終わり方は、同じ回の実行の記録が持つ。出力の形式エラーが直らない失敗の外れた行は、
/// 同じ回の出力の形式エラーの記録が持つ。
enum AutomationFailure: Error, Equatable {
  /// 手段が 0 以外で終わった。`detail` は標準エラーか応答の抜粋（無ければ空）。
  case ended(detail: String)
  /// agent が応答を返さずに終わった（`detail` は標準エラーの抜粋）。
  case noReply(detail: String)
  case notUTF8
  /// agent の CLI がエラーを返した（その文の抜粋）。
  case agentError(String)
  /// 部品が `{"error": …}` で失敗を申告した。
  case reported(String)
  /// 出力の形式エラーが出し直しでも直らなかった（コマンドは出し直さない）。
  case brokeRules
  /// 判定（鍵）へ渡す行が、どれも出どころを持たなかった。
  case unsourced(String)

  /// AI が読む英文。`part` はこの回の部品の鍵。
  func text(part: String, ending: AutomationEnding, breach: AutomationPartRun.Breach?) -> String {
    let word = "part \"\(part)\""
    func with(_ head: String, _ detail: String) -> String {
      detail.isEmpty ? head : "\(head): \(detail)"
    }
    switch self {
    case .ended(let detail): return with("the \(word) ended: \(ending.text)", detail)
    case .noReply(let detail): return with("the \(word) ended without a reply", detail)
    case .notUTF8: return "the \(word) output is not UTF-8"
    case .agentError(let text): return "the \(word) agent reported an error: \(text)"
    case .reported(let text): return "the \(word) reported an error: \(text)"
    case .brokeRules:
      let line = breach.flatMap { $0.redo?.lines.lines.first ?? $0.lines.lines.first }
      return "the output of \(word) broke the rules: \(line?.text ?? "")"
    case .unsourced(let target):
      return "no row passed to part \"\(target)\" has an origin (it did not come from a fetch part)"
    }
  }
}

/// 出力の中の、受け付けなかった 1 行。`line` は 1 始まりの行番号（空行も数える）。
struct AutomationBrokenLine: Error, Equatable {
  let line: Int
  let fault: AutomationLineFault

  /// 「line <n>: <理由>」。
  var text: String { "line \(line): \(fault.text)" }
}

/// 行を受け付けなかった理由。
enum AutomationLineFault: Equatable {
  case notJSON
  case notObject
  case missingKey(String)
  case nullValue(String)
  case typeMismatch(String)
  /// 欄が空なら値そのものが正しくない。
  case invalidValue(String)
  /// 同じ id の 2 つ目の行。
  case idTwice(String)
  /// 判定へ届く処理が、入力の行の id でない id の行を出した。
  case notInputId(String)
  /// 何も無い回の申告が項目と一緒に出た。
  case nothingWithItems
  /// 判定の案が新しい項目でない id を指した。
  case notNewItem(String)
  case proposedTwice(String)
  /// 判定の resolve が判断待ちの候補のリンクでない。
  case notWaiting(String)
  /// 判定の行が propose と resolve のちょうど 1 つを持たない。
  case notOneDecision
  case titleNotOneLine(String)
  /// 判定の案の期限が日付でない（id と原文）。
  case dueNotDate(String, String)
  /// 判定の案の付け先が一覧に無い（id と番号）。
  case workspaceNotListed(String, Int)

  init<Item>(_ reason: JSONLines<Item>.Reason) {
    switch reason {
    case .notJSON: self = .notJSON
    case .notObject: self = .notObject
    case .missingKey(let key): self = .missingKey(key)
    case .nullValue(let key): self = .nullValue(key)
    case .typeMismatch(let key): self = .typeMismatch(key)
    case .invalidValue(let key): self = .invalidValue(key)
    }
  }

  /// AI が読む英文。
  var text: String {
    switch self {
    case .notJSON: "not JSON"
    case .notObject: "not a JSON object"
    case .missingKey(let key): "missing \(key)"
    case .nullValue(let key): "\(key) is null"
    case .typeMismatch(let key): "\(key) has the wrong type"
    case .invalidValue(let key): key.isEmpty ? "invalid value" : "invalid \(key)"
    case .idTwice(let id): "id \(id) appeared twice"
    case .notInputId(let id): "id \(id) is not the id of an input item"
    case .nothingWithItems: "a nothing line alongside items"
    case .notNewItem(let id): "propose \(id): not a new item"
    case .proposedTwice(let id): "propose \(id): proposed twice"
    case .notWaiting(let link): "resolve \(link): not a waiting proposal"
    case .notOneDecision: "a line must have exactly one of propose / resolve"
    case .titleNotOneLine(let id): "propose \(id): title must be a single non-empty line"
    case .dueNotDate(let id, let raw): "propose \(id): due is not a YYYY-MM-DD date: \(raw)"
    case .workspaceNotListed(let id, let number):
      "propose \(id): workspace \(number) is not a listed workspace"
    }
  }
}

/// 判定の確定で、この時点の候補と合わずに捨てた案（出力の決まりは守っていた）。
struct AutomationDismissal: Equatable {
  let link: String
  let why: Why

  enum Why: String, Codable {
    /// 同じリンクの候補が既にある。
    case alreadyProposed
    /// 対応済みにする判断待ちの候補が無い。
    case noOpenProposal
  }

  /// AI が読む英文。
  var text: String {
    switch why {
    case .alreadyProposed: "propose \(link): already proposed"
    case .noOpenProposal: "resolve \(link): no open proposal"
    }
  }
}

// MARK: - JSON（保存の形）

/// `{"kind": "exited", "code": 1}` の形。
extension AutomationEnding: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, code, signal, cli, directory, reason, tools
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .kind) {
    case "exited": self = .exited(try c.decode(Int32.self, forKey: .code))
    case "signaled": self = .signaled(try c.decode(Int32.self, forKey: .signal))
    case "timeLimit": self = .timeLimit
    case "idleLimit": self = .idleLimit
    case "outputLimit": self = .outputLimit
    case "stopped": self = .stopped
    case "agentMissing": self = .agentMissing(try c.decode(String.self, forKey: .cli))
    case "directoryMissing":
      self = .directoryMissing(try c.decode(String.self, forKey: .directory))
    case "notStarted": self = .notStarted(try c.decode(String.self, forKey: .reason))
    case "toolsUnavailable": self = .toolsUnavailable(try c.decode([String].self, forKey: .tools))
    case "heldByTrial": self = .heldByTrial
    case "givenToTrial": self = .givenToTrial
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: c, debugDescription: "unknown ending kind")
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .exited(let code):
      try c.encode("exited", forKey: .kind)
      try c.encode(code, forKey: .code)
    case .signaled(let signal):
      try c.encode("signaled", forKey: .kind)
      try c.encode(signal, forKey: .signal)
    case .timeLimit: try c.encode("timeLimit", forKey: .kind)
    case .idleLimit: try c.encode("idleLimit", forKey: .kind)
    case .outputLimit: try c.encode("outputLimit", forKey: .kind)
    case .stopped: try c.encode("stopped", forKey: .kind)
    case .agentMissing(let cli):
      try c.encode("agentMissing", forKey: .kind)
      try c.encode(cli, forKey: .cli)
    case .directoryMissing(let directory):
      try c.encode("directoryMissing", forKey: .kind)
      try c.encode(directory, forKey: .directory)
    case .notStarted(let reason):
      try c.encode("notStarted", forKey: .kind)
      try c.encode(reason, forKey: .reason)
    case .toolsUnavailable(let tools):
      try c.encode("toolsUnavailable", forKey: .kind)
      try c.encode(tools, forKey: .tools)
    case .heldByTrial: try c.encode("heldByTrial", forKey: .kind)
    case .givenToTrial: try c.encode("givenToTrial", forKey: .kind)
    }
  }
}

/// `{"kind": "ended", "detail"?: "…"}` の形。空の抜粋は書かない。
extension AutomationFailure: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, detail, text, part
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    switch try c.decode(String.self, forKey: .kind) {
    case "ended": self = .ended(detail: detail)
    case "noReply": self = .noReply(detail: detail)
    case "notUTF8": self = .notUTF8
    case "agentError": self = .agentError(try c.decode(String.self, forKey: .text))
    case "reported": self = .reported(try c.decode(String.self, forKey: .text))
    case "brokeRules": self = .brokeRules
    case "unsourced": self = .unsourced(try c.decode(String.self, forKey: .part))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: c, debugDescription: "unknown failure kind")
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .ended(let detail):
      try c.encode("ended", forKey: .kind)
      if !detail.isEmpty { try c.encode(detail, forKey: .detail) }
    case .noReply(let detail):
      try c.encode("noReply", forKey: .kind)
      if !detail.isEmpty { try c.encode(detail, forKey: .detail) }
    case .notUTF8: try c.encode("notUTF8", forKey: .kind)
    case .agentError(let text):
      try c.encode("agentError", forKey: .kind)
      try c.encode(text, forKey: .text)
    case .reported(let text):
      try c.encode("reported", forKey: .kind)
      try c.encode(text, forKey: .text)
    case .brokeRules: try c.encode("brokeRules", forKey: .kind)
    case .unsourced(let part):
      try c.encode("unsourced", forKey: .kind)
      try c.encode(part, forKey: .part)
    }
  }
}

/// `{"line": 3, "kind": "missingKey", "key": "link"}` の形。
extension AutomationBrokenLine: Codable {
  private enum CodingKeys: String, CodingKey {
    case line, kind, key, id, link, raw, workspace
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    func string(_ key: CodingKeys) throws -> String { try c.decode(String.self, forKey: key) }
    let fault: AutomationLineFault
    switch try string(.kind) {
    case "notJSON": fault = .notJSON
    case "notObject": fault = .notObject
    case "missingKey": fault = .missingKey(try string(.key))
    case "nullValue": fault = .nullValue(try string(.key))
    case "typeMismatch": fault = .typeMismatch(try string(.key))
    case "invalidValue": fault = .invalidValue(try string(.key))
    case "idTwice": fault = .idTwice(try string(.id))
    case "notInputId": fault = .notInputId(try string(.id))
    case "nothingWithItems": fault = .nothingWithItems
    case "notNewItem": fault = .notNewItem(try string(.id))
    case "proposedTwice": fault = .proposedTwice(try string(.id))
    case "notWaiting": fault = .notWaiting(try string(.link))
    case "notOneDecision": fault = .notOneDecision
    case "titleNotOneLine": fault = .titleNotOneLine(try string(.id))
    case "dueNotDate": fault = .dueNotDate(try string(.id), try string(.raw))
    case "workspaceNotListed":
      fault = .workspaceNotListed(try string(.id), try c.decode(Int.self, forKey: .workspace))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: c, debugDescription: "unknown line fault")
    }
    self.init(line: try c.decode(Int.self, forKey: .line), fault: fault)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(line, forKey: .line)
    func kind(_ name: String, _ values: [(CodingKeys, String)] = []) throws {
      try c.encode(name, forKey: .kind)
      for (key, value) in values { try c.encode(value, forKey: key) }
    }
    switch fault {
    case .notJSON: try kind("notJSON")
    case .notObject: try kind("notObject")
    case .missingKey(let key): try kind("missingKey", [(.key, key)])
    case .nullValue(let key): try kind("nullValue", [(.key, key)])
    case .typeMismatch(let key): try kind("typeMismatch", [(.key, key)])
    case .invalidValue(let key): try kind("invalidValue", [(.key, key)])
    case .idTwice(let id): try kind("idTwice", [(.id, id)])
    case .notInputId(let id): try kind("notInputId", [(.id, id)])
    case .nothingWithItems: try kind("nothingWithItems")
    case .notNewItem(let id): try kind("notNewItem", [(.id, id)])
    case .proposedTwice(let id): try kind("proposedTwice", [(.id, id)])
    case .notWaiting(let link): try kind("notWaiting", [(.link, link)])
    case .notOneDecision: try kind("notOneDecision")
    case .titleNotOneLine(let id): try kind("titleNotOneLine", [(.id, id)])
    case .dueNotDate(let id, let raw): try kind("dueNotDate", [(.id, id), (.raw, raw)])
    case .workspaceNotListed(let id, let number):
      try kind("workspaceNotListed", [(.id, id)])
      try c.encode(number, forKey: .workspace)
    }
  }
}

/// `{"link": "…", "why": "alreadyProposed"}` の形。
extension AutomationDismissal: Codable {}
