import Foundation

public enum EditorDocumentError: Error, Equatable {
  case unreadable(URL)
  case notUTF8(URL)
}

/// 開いたファイル 1 つ。識別（URL）・言語・未保存の有無・行索引・構文層を持ち、本文の正は対になる
/// テキスト面にある（開いてから閉じるまで 1 対 1）。面の delegate として編集を受け、索引と構文木を
/// 追従させて塗り直す。
///
/// 塗り直す範囲は「構文木が変わった区間 ∪ 今見えている区間」。木の差分だけでは、隣のノードの変化で
/// 役割が変わるのに自分の区間は変わらない字（呼び出しになった識別子など）が古い色のまま残る。
/// 見えている区間を毎回塗り直し、見えていない区間は次に見えたときに 1 回だけ塗る（`fresh` が
/// 「最後の編集の後に塗った区間」を持つ）。塗りは常に塗り直す区間の中に閉じる（→ `SyntaxLayer`）。
@MainActor
public final class EditorDocument {
  public let url: URL
  public let language: SyntaxLanguage?
  public let surface: any TextSurface
  public private(set) var lineIndex: LineIndex
  /// 面の本文が最後に保存（または開いた）内容と違うか。⌘Z で保存時の状態に戻しても立ったまま。
  public private(set) var isDirty = false {
    didSet { if isDirty != oldValue { onDirtyChange?(isDirty) } }
  }
  public var onDirtyChange: ((Bool) -> Void)?
  /// テキスト面が first responder になった／やめた。
  public var onFocusChange: ((Bool) -> Void)?
  private let syntax: SyntaxLayer?
  /// 最後の編集の後に塗った区間。編集のたびに（変わった区間 ∪ 可視区間）へ置き直す。
  private var fresh = IndexSet()

  /// ファイルを UTF-8 として読む。読めない・UTF-8 でないは throw。
  public static func read(_ url: URL) throws -> String {
    guard let data = try? Data(contentsOf: url) else { throw EditorDocumentError.unreadable(url) }
    guard let text = String(data: data, encoding: .utf8) else {
      throw EditorDocumentError.notUTF8(url)
    }
    return text
  }

  public init(url: URL, surface: any TextSurface, registry: LanguageRegistry) {
    self.url = url
    self.surface = surface
    language = SyntaxLanguage.detect(url: url)
    lineIndex = LineIndex(text: surface.text)
    syntax = language.flatMap { registry.configuration(for: $0) }
      .flatMap { try? SyntaxLayer(configuration: $0, registry: registry) }
    surface.delegate = self
    if let syntax {
      let text = surface.text
      highlight(syntax.parseAll(text, lineIndex: lineIndex), text: text)
      fresh = IndexSet(integersIn: 0..<text.utf16.count)
    }
  }

  /// 面の本文をそのまま UTF-8 で書く（改行・末尾改行は本文のまま）。保存は undo の区切りでもある。
  public func save() throws {
    try Data(surface.text.utf8).write(to: url, options: .atomic)
    isDirty = false
    surface.markUndoBoundary()
  }

  private func highlight(_ set: IndexSet, text: String) {
    guard let syntax, !set.isEmpty else { return }
    surface.applyHighlights(syntax.highlights(in: set, text: text), in: set)
  }

  /// 今見えている区間（本文の長さに収めたもの）。
  private var visibleSet: IndexSet {
    let range = surface.visibleRange
    let end = min(NSMaxRange(range), surface.text.utf16.count)
    guard range.location < end else { return IndexSet() }
    return IndexSet(integersIn: range.location..<end)
  }
}

extension EditorDocument: TextSurfaceDelegate {
  public func surface(_ surface: any TextSurface, didChange edit: TextEdit) {
    let old = lineIndex
    lineIndex.apply(edit, replacement: surface.substring(in: edit.newRange))
    isDirty = true
    guard let syntax else { return }
    let text = surface.text
    var set = syntax.didChange(edit, text: text, old: old, new: lineIndex)
    set.formUnion(visibleSet)
    highlight(set, text: text)
    fresh = set
  }

  public func surface(_ surface: any TextSurface, focusDidChange focused: Bool) {
    onFocusChange?(focused)
  }

  /// 見える区間が動いた。最後の編集の後にまだ塗っていない部分だけ塗る。
  public func surfaceDidLayoutViewport(_ surface: any TextSurface) {
    guard syntax != nil else { return }
    let stale = visibleSet.subtracting(fresh)
    guard !stale.isEmpty else { return }
    highlight(stale, text: surface.text)
    fresh.formUnion(stale)
  }
}
