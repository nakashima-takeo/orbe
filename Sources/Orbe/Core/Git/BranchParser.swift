import Foundation

/// `git for-each-ref` の出力を `GitBranch` へ落とすパーサ（local / remote）。
/// フィールドの並びはここだけが持ち、`--format=` に渡す形式も読む位置もそこから導く——位置で読む形式は、
/// 片側だけ変えるとエラーにならず別のフィールドとして読まれるため。フィールドは NUL、レコードは行で区切る。
/// 並べるフィールドは LF も NUL も含みえない（ref 名・remote 名は git が制御文字を禁じ、author 名は
/// コミットヘッダの 1 行から取る）ので、この区切りで値を取り違えない。名前は短縮表示名ではなく
/// `refname:lstrip=2` の正確な名前で読む（`refname:short` は同名タグ等があると `heads/x` に化ける）。
enum BranchParser {
  private enum LocalField: String, CaseIterable {
    case name = "refname:lstrip=2"
    case relativeDate = "committerdate:relative"
    case upstreamShort = "upstream:short"
    case upstreamRef = "upstream"
    case upstreamRemote = "upstream:remotename"
    case upstreamRemoteRef = "upstream:remoteref"
    case upstreamTrack = "upstream:track"
    case pushRemote = "push:remotename"
  }

  private enum RemoteField: String, CaseIterable {
    case name = "refname:lstrip=2"
    case relativeDate = "committerdate:relative"
    case author = "authorname"
  }

  static let localFormat = format(LocalField.self)
  static let remoteFormat = format(RemoteField.self)

  static func parseLocal(_ text: String) -> [GitBranch] {
    records(text, LocalField.self).compactMap { record in
      guard let name = record[.name] else { return nil }
      let upstream = record[.upstreamShort].map { short in
        GitUpstream(
          short: short, ref: record[.upstreamRef] ?? "", remote: record[.upstreamRemote] ?? "",
          remoteRef: record[.upstreamRemoteRef] ?? "", track: parseTrack(record[.upstreamTrack]))
      }
      return GitBranch(
        name: name, relativeDate: record[.relativeDate] ?? "", upstream: upstream,
        pushRemote: record[.pushRemote])
    }
  }

  /// `*/HEAD`（`origin/HEAD` の symref）はノイズとして除外する。
  static func parseRemote(_ text: String) -> [GitBranch] {
    records(text, RemoteField.self).compactMap { record in
      guard let name = record[.name], !name.hasSuffix("/HEAD") else { return nil }
      let date = record[.relativeDate] ?? ""
      let combined: String
      if let author = record[.author] {
        combined = date.isEmpty ? author : "\(author) · \(date)"
      } else {
        combined = date
      }
      return GitBranch(name: name, relativeDate: combined, upstream: nil)
    }
  }

  /// `%(upstream:track)` の書式は固定（空 / `[gone]` / `[ahead N]` / `[behind M]` / `[ahead N, behind M]`）。
  private static func parseTrack(_ text: String?) -> GitUpstreamTrack? {
    guard let text else { return nil }
    if text == "[gone]" { return .gone }
    return .counts(ahead: count("ahead ", in: text), behind: count("behind ", in: text))
  }

  private static func count(_ label: String, in text: String) -> Int {
    guard let range = text.range(of: label) else { return 0 }
    return Int(text[range.upperBound...].prefix { $0.isNumber }) ?? 0
  }

  private static func format<Field: RawRepresentable & CaseIterable>(_: Field.Type) -> String
  where Field.RawValue == String {
    Field.allCases.map { "%(\($0.rawValue))" }.joined(separator: "%00")
  }

  private static func records<Field: CaseIterable & Equatable>(_ text: String, _: Field.Type)
    -> [Record<Field>]
  {
    // 行はスカラーで割る。Character で割ると、`\r` で終わる author 名と行末の LF が 1 文字（CR LF）に
    // まとまり、次のレコードがその列に吸い込まれる。
    text.unicodeScalars.split(separator: "\n").map {
      Record(
        values: Substring($0).split(separator: "\0", omittingEmptySubsequences: false)
          .map(String.init))
    }
  }

  /// 1 レコード。列が欠けていても落ちず、欠けた列と空の列はどちらも nil として読む。
  private struct Record<Field: CaseIterable & Equatable> {
    let values: [String]

    subscript(_ field: Field) -> String? {
      guard let i = Array(Field.allCases).firstIndex(of: field), i < values.count,
        !values[i].isEmpty
      else { return nil }
      return values[i]
    }
  }
}
