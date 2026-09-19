import CryptoKit
import Foundation

public enum EditorDocumentError: Error, Equatable {
  case unreadable(URL)
  case notUTF8(URL)
  /// ディスクの内容が最後に読んだ／書いたものと違う。force でない保存はディスクに触れずこれで返る。
  case diskChanged(URL)
}

/// 開いたファイル 1 つ。識別（URL）・言語・未保存の有無・行索引・構文層を持ち、本文の正は対になる
/// テキスト面にある（開いてから閉じるまで 1 対 1）。面の delegate として編集を受け、索引と構文木を
/// 追従させて塗り直す。
///
/// 塗り直す範囲は「構文木が変わった区間 ∪ 今見えている区間」。木の差分だけでは、隣のノードの変化で
/// 役割が変わるのに自分の区間は変わらない字（呼び出しになった識別子など）が古い色のまま残る。
/// 見えている区間を毎回塗り直し、見えていない区間は次に見えたときに 1 回だけ塗る（`fresh` が
/// 「最後の編集の後に塗った区間」を持つ）。塗りは常に塗り直す区間の中に閉じる（→ `SyntaxLayer`）。
///
/// ディスクの姿（最後に読んだ／書いたファイルのバイト列のダイジェスト）も持ち、外部変更は監視の通知と保存の直前に
/// 実ファイルを読み直して比べる（`reconcileWithDisk` / `save`）。baseline（比べる底の本文）を持てば、
/// 本文との行差分（ハンク）を編集に追従させ、行の印（git ガター）として面へ押す。
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
  /// ディスクの内容が最後に読んだ／書いたものと違い、差し替えられていない（未保存の本文がある、または
  /// UTF-8 として読めない内容が書かれている）。照合のたびに導出し直す（消えた・同じ・差し替えたなら false）。
  public private(set) var isDiskChanged = false {
    didSet { if isDiskChanged != oldValue { onDiskChange?(isDiskChanged) } }
  }
  public var onDiskChange: ((Bool) -> Void)?
  /// テキスト面が first responder になった／やめた。
  public var onFocusChange: ((Bool) -> Void)?
  /// 比べる底の本文（index 版など）。無ければハンクは空。置くと即時にハンクを作り直す。
  public var baseline: String? {
    didSet {
      guard baseline != oldValue else { return }
      needsHunks = false
      rebuildHunks()
    }
  }
  /// baseline と本文の行差分。編集は runloop 1 回に間引いて作り直す。
  public private(set) var hunks: [LineHunk] = [] {
    didSet { if hunks != oldValue { onHunksChange?() } }
  }
  public var onHunksChange: (() -> Void)?
  /// インデントの単位（1 段のスペース数）。開いたとき、および本文を丸ごと置き換えたときに本文から検出し直し、
  /// 面へ押す。
  public private(set) var indentUnit = IndentUnit.fallback
  /// 面の見えている範囲が変わった（スクロール・窓の高さ）。
  public var onViewportChange: (() -> Void)?
  /// 面の選択が変わった。
  public var onSelectionChange: (() -> Void)?
  /// 本文が変わった。索引・構文木・色付けの更新の後に届く（構文の事実を読み直してよい）。
  public var onTextChange: ((TextChange) -> Void)?
  private let syntax: SyntaxLayer?
  /// 最後の編集の後に塗った区間。編集のたびに（変わった区間 ∪ 可視区間）へ置き直す。
  private var fresh = IndexSet()
  /// 最後に読んだ／書いたファイルのバイト列のダイジェスト（ディスクの姿）。
  private var diskDigest: SHA256Digest
  /// 開いた／差し替えたときにファイルが UTF-8 BOM で始まっていたか。保存で同じように書き戻す。
  private var hasBOM: Bool
  private var needsHunks = false
  /// ディスクの内容で本文を差し替えている間は、その編集で未保存を立てない。
  private var isReplacingFromDisk = false

  /// ファイルから読んだ内容。本文のほかに、ディスクの姿と BOM の有無を持つ（文書がそのまま引き継ぐ）。
  public struct Contents {
    public let text: String
    fileprivate let digest: SHA256Digest
    fileprivate let hasBOM: Bool
  }

  private static let bom = Data([0xEF, 0xBB, 0xBF])

  /// ファイルを UTF-8 として読む。読めない・UTF-8 でないは throw。先頭の BOM は本文に含めない。
  public static func read(_ url: URL) throws -> Contents {
    guard let data = try? Data(contentsOf: url) else { throw EditorDocumentError.unreadable(url) }
    let hasBOM = data.starts(with: bom)
    guard let text = String(data: hasBOM ? data.dropFirst(bom.count) : data, encoding: .utf8)
    else { throw EditorDocumentError.notUTF8(url) }
    return Contents(text: text, digest: SHA256.hash(data: data), hasBOM: hasBOM)
  }

  /// `surface` は `contents.text` で作った面。
  public init(
    url: URL, contents: Contents, surface: any TextSurface, registry: LanguageRegistry
  ) {
    self.url = url
    self.surface = surface
    language = SyntaxLanguage.detect(url: url)
    let text = surface.text
    lineIndex = LineIndex(text: text)
    diskDigest = contents.digest
    hasBOM = contents.hasBOM
    syntax = language.flatMap { registry.configuration(for: $0) }
      .flatMap { try? SyntaxLayer(configuration: $0, registry: registry) }
    surface.delegate = self
    applyIndentUnit(of: text)
    if let syntax {
      highlight(syntax.parseAll(text, lineIndex: lineIndex), text: text)
      fresh = IndexSet(integersIn: 0..<text.utf16.count)
    }
  }

  /// `range` の中の comment 役割の区間（昇順）。文法が無ければ空。窓もキャッシュも持たない——俯瞰が行の縮図を
  /// 組むときにチャンクごとに引く。
  public func commentRanges(in range: NSRange) -> [NSRange] {
    guard let syntax, range.length > 0 else { return [] }
    let set = IndexSet(integersIn: range.location..<NSMaxRange(range))
    return syntax.highlights(in: set) { [surface] in surface.substring(in: $0) }
      .filter { $0.role == .comment }.map(\.range).sorted { $0.location < $1.location }
  }

  private func applyIndentUnit(of text: String) {
    indentUnit = IndentUnit.detect(in: text)
    surface.setIndentUnit(indentUnit)
  }

  /// 面の本文をそのまま UTF-8 で書く（改行・末尾改行は本文のまま。開いたとき BOM があれば付け直す）。
  /// 保存は undo の区切りでもある。force でなければ直前にディスクと照合する（監視の通知が届く前でも
  /// 同じ判定）——未編集なら差し替えてから書き、未保存の本文があれば `diskChanged` で失敗して
  /// ディスクに触れない。
  public func save(force: Bool = false) throws {
    if !force {
      reconcileWithDisk()
      if isDiskChanged { throw EditorDocumentError.diskChanged(url) }
    }
    let data = (hasBOM ? Self.bom : Data()) + Data(surface.text.utf8)
    try data.write(to: url, options: .atomic)
    diskDigest = SHA256.hash(data: data)
    isDirty = false
    isDiskChanged = false
    surface.markUndoBoundary()
  }

  /// 実ファイルを読み直してディスクの姿と比べる。違っていて未保存でなければ本文を差し替え（undo 可、
  /// 未保存にならない、undo の区切り）、未保存なら `isDiskChanged` を立てて本文は保つ。
  /// 消えた・同じ内容なら印を消す。UTF-8 でない内容（別の符号化・バイナリ）が書かれていれば一致を
  /// 証明できないので、差し替えずに印を立てる（外の書き込みを ⌘S で潰さない）。
  public func reconcileWithDisk() {
    let onDisk: Contents
    do {
      onDisk = try Self.read(url)
    } catch EditorDocumentError.notUTF8 {
      isDiskChanged = true
      return
    } catch {
      isDiskChanged = false
      return
    }
    guard onDisk.digest != diskDigest else {
      isDiskChanged = false
      return
    }
    guard !isDirty else {
      isDiskChanged = true
      return
    }
    isReplacingFromDisk = true
    surface.replaceAll(with: onDisk.text)
    isReplacingFromDisk = false
    applyIndentUnit(of: onDisk.text)
    diskDigest = onDisk.digest
    hasBOM = onDisk.hasBOM
    surface.markUndoBoundary()
    isDiskChanged = false
  }

  private func highlight(_ set: IndexSet, text: String) {
    guard let syntax, !set.isEmpty else { return }
    surface.applyHighlights(syntax.highlights(in: set, text: text), in: set)
  }

  /// ハンクを作り直し、行の印を面へ押す。印はハンクが同じでも押す——同じ行の中の打鍵でハンクは変わらず
  /// 区間のオフセットだけが動く。
  private func rebuildHunks() {
    let text = surface.text
    hunks = baseline.map { LineDiff.hunks(base: $0, current: text) } ?? []
    surface.setLineMarks(LineMarks(hunks: hunks).spans(in: lineIndex, length: text.utf16.count))
  }

  /// 同じ runloop ターンに複数届いた編集（複数キャレット等）を 1 回の作り直しに畳む。
  private func scheduleHunks() {
    guard baseline != nil, !needsHunks else { return }
    needsHunks = true
    Task { @MainActor [weak self] in
      guard let self, needsHunks else { return }
      needsHunks = false
      rebuildHunks()
    }
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
    if !isReplacingFromDisk { isDirty = true }
    scheduleHunks()
    var changedRoles = IndexSet(integersIn: edit.newRange.location..<NSMaxRange(edit.newRange))
    defer { onTextChange?(TextChange(edit: edit, changedRoles: changedRoles)) }
    guard let syntax else { return }
    let text = surface.text
    changedRoles = syntax.didChange(edit, text: text, old: old, new: lineIndex)
    let set = changedRoles.union(visibleSet)
    highlight(set, text: text)
    fresh = set
  }

  public func surfaceDidScroll(_ surface: any TextSurface) {
    onViewportChange?()
  }

  public func surfaceDidChangeSelection(_ surface: any TextSurface) {
    onSelectionChange?()
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
