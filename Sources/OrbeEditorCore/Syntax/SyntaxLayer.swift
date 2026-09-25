import Foundation
import SwiftTreeSitter
import SwiftTreeSitterLayer

/// 文書 1 つの構文木（injections 込みの `LanguageLayer`）。解析し、編集を追い、役割付き区間を発行する。
/// 単位は UTF-16（tree-sitter の既定符号化）。バイトはその 2 倍。
final class SyntaxLayer {
  private let layer: LanguageLayer
  /// capture 名（成分の列）→ 役割。名前の種類は文法ごとに数十しかないので、表は名前ごとに 1 度だけ引く（塗りも
  /// ミニマップも capture ごとに引くので、毎回の名前の組み立てと分解を避ける）。
  private var roles: [[String]: SyntaxRole?] = [:]

  init(configuration: LanguageConfiguration, registry: LanguageRegistry) throws {
    layer = try LanguageLayer(
      languageConfig: configuration,
      configuration: LanguageLayer.Configuration(languageProvider: registry.languageProvider))
  }

  /// 本文全体を初めて解析する。
  func parseAll(_ text: String, lineIndex: LineIndex) {
    let length = text.utf16.count
    let edit = InputEdit(
      startByte: 0, oldEndByte: 0, newEndByte: length * 2, startPoint: .zero, oldEndPoint: .zero,
      newEndPoint: Self.point(at: length, in: lineIndex))
    _ = layer.didChangeContent(LanguageLayer.Content(string: text), using: edit)
  }

  /// 編集を構文木へ写して再解析し、塗り直すべき区間を返す。`old` は編集前の索引、`new` は編集後。
  func didChange(_ edit: TextEdit, text: String, old: LineIndex, new: LineIndex) -> IndexSet {
    let input = InputEdit(
      startByte: edit.range.location * 2, oldEndByte: NSMaxRange(edit.range) * 2,
      newEndByte: NSMaxRange(edit.newRange) * 2,
      startPoint: Self.point(at: edit.range.location, in: old),
      oldEndPoint: Self.point(at: NSMaxRange(edit.range), in: old),
      newEndPoint: Self.point(at: NSMaxRange(edit.newRange), in: new))
    return layer.didChangeContent(LanguageLayer.Content(string: text), using: input)
  }

  /// 区間集合の中の役割付き区間。並びは tree-sitter の優先順（後のものが上に塗られる）。本文は predicate が要る区間
  /// だけ `substring` で取る（全文のコピーを要しない）。tree-sitter は集合と交差する**マッチ**を返すので、capture は
  /// 集合の外へはみ出しうる（マッチの他の capture が外にある・capture 自体が集合をまたぐ）。集合で切る——外の字の役割を
  /// 広い capture で答えない（外にある細かい capture は、そこを問われたときに答える）。
  func highlights(in set: IndexSet, substring: @escaping (NSRange) -> String) -> [HighlightSpan] {
    guard
      let ranges = try? layer.highlights(in: set, provider: { range, _ in substring(range) })
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

  private static func point(at offset: Int, in index: LineIndex) -> Point {
    let p = index.point(at: offset)
    return Point(row: p.row, column: p.column * 2)
  }
}
