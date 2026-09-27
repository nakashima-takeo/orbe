import Foundation
import TreeSitter

/// 文書 1 つの構文——根の層と注入の層の並び。本文の写しを解析し、編集を追い、注入を問い直し、区間の役割を答える。単位は
/// UTF-16（バイトはその 2 倍）。構文の裏の仕事（`SyntaxWorker`）の状態としてだけ使う。
///
/// 注入は tree-sitter の約束どおりに扱う——注入 1 つにつき木 1 本、規則が束ねると指定したものだけを（生んだ層・言語）ごとに
/// 1 本に束ねる。注入の層は、自分を生んだマッチで存否が決まり、作り直す区画の中で問い直す（深さの順に、マッチが区画に
/// 掛かる子の層を外し、見つかった注入のうち言語と注入の範囲が同じものは木と孫を持ったまま戻す）。
///
/// 色は区画（本文の `block` 字ごとの固定の格子）ごとに問う。構文木が誤りを含む層では、区画の前後 `margin` 字の枠に収まる
/// マッチだけを問う——誤りを含む木の問い合わせは後ろに続く文書の長さに比例して重くなるので、その重さを枠で塞ぐ。枠は区画で
/// 決まるので、同じ本文の同じ字は、どこから作り直しても同じ色になる。注入の問い合わせには枠を掛けない（誤りを含む木でも
/// 重くならず、枠で見えないマッチがあると、区画によって注入の存否の答えが食い違う）。
final class SyntaxLayers {
  /// 色を問う区画の大きさ（UTF-16）。
  static let block = 16_384
  /// 誤りを含む層で、区画の前後に取る枠の余白（UTF-16）。
  static let margin = 16_384
  /// 注入の深さの上限。この深さの層は注入を問わない。
  static let maximumDepth = 4

  private let registry: LanguageRegistry
  private let parser: SyntaxParser
  private let cursor = QueryCursor()
  private let root: SyntaxLayer
  private var injections = InjectionLayers()
  /// 注入が名乗る言語名 → 規則。
  private var injectionRules: [String: GrammarRules?] = [:]
  private var text = TextRope()
  /// 作り直していない範囲に足す区間（本文の上）——注入の層の出入りと、注入の層の構文木が変わった区間。
  private var invalidated = IndexSet()
  /// 文書を閉じた。以後は何もしない。
  var isCancelled: Bool { parser.cancellation.isCancelled }

  init(rules: GrammarRules, registry: LanguageRegistry, cancellation: SyntaxCancellation) {
    self.registry = registry
    parser = SyntaxParser(cancellation: cancellation)
    root = SyntaxLayer(rules: rules, depth: 0, parent: nil, isCombined: false, parts: [])
  }

  /// 根と注入の層（根、束ねない層を開始位置の順、束ねた層の順）。
  var allLayers: [Placed] { [placedRoot] + injections.all }

  private var placedRoot: Placed { Placed(layer: root, origin: 0, row: 0) }

  /// 本文全体を初めて解析する。
  func parseAll(_ text: TextRope) {
    self.text = text
    parse(placedRoot)
  }

  /// 編集（古い順）を構文木へ写し、根を 1 回だけ差分で解析する。根の構文木が変わった区間と編集の区間（どちらも `text`
  /// の上）を返す。削除の編集の区間は、消した位置の前後の 1 字ずつ（消した位置の行を作り直す範囲に入れるため）。編集で
  /// 部分が丸ごと消えた束ねた層もここで解析し直す——消えた部分はもうどの区画にも掛からないので、残りの部分の構文の変化は
  /// 問い直しでは見つからない。
  func apply(_ edits: some Collection<VersionedEdit>, text: TextRope) -> IndexSet {
    self.text = text
    var edited = IndexSet()
    for record in edits {
      let edit = record.edit
      invalidated = edit.track(invalidated)
      edited = edit.track(edited)
      let location = edit.range.location
      edited.insert(
        integersIn: edit.replacementLength > 0
          ? location..<(location + edit.replacementLength) : max(0, location - 1)..<(location + 1))
      root.edit(TSInputEdit(record, origin: 0, row: 0))
      invalidated.formUnion(edit.track(injections.apply(record)))
    }
    for layer in injections.combined where layer.rangesReplaced {
      parse(Placed(layer: layer, origin: 0, row: 0))
    }
    return edited.union(parse(placedRoot))
  }

  /// 根の構文木の写し（別のスレッドで読む）。まだ解析していなければ nil。
  func rootTreeCopy() -> TreeCopy? {
    root.tree?.copy()
  }

  /// 前に取ってから足された「作り直していない範囲」。
  func takeInvalidated() -> IndexSet {
    defer { invalidated = IndexSet() }
    return invalidated.intersection(IndexSet(integersIn: 0..<text.length))
  }

  /// 区間の役割の区間——区間の注入を問い直してから、層ごとの capture を優先の順に塗り重ねて平らにした、重ならない昇順の
  /// 列。役割の無い字は含まない。答えは区間の切り方に依らない（区間を区画で切って区画ごとに問い、区間の外の字の役割は
  /// 答えない）。
  func roles(in range: NSRange) -> [HighlightSpan] {
    var result: [HighlightSpan] = []
    var start = max(0, range.location)
    let end = min(NSMaxRange(range), text.length)
    while start < end, !isCancelled {
      let piece = start..<min(end, (start / Self.block + 1) * Self.block)
      resolveInjections(in: piece)
      result += paint(piece)
      start = piece.upperBound
    }
    return result
  }

  // MARK: - 解析

  /// 層を解析する（要るときだけ）。構文木が変わった区間（本文の上）を返す。根の変化は返すだけ、注入の層の変化は作り直して
  /// いない範囲へ足す。誤りの有無が変わった層は、枠の掛け方が変わるので層の全体を変わったとする。解析できない層（含める
  /// 範囲が空・拒まれた）は子孫ごと外す。
  @discardableResult
  private func parse(_ placed: Placed) -> IndexSet {
    let layer = placed.layer
    guard !isCancelled, layer.needsParse || layer.tree == nil else { return IndexSet() }
    let isRoot = layer === root
    let ranges = layer.includedRanges
    guard isRoot || !ranges.isEmpty else {
      invalidated.formUnion(injections.drop([placed]))
      return IndexSet()
    }
    let old = layer.rules.grammar.reusesTrees ? layer.tree : nil
    if layer.rangesReplaced { old?.prepareToExtend(to: ranges) }
    let outcome = parser.parse(
      layer.rules.language, ranges: ranges, old: old, text: text, origin: placed.origin)
    guard case .parsed(let tree) = outcome else {
      if case .rejected = outcome { invalidated.formUnion(injections.drop([placed])) }
      return IndexSet()
    }
    var changed = IndexSet()
    if let old = layer.tree, old.hasError == tree.hasError {
      for range in old.changedRanges(to: tree) {
        let from = min(placed.origin + range.lowerBound / 2, text.length)
        let to = min(placed.origin + (range.upperBound + 1) / 2, text.length)
        if from < to { changed.insert(integersIn: from..<to) }
      }
    } else if isRoot {
      changed.insert(integersIn: 0..<text.length)
    } else {
      changed = placed.whole.intersection(IndexSet(integersIn: 0..<text.length))
    }
    layer.tree = tree
    layer.needsParse = false
    layer.rangesReplaced = false
    if !isRoot { invalidated.formUnion(changed) }
    return changed
  }

  // MARK: - 注入の問い直し

  /// 区画の中で、深さの順に各層の注入を問い直す。深さごとに、マッチが区画に掛かる子の層をまとめて外し、区画と交わる層と
  /// 外した子の親の注入を問い直して、言語と注入の範囲が同じ子は木と孫を持ったまま戻す。戻らなかった子は子孫ごと外す。外した
  /// 子の親は、区画と交わらなくても問い直す——束ねた層の節は部分の隙間をまたげるので、親の部分が無い区画に子のマッチが
  /// 掛かることがある。そこで親に問わないと、子を戻せずに外し、隣の区画で作り直すのを繰り返す。
  private func resolveInjections(in piece: Range<Int>) {
    var parents = [placedRoot]
    for depth in 0..<Self.maximumDepth {
      var taken: [RestoreKey: [Placed]] = [:]
      var asked = parents
      for child in injections.uncombined(atDepth: depth + 1, touching: piece).reversed() {
        injections.remove(at: child.index)
        taken[RestoreKey(child.placed), default: []].append(child.placed)
        if let parent = child.placed.layer.parent, parent.isCombined,
          !asked.contains(where: { $0.layer === parent })
        {
          asked.append(Placed(layer: parent, origin: 0, row: 0))
        }
      }
      for parent in asked where parent.layer.rules.injections != nil {
        parse(parent)
        guard !isCancelled else { return }
        if !parent.layer.detached, parent.layer.tree != nil {
          resolveChildren(of: parent, in: piece, restoring: &taken)
        }
      }
      let leftovers = taken.values.flatMap { $0 }
      if !leftovers.isEmpty { invalidated.formUnion(injections.drop(leftovers)) }
      parents = injections.intersecting(piece).filter { $0.layer.depth == depth + 1 }
    }
  }

  /// `parent` の注入を区画の中で問い、子の層を置く。外した子（`taken`）のうち言語と注入の範囲が同じものは戻す。
  private func resolveChildren(
    of parent: Placed, in piece: Range<Int>, restoring taken: inout [RestoreKey: [Placed]]
  ) {
    var combinedParts: [Grammar: [InjectionPart]] = [:]
    for injection in injections(of: parent, in: piece) {
      if injection.combined {
        combinedParts[injection.rules.grammar, default: []].append(injection.combinedPart)
        continue
      }
      let candidate = injection.placed()
      let key = RestoreKey(candidate)
      let match = injection.globalMatch
      if let index = taken[key]?.lastIndex(where: {
        $0.layer.parent === parent.layer && $0.origin <= match.lowerBound
      }), let old = taken[key]?.remove(at: index) {
        old.layer.parts[0].match = (match.lowerBound - old.origin)..<(match.upperBound - old.origin)
        injections.insert(old)
      } else {
        injections.insert(candidate)
        invalidated.formUnion(candidate.whole)
      }
    }
    resolveCombined(of: parent.layer, in: piece, found: combinedParts)
  }

  /// 束ねる層の、区画に掛かるマッチの部分を差し替える。部分が変わった層はその場で解析し直す——束ねた層では、区画の部分が
  /// 消えると区画の外の構文が変わり、その層がもう区画と交わらないこともあるので、変わった区間をここで足す。部分が空に
  /// なった層は外す。
  private func resolveCombined(
    of parent: SyntaxLayer, in piece: Range<Int>, found: [Grammar: [InjectionPart]]
  ) {
    var found = found
    var emptied: [Placed] = []
    for layer in injections.combined where layer.parent === parent {
      let before = layer.parts
      var parts = before.filter { !$0.match.touches(piece) }
      parts += found.removeValue(forKey: layer.rules.grammar) ?? []
      parts.sort { $0.match.lowerBound < $1.match.lowerBound }
      if parts.isEmpty {
        emptied.append(Placed(layer: layer, origin: 0, row: 0))
      } else if !InjectionPart.same(parts, before) {
        layer.parts = parts
        layer.needsParse = true
        layer.rangesReplaced = true
        parse(Placed(layer: layer, origin: 0, row: 0))
      }
    }
    if !emptied.isEmpty { invalidated.formUnion(injections.drop(emptied)) }
    for grammar in Grammar.allCases {
      guard var parts = found[grammar], let rules = registry.rules(for: grammar) else { continue }
      parts.sort { $0.match.lowerBound < $1.match.lowerBound }
      let layer = SyntaxLayer(
        rules: rules, depth: parent.depth + 1, parent: parent, isCombined: true, parts: parts)
      injections.append(combined: layer)
      parse(Placed(layer: layer, origin: 0, row: 0))
    }
  }

  /// `parent` の注入のうち、マッチが区画に掛かるもの。
  private func injections(of parent: Placed, in piece: Range<Int>) -> [Injection] {
    guard let bytes = parent.bytes(of: piece), let query = parent.layer.rules.injections,
      let content = query.content, let tree = parent.layer.tree
    else { return [] }
    let text = text
    var found: [Injection] = []
    cursor.matches(
      of: query.query, in: tree.root, bounds: QueryBounds(range: bytes),
      text: { parent.text(of: $0, in: text) },
      each: { match in
        if let injection = injection(of: match, query: query, content: content, parent: parent),
          injection.globalMatch.touches(piece)
        {
          found.append(injection)
        }
      })
    return found
  }

  /// マッチ 1 つの注入。言語は `injection.language` の capture の字、無ければ `#set!` の指定。知らない言語・範囲が空なら nil。
  private func injection(
    of match: TSQueryMatch, query: InjectionQuery, content: UInt32, parent: Placed
  ) -> Injection? {
    let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
    guard
      let first = captures.min(by: { ts_node_start_byte($0.node) < ts_node_start_byte($1.node) })
    else { return nil }
    let contents = captures.filter { $0.index == content }.map(\.node)
    let languageNode = captures.first { $0.index == query.language }?.node
    let pattern = query.patterns[Int(match.pattern_index)]
    guard !contents.isEmpty,
      let name = languageNode.map({ parent.text(of: $0, in: text) }) ?? pattern.language,
      let rules = rules(forInjection: name)
    else { return nil }
    let ranges = Injection.contentRanges(
      contents, includesChildren: pattern.includesChildren,
      within: parent.layer === root ? nil : parent.layer.includedRanges)
    guard !ranges.isEmpty else { return nil }
    return Injection(
      rules: rules, parent: parent, combined: pattern.combined,
      matchStartByte: Int(ts_node_start_byte(first.node)),
      matchStartPoint: ts_node_start_point(first.node),
      matchEndByte: captures.map { Int(ts_node_end_byte($0.node)) }.max() ?? 0, ranges: ranges)
  }

  private func rules(forInjection name: String) -> GrammarRules? {
    if let cached = injectionRules[name] { return cached }
    let rules = registry.rules(forInjection: name)
    injectionRules[name] = rules
    return rules
  }

  // MARK: - 色

  /// 区画の役割。区画と交わる層ごとに capture を集め、優先の順に塗り重ねる。注入の層の capture は注入の範囲の中に切る。
  private func paint(_ piece: Range<Int>) -> [HighlightSpan] {
    var captures: [PaintedCapture] = []
    for placed in [placedRoot] + injections.intersecting(piece) {
      let clip = placed.layer === root ? [piece] : placed.clip(to: piece)
      guard !clip.isEmpty else { continue }
      parse(placed)
      guard !isCancelled else { return [] }
      guard !placed.layer.detached else { continue }
      cursor.collectHighlights(of: placed, in: piece, clip: clip, text: text, into: &captures)
    }
    return PaintedCapture.flatten(captures)
  }
}
