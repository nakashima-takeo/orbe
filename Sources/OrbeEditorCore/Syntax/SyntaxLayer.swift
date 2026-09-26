import Foundation
import SwiftTreeSitter
import SwiftTreeSitterLayer

/// 文書 1 つの構文木（injections 込みの `LanguageLayer`）。本文の写し（ロープ）を塊ごとに読んで解析し、編集を追い、
/// 役割付き区間を発行する。単位は UTF-16（tree-sitter の既定符号化）。バイトはその 2 倍。構文の裏の仕事
/// （`SyntaxWorker`）の状態としてだけ使う。
final class SyntaxLayer {
  private let layer: LanguageLayer
  /// capture 名（成分の列）→ 役割。名前の種類は文法ごとに数十しかないので、表は名前ごとに 1 度だけ引く。
  private var roles: [[String]: SyntaxRole?] = [:]

  init(configuration: LanguageConfiguration, registry: LanguageRegistry) throws {
    layer = try LanguageLayer(
      languageConfig: configuration,
      configuration: LanguageLayer.Configuration(languageProvider: registry.languageProvider))
  }

  /// 本文全体を初めて解析する。
  func parseAll(_ text: TextRope) {
    let end = Self.point(at: text.length, in: text)
    let edit = InputEdit(
      startByte: 0, oldEndByte: 0, newEndByte: UInt32(text.length * 2), startPoint: .zero,
      oldEndPoint: .zero, newEndPoint: end)
    _ = layer.didChangeContent(Self.content(text), using: edit)
  }

  /// 編集（古い順）を構文木へ写して 1 回だけ再解析し、構文木が変わった区間と編集の区間（どちらも `text` の上）を返す。
  /// 削除の編集の区間は、消した位置の前後の 1 字ずつ（消した位置の行を作り直す範囲に入れるため）。
  func didChange(_ edits: some Collection<VersionedEdit>, text: TextRope) -> IndexSet {
    var edited = IndexSet()
    for record in edits {
      let edit = record.edit
      layer.applyEdit(
        InputEdit(
          startByte: UInt32(edit.range.location * 2),
          oldEndByte: UInt32(NSMaxRange(edit.range) * 2),
          newEndByte: UInt32(NSMaxRange(edit.newRange) * 2), startPoint: Self.point(record.start),
          oldEndPoint: Self.point(record.oldEnd), newEndPoint: Self.point(record.newEnd)))
      edited = edit.track(edited)
      let location = edit.range.location
      edited.insert(
        integersIn: edit.replacementLength > 0
          ? location..<(location + edit.replacementLength) : max(0, location - 1)..<(location + 1))
    }
    return layer.parse(with: Self.content(text), affecting: edited, resolveSublayers: true)
      .union(edited)
  }

  /// 区間の中の役割の区間——構文の区間を後勝ち（tree-sitter の優先順で後のものが上に塗られる）で平らにした、重ならない
  /// 昇順の列。役割の無い字は含まない。答えは区間の切り方に依らない（区間の外の字の役割は答えず、区間をまたぐ capture は
  /// 区間で切る）——文書全体の役割を区切りごとに作っても、全体を一度に作ったものと同じになる。
  func roles(in range: NSRange, text: TextRope) -> [HighlightSpan] {
    guard range.length > 0 else { return [] }
    var roles = [SyntaxRole?](repeating: nil, count: range.length)
    for span in highlights(in: range, text: text) {
      let start = span.range.location - range.location
      for offset in start..<(start + span.range.length) { roles[offset] = span.role }
    }
    var result: [HighlightSpan] = []
    var offset = 0
    while offset < roles.count {
      guard let role = roles[offset] else {
        offset += 1
        continue
      }
      var end = offset + 1
      while end < roles.count, roles[end] == role { end += 1 }
      result.append(
        HighlightSpan(
          range: NSRange(location: range.location + offset, length: end - offset), role: role))
      offset = end
    }
    return result
  }

  /// 区間の中の役割付き区間。並びは tree-sitter の優先順（後のものが上に塗られる）。tree-sitter は区間と交差する
  /// **マッチ**を返すので、capture は区間の外へはみ出しうる（マッチの他の capture が外にある・capture 自体が区間をまたぐ）。
  /// 区間で切る——外の字の役割を広い capture で答えない（外にある細かい capture は、そこを問われたときに答える）。
  private func highlights(in range: NSRange, text: TextRope) -> [HighlightSpan] {
    let set = IndexSet(integersIn: range.location..<NSMaxRange(range))
    guard
      let ranges = try? layer.highlights(in: set, provider: { range, _ in text.substring(range) })
    else { return [] }
    return ranges.flatMap { named -> [HighlightSpan] in
      guard let range = Range(named.range), let role = role(of: named.nameComponents)
      else { return [] }
      return set.intersection(IndexSet(integersIn: range)).rangeView.map {
        HighlightSpan(range: NSRange($0), role: role)
      }
    }
  }

  private func role(of components: [String]) -> SyntaxRole? {
    if let role = roles[components] { return role }
    let role = CaptureRoleMap.role(for: components.joined(separator: "."))
    roles[components] = role
    return role
  }

  private static func content(_ text: TextRope) -> LanguageLayer.Content {
    LanguageLayer.Content(
      readHandler: { byte, _ in text.chunkData(at: byte / 2) },
      textProvider: { range, _ in text.substring(range) })
  }

  private static func point(at offset: Int, in text: TextRope) -> Point {
    let p = text.point(at: offset)
    return Point(row: p.row, column: p.column * 2)
  }

  private static func point(_ point: TextPoint) -> Point {
    Point(row: point.row, column: point.column * 2)
  }
}
