import Foundation
import TreeSitter

/// 組んだ問い合わせ 1 つ（`TSQuery`）と、パターンごとの述語。組んだ後は変わらない。
///
/// `@unchecked Sendable`: `TSQuery` は組んだ後に書き換えず（問い合わせの進み具合は cursor が持つ）、述語の正規表現も
/// 不変なので、複数の文書の構文の裏の仕事から同時に使ってよい。コンパイラはポインタの先を見られない。
final class SyntaxQuery: @unchecked Sendable {
  let raw: OpaquePointer
  /// capture の番号 → 名前。
  let captureNames: [String]
  /// パターンごとの述語。
  private let predicates: [[QueryPredicate]]
  /// パターンごとの `#set!`（capture を名指さないもの）の鍵と値（値の無い鍵は空の文字列）。
  let settings: [[String: String]]

  /// queries の本文から組む。組めない（構文の誤り・正規表現の誤り）なら nil。
  init?(language: LanguagePointer, source: Data) {
    var errorOffset: UInt32 = 0
    var errorType = TSQueryErrorNone
    let query = source.withUnsafeBytes { bytes in
      ts_query_new(
        language.raw, bytes.bindMemory(to: CChar.self).baseAddress, UInt32(bytes.count),
        &errorOffset, &errorType)
    }
    guard let query else { return nil }
    let names = (0..<ts_query_capture_count(query)).map { Self.captureName(query, $0) }
    var predicates: [[QueryPredicate]] = []
    var settings: [[String: String]] = []
    for pattern in 0..<ts_query_pattern_count(query) {
      guard let parsed = Self.parse(query, pattern: pattern, captureNames: names) else {
        ts_query_delete(query)
        return nil
      }
      predicates.append(parsed.predicates)
      settings.append(parsed.settings)
    }
    raw = query
    captureNames = names
    self.predicates = predicates
    self.settings = settings
  }

  deinit {
    ts_query_delete(raw)
  }

  /// マッチが述語をすべて満たすか。`text` は capture の節の字。
  func accepts(_ match: TSQueryMatch, text: (TSNode) -> String) -> Bool {
    let predicates = predicates[Int(match.pattern_index)]
    guard !predicates.isEmpty else { return true }
    let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
    return predicates.allSatisfy { predicate in
      captures.allSatisfy { capture in
        !predicate.names(capture.index) || predicate.accepts(text(capture.node))
      }
    }
  }

  private static func captureName(_ query: OpaquePointer, _ id: UInt32) -> String {
    var length: UInt32 = 0
    return String(cString: ts_query_capture_name_for_id(query, id, &length))
  }

  private static func stringValue(_ query: OpaquePointer, _ id: UInt32) -> String {
    var length: UInt32 = 0
    return String(cString: ts_query_string_value_for_id(query, id, &length))
  }

  /// パターン 1 つの述語と `#set!` を読む。正規表現が組めなければ nil。
  private static func parse(
    _ query: OpaquePointer, pattern: UInt32, captureNames: [String]
  ) -> (predicates: [QueryPredicate], settings: [String: String])? {
    var count: UInt32 = 0
    guard let steps = ts_query_predicates_for_pattern(query, pattern, &count), count > 0 else {
      return ([], [:])
    }
    var predicates: [QueryPredicate] = []
    var settings: [String: String] = [:]
    var arguments: [TSQueryPredicateStep] = []
    for step in UnsafeBufferPointer(start: steps, count: Int(count)) {
      guard step.type == TSQueryPredicateStepTypeDone else {
        arguments.append(step)
        continue
      }
      defer { arguments = [] }
      guard let head = arguments.first, head.type == TSQueryPredicateStepTypeString else {
        continue
      }
      let rest = arguments.dropFirst()
      let captures = rest.filter { $0.type == TSQueryPredicateStepTypeCapture }.map(\.value_id)
      let strings = rest.filter { $0.type == TSQueryPredicateStepTypeString }.map {
        stringValue(query, $0.value_id)
      }
      switch stringValue(query, head.value_id) {
      case "eq?", "not-eq?":
        let negated = stringValue(query, head.value_id) == "not-eq?"
        predicates.append(QueryPredicate(captures: captures, test: .equals(strings, negated)))
      case "match?", "not-match?":
        guard let pattern = strings.first else { continue }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let negated = stringValue(query, head.value_id) == "not-match?"
        predicates.append(QueryPredicate(captures: captures, test: .matches(regex, negated)))
      case "any-of?", "not-any-of?":
        guard let capture = captures.first else { continue }
        let negated = stringValue(query, head.value_id) == "not-any-of?"
        predicates.append(
          QueryPredicate(captures: [capture], test: .isAnyOf(Set(strings), negated)))
      case "set!":
        if captures.isEmpty, let key = strings.first {
          settings[key] = strings.count > 1 ? strings[1] : ""
        }
      default:
        continue
      }
    }
    return (predicates, settings)
  }
}

/// 述語 1 つ。名指した capture（名指しが無ければマッチの全 capture）の字がどれも条件を満たすこと。`#is-not?`・`#offset!`・
/// 知らない述語は常に通す。
private struct QueryPredicate: Sendable {
  enum Test: @unchecked Sendable {
    /// 字が並べた文字列のどれとも等しい（否定なら、どれとも等しくない）。文字列が無ければ常に通す（capture どうしの比較）。
    case equals([String], Bool)
    case matches(NSRegularExpression, Bool)
    case isAnyOf(Set<String>, Bool)
  }

  let captures: [UInt32]
  let test: Test

  func names(_ capture: UInt32) -> Bool {
    captures.isEmpty || captures.contains(capture)
  }

  func accepts(_ text: String) -> Bool {
    switch test {
    case .equals(let strings, let negated):
      return strings.allSatisfy { ($0 == text) != negated }
    case .matches(let regex, let negated):
      let range = NSRange(location: 0, length: text.utf16.count)
      return (regex.firstMatch(in: text, range: range) != nil) != negated
    case .isAnyOf(let strings, let negated):
      return strings.contains(text) != negated
    }
  }
}

/// highlights の問い合わせ。capture の番号から役割と、名前の成分の数（優先の鍵）を引く。
final class HighlightQuery: Sendable {
  let query: SyntaxQuery
  let roles: [SyntaxRole?]
  let componentCounts: [Int]

  init(_ query: SyntaxQuery) {
    self.query = query
    roles = query.captureNames.map { CaptureRoleMap.role(for: $0) }
    componentCounts = query.captureNames.map { $0.components(separatedBy: ".").count }
  }
}

/// injections の問い合わせ。パターンごとに、言語の指定・束ねるか・子の節を含むかを読んでおく。
final class InjectionQuery: Sendable {
  struct Pattern: Sendable {
    let language: String?
    let combined: Bool
    let includesChildren: Bool
  }

  let query: SyntaxQuery
  let content: UInt32?
  let language: UInt32?
  let patterns: [Pattern]

  init(_ query: SyntaxQuery) {
    self.query = query
    content = query.captureNames.firstIndex(of: "injection.content").map { UInt32($0) }
    language = query.captureNames.firstIndex(of: "injection.language").map { UInt32($0) }
    patterns = query.settings.map { settings in
      Pattern(
        language: settings["injection.language"],
        combined: settings["injection.combined"] != nil,
        includesChildren: settings["injection.include-children"] != nil)
    }
  }
}

/// 文法 1 つの、色付けに要るもの一式——`TSLanguage` と highlights・injections の問い合わせ。
final class GrammarRules: Sendable {
  let grammar: Grammar
  let language: LanguagePointer
  let highlights: HighlightQuery
  let injections: InjectionQuery?

  init(grammar: Grammar, highlights: SyntaxQuery, injections: SyntaxQuery?) {
    self.grammar = grammar
    language = grammar.language
    self.highlights = HighlightQuery(highlights)
    self.injections = injections.map(InjectionQuery.init)
  }
}

/// 問い合わせる区間（バイト）。`range` と交わるマッチだけ、`containing` があればその中に全部の節が収まるマッチだけを返す。
struct QueryBounds {
  var range: Range<Int>
  var containing: Range<Int>?
}

/// 問い合わせの cursor。構文の裏の仕事の中だけで使う。
final class QueryCursor {
  private let raw: OpaquePointer

  init() {
    raw = ts_query_cursor_new()
  }

  deinit {
    ts_query_cursor_delete(raw)
  }

  /// `query` を `node` の下で回し、述語を満たすマッチを順に渡す。`text` は capture の節の字。
  func matches(
    of query: SyntaxQuery, in node: TSNode, bounds: QueryBounds, text: (TSNode) -> String,
    each body: (TSQueryMatch) -> Void
  ) {
    let range = bounds.range
    ts_query_cursor_set_byte_range(raw, UInt32(range.lowerBound), UInt32(range.upperBound))
    if let containing = bounds.containing {
      ts_query_cursor_set_containing_byte_range(
        raw, UInt32(containing.lowerBound), UInt32(containing.upperBound))
    } else {
      ts_query_cursor_set_containing_byte_range(raw, 0, 0)
    }
    ts_query_cursor_exec(raw, query.raw, node)
    var match = TSQueryMatch()
    while ts_query_cursor_next_match(raw, &match) {
      if query.accepts(match, text: text) { body(match) }
    }
  }
}

extension QueryCursor {
  /// 層 1 つの、区画の capture を集める（`clip` は層の注入の範囲と区画の積）。誤りを含む層では区画の枠を掛ける。
  func collectHighlights(
    of placed: Placed, in piece: Range<Int>, clip: [Range<Int>], text: TextRope,
    into captures: inout [PaintedCapture]
  ) {
    let layer = placed.layer
    guard let tree = layer.tree,
      var bounds = placed.bytes(of: piece).map({ QueryBounds(range: $0) })
    else { return }
    if layer.crumbled {
      let block = piece.lowerBound / SyntaxLayers.block * SyntaxLayers.block
      let lower = max(0, block - SyntaxLayers.margin - placed.origin)
      let upper = max(lower, block + SyntaxLayers.block + SyntaxLayers.margin - placed.origin)
      bounds.containing = (lower * 2)..<(upper * 2)
    }
    let highlights = layer.rules.highlights
    let layerStart =
      layer.includedRanges.first.map { placed.origin + Int($0.start_byte) / 2 } ?? placed.origin
    let grammar = Grammar.allCases.firstIndex(of: layer.rules.grammar) ?? 0
    matches(
      of: highlights.query, in: tree.root, bounds: bounds, text: { placed.text(of: $0, in: text) },
      each: { match in
        for capture in UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count)) {
          guard let role = highlights.roles[Int(capture.index)] else { continue }
          let start = placed.origin + Int(ts_node_start_byte(capture.node)) / 2
          let end = placed.origin + Int(ts_node_end_byte(capture.node)) / 2
          let key = PaintedCapture.Key(
            depth: layer.depth, start: start,
            components: highlights.componentCounts[Int(capture.index)],
            pattern: Int(match.pattern_index), layerStart: layerStart, grammar: grammar,
            sequence: captures.count)
          var index = clip.partitioningIndex { $0.upperBound > start }
          while index < clip.count, clip[index].lowerBound < end {
            let range = max(start, clip[index].lowerBound)..<min(end, clip[index].upperBound)
            if !range.isEmpty {
              captures.append(PaintedCapture(key: key, range: range, role: role))
            }
            index += 1
          }
        }
      })
  }
}

/// 塗り重ねる capture 1 つ。鍵の小さいものから塗り、後に塗ったものが勝つ——深い層 → 後から始まる capture → 名前の成分が
/// 多いもの → 後のパターン。鍵が同じ注入の層どうしは（層の始まり・言語）で、それも同じなら集めた順で決める。
struct PaintedCapture: Comparable {
  struct Key: Comparable {
    let depth: Int
    let start: Int
    let components: Int
    let pattern: Int
    let layerStart: Int
    let grammar: Int
    let sequence: Int

    static func < (lhs: Key, rhs: Key) -> Bool {
      let left = (lhs.depth, lhs.start, lhs.components, lhs.pattern, lhs.layerStart, lhs.grammar)
      let right = (rhs.depth, rhs.start, rhs.components, rhs.pattern, rhs.layerStart, rhs.grammar)
      return left != right ? left < right : lhs.sequence < rhs.sequence
    }
  }

  let key: Key
  let range: Range<Int>
  let role: SyntaxRole

  static func < (lhs: PaintedCapture, rhs: PaintedCapture) -> Bool { lhs.key < rhs.key }
  static func == (lhs: PaintedCapture, rhs: PaintedCapture) -> Bool { lhs.key == rhs.key }

  /// 鍵の順に塗り重ね、同じ役割の隣り合う区間を繋いだ、重ならない昇順の役割の区間。
  static func flatten(_ captures: [PaintedCapture]) -> [HighlightSpan] {
    var segments: [(range: Range<Int>, role: SyntaxRole)] = []
    for capture in captures.sorted() {
      let range = capture.range
      let first = segments.partitioningIndex { $0.range.upperBound > range.lowerBound }
      var last = first
      while last < segments.count, segments[last].range.lowerBound < range.upperBound { last += 1 }
      var replacement = [(range: range, role: capture.role)]
      if first < last, segments[first].range.lowerBound < range.lowerBound {
        replacement.insert(
          (segments[first].range.lowerBound..<range.lowerBound, segments[first].role), at: 0)
      }
      if first < last, segments[last - 1].range.upperBound > range.upperBound {
        replacement.append(
          (range.upperBound..<segments[last - 1].range.upperBound, segments[last - 1].role))
      }
      segments.replaceSubrange(first..<last, with: replacement)
    }
    var spans: [HighlightSpan] = []
    for segment in segments {
      if let last = spans.last, last.role == segment.role,
        NSMaxRange(last.range) == segment.range.lowerBound
      {
        spans[spans.count - 1] = HighlightSpan(
          range: NSRange(last.range.location..<segment.range.upperBound), role: last.role)
      } else {
        spans.append(HighlightSpan(range: NSRange(segment.range), role: segment.role))
      }
    }
    return spans
  }
}

extension Array {
  /// 述語が偽から真へ変わる最初の番号（述語は前から偽・真の順に並ぶこと）。
  fileprivate func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
    var low = 0
    var high = count
    while low < high {
      let middle = (low + high) / 2
      if predicate(self[middle]) { high = middle } else { low = middle + 1 }
    }
    return low
  }
}
