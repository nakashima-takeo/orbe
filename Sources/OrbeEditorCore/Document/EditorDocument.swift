import CryptoKit
import Foundation

public enum EditorDocumentError: Error, Equatable {
  case unreadable(URL)
  case notUTF8(URL)
  /// ディスクの内容が最後に読んだ／書いたものと違う。force でない保存はディスクに触れずこれで返る。
  case diskChanged(URL)
}

/// 開いたファイル 1 つ。識別（URL）・言語・未保存の有無と、本文の写し（ロープ）・版・役割の並びを持つ。本文の正は対になる
/// テキスト面にあり（開いてから閉じるまで 1 対 1）、文書は面の delegate として編集（置換後の文字列つき）を受けてロープを
/// 追う。本文を読むのはこのロープだけ——面の契約に本文を読む口は無い。
///
/// 構文色・行差分（ハンク）・検索・出現は、ロープの写し（版つき）から裏の仕事が作る。打鍵 1 回で main がするのは、ロープの
/// 置換・役割の並びのずらし・裏への依頼だけで、文書の大きさに依らない。裏の結果は受け取り箱に置かれ、main は今の版の結果なら
/// そのまま、古い版の結果はその後の編集でずらして使う（字から離れない）。役割は面に問われた区間を並びから引くだけ（色を
/// どこに置くかは面が決める。文書は窓もキャッシュも持たない）。
///
/// ディスクの姿（最後に読んだ／書いたファイルのバイト列のダイジェスト）も持ち、外部変更は監視の通知と保存の直前に
/// 実ファイルを読み直して比べる（`reconcileWithDisk` / `save`）。baseline（比べる底の本文）を持てば、本文との行差分を
/// 行の印（git ガター）として面へ押す。
@MainActor
public final class EditorDocument {
  /// 文書を初めて画面に出すとき、最初の色を待つ上限。
  public static let firstColorsWait: TimeInterval = 0.05

  public let url: URL
  public let language: SyntaxLanguage?
  public let surface: any TextSurface
  /// 本文の写し。面の本文と常に同じ。
  public private(set) var text: TextRope
  /// 文書全体の役割の並び。裏の最新の結果を、その後の編集に合わせてずらしたもの。
  public private(set) var roles: RoleRuns
  /// 本文の版と、届いていない結果を今の版まで写すための編集の記録。
  private var log = EditLog()
  /// 本文の版（編集 1 回で 1 進む）。
  public var version: Int { log.version }
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
  /// 比べる底の本文（index 版など）。無ければハンクは空。置くと裏へ行差分を頼む。
  public var baseline: String? {
    didSet {
      guard baseline != oldValue else { return }
      baselineGeneration += 1
      requestHunks()
    }
  }
  /// baseline と本文の行差分。編集の直後はずらした前のハンクで、裏の結果が届くと置き換わる。
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
  /// 本文が変わった（変わった最小の区間の編集）。ロープとずらした役割の更新の後に届く。
  public var onTextChange: ((TextEdit) -> Void)?
  /// 裏から届いた役割で、役割が変わった区間（今の本文の上）。
  public var onRolesChange: ((IndexSet) -> Void)?
  /// 区間の列の問い（`analyze`）の結果（今の本文の上へずらしたもの）。問いが今と違うかは受け手が見る。
  public var onAnalysis: ((AnalysisRequest, [NSRange]) -> Void)?

  private let inbox: AnalysisInbox
  private let syntax: SyntaxWorker?
  private let analysis: DocumentAnalysis
  /// 最後に受け取った構文の結果の版と、そのとき見えている範囲・全体の作り直しが済んでいたか。
  private var syntaxState = SyntaxProgress(version: 0, visibleReady: false, complete: false)
  private var baselineGeneration = 0
  /// 行差分を頼んで、まだその結果を受け取っていない版。
  private var pendingHunks: Int?
  /// 区間の列の問いのうち、まだ結果を受け取っていないもの（種類ごとに最新の問いと版）。
  private var pendingRanges: [AnalysisRequest.Kind: (request: AnalysisRequest, version: Int)] = [:]
  private var hasBeenShown = false
  /// 最後に読んだ／書いたファイルのバイト列のダイジェスト（ディスクの姿）。
  private var diskDigest: SHA256Digest
  /// 開いた／差し替えたときにファイルが UTF-8 BOM で始まっていたか。保存で同じように書き戻す。
  private var hasBOM: Bool
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

  /// `surface` は `contents.text` で作った面。ロープは面ではなく読んだ内容から組む。構文の裏の仕事はここで起き、
  /// 全体の解析と先頭の画面ぶんの役割を作り始める（待たない）。
  public init(
    url: URL, contents: Contents, surface: any TextSurface, registry: LanguageRegistry
  ) {
    self.url = url
    self.surface = surface
    language = SyntaxLanguage.detect(url: url)
    let text = TextRope(contents.text)
    self.text = text
    roles = RoleRuns(length: text.length)
    diskDigest = contents.digest
    hasBOM = contents.hasBOM
    let inbox = AnalysisInbox()
    self.inbox = inbox
    syntax = language.flatMap { registry.configuration(for: $0) }.flatMap {
      try? SyntaxWorker(
        text: text, version: 0, configuration: $0, registry: registry, inbox: inbox)
    }
    analysis = DocumentAnalysis(inbox: inbox)
    inbox.setWake { [weak self] in self?.receive() }
    surface.delegate = self
    applyIndentUnit()
  }

  /// 閉じた文書の写しは裏で手放す（大きな木の解放を main で行わない）。
  deinit {
    let released = (text, roles)
    DispatchQueue.global(qos: .utility).async { withExtendedLifetime(released) {} }
  }

  /// 選択の先頭の位置の語（出現の強調・⌘F の種）。長い行はキャレットの前後の窓だけを読む（→ `Occurrences.wordWindow`）。
  public func word(at selection: NSRange) -> NSRange? {
    let row = text.row(containing: selection.location)
    let start = text.lineStart(row)
    var end = text.lineEnd(row)
    let tailStart = max(start, end - 2)
    for unit in text.units(in: NSRange(location: tailStart, length: end - tailStart)).reversed() {
      guard unit == 0x0A || unit == 0x0D else { break }
      end -= 1
    }
    let window = Occurrences.wordWindow(
      caret: selection.location, line: NSRange(location: start, length: end - start))
    return Occurrences.word(
      at: selection, text: text.substring(window), textStart: window.location)
  }

  /// 先頭に見えている行（小数。行 + 隠れ割合）と可視行数（小数）——俯瞰の式の入力。
  public var viewportLines: (first: CGFloat, visible: CGFloat) {
    let viewport = surface.viewport
    let row = CGFloat(text.row(containing: viewport.firstVisible))
    return (row + viewport.hiddenFraction, viewport.visibleLines)
  }

  /// 先頭行（小数）の位置へスクロールする（`viewport` の逆。行は行の数に収める）。
  public func scroll(toFirstLine line: CGFloat) {
    let clamped = min(max(0, line), CGFloat(text.lineCount - 1))
    let row = Int(floor(clamped))
    surface.scroll(toTop: text.lineStart(row), hiddenFraction: clamped - CGFloat(row))
  }

  /// 区間の列の問いを裏へ頼む。結果は `onAnalysis` に届く。
  public func analyze(_ request: AnalysisRequest) {
    pendingRanges[request.kind] = (request, version)
    analysis.post(request, text: text, version: version)
  }

  /// 文書を初めて画面に出す直前に呼ぶ。構文の裏の仕事が見えている範囲の役割を作り終えていなければ、最初の描画に色が
  /// 間に合うよう最大 `firstColorsWait` 待つ（越えたら無色で出し、後から色が付く）。2 回目以降は何もしない。
  public func prepareToShow() {
    guard !hasBeenShown else { return }
    hasBeenShown = true
    guard let syntax, !isFirstColorReady else { return }
    syntax.boost()
    _ = wait(until: .now() + Self.firstColorsWait) { $0.isFirstColorReady }
  }

  /// 裏の仕事（構文・行差分・問い）がすべて今の版に追いつき、その結果を受け取るまで待つ（最大 `timeout`）。追いついたら
  /// true。時間ではなく受け取り箱を見て待つ——描画やテストが、結果の出揃った状態を決定的に得る口。
  @discardableResult
  public func waitUntilCaughtUp(timeout: TimeInterval = 5) -> Bool {
    syntax?.boost()
    return wait(until: .now() + timeout) { $0.isCaughtUp }
  }

  /// 受け取り箱に結果が届くたびに受け取り、`done` が成り立つか期限が来るまで待つ。
  private func wait(until deadline: DispatchTime, _ done: (EditorDocument) -> Bool) -> Bool {
    receive()
    while !done(self) {
      guard inbox.wait(until: deadline) else { break }
      receive()
    }
    return done(self)
  }

  private var isFirstColorReady: Bool {
    syntax == nil || (syntaxState.version == version && syntaxState.visibleReady)
  }

  private var isCaughtUp: Bool {
    (syntax == nil || (syntaxState.version == version && syntaxState.complete))
      && pendingHunks == nil && pendingRanges.isEmpty
  }

  private func applyIndentUnit() {
    indentUnit = IndentUnit.detect(in: text.utf16)
    surface.setIndentUnit(indentUnit)
  }

  /// 本文をそのまま UTF-8 で書く（改行・末尾改行は本文のまま。開いたとき BOM があれば付け直す）。
  /// 保存は undo の区切りでもある。force でなければ直前にディスクと照合する（監視の通知が届く前でも
  /// 同じ判定）——未編集なら差し替えてから書き、未保存の本文があれば `diskChanged` で失敗して
  /// ディスクに触れない。
  public func save(force: Bool = false) throws {
    if !force {
      reconcileWithDisk()
      if isDiskChanged { throw EditorDocumentError.diskChanged(url) }
    }
    let data = (hasBOM ? Self.bom : Data()) + text.utf8Data()
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
    applyIndentUnit()
    diskDigest = onDisk.digest
    hasBOM = onDisk.hasBOM
    surface.markUndoBoundary()
    isDiskChanged = false
  }

  /// 行差分を裏へ頼む。baseline が無ければハンクは空。
  private func requestHunks() {
    guard let baseline else {
      pendingHunks = nil
      hunks = []
      pushLineMarks()
      return
    }
    pendingHunks = version
    analysis.postHunks(
      text: text, version: version, baseline: baseline, generation: baselineGeneration)
  }

  /// 行の印を面へ押す。印はハンクが同じでも押す——同じ行の中の打鍵でハンクは変わらず区間のオフセットだけが動く。
  private func pushLineMarks() {
    surface.setLineMarks(LineMarks(hunks: hunks).spans(in: text))
  }

  /// 受け取り箱の結果を取り、今の版へ写して置く。
  private func receive() {
    let contents = inbox.take()
    var changedRoles = IndexSet()
    for outcome in contents.syntax {
      guard let edits = log.edits(since: outcome.version) else { continue }
      changedRoles.formUnion(edits.reduce(outcome.changed) { $1.edit.track($0) })
    }
    if let outcome = contents.syntax.last, let edits = log.edits(since: outcome.version) {
      var latest = outcome.roles
      for record in edits { latest.apply(record.edit) }
      roles = latest
      syntaxState = SyntaxProgress(
        version: outcome.version, visibleReady: outcome.visibleReady, complete: outcome.complete)
    }
    if let outcome = contents.hunks, outcome.generation == baselineGeneration,
      let edits = log.edits(since: outcome.version)
    {
      hunks = edits.reduce(outcome.hunks) { $1.track($0) }
      if pendingHunks == outcome.version { pendingHunks = nil }
      pushLineMarks()
    }
    for outcome in contents.ranges.values {
      guard let pending = pendingRanges[outcome.request.kind], pending.request == outcome.request,
        let edits = log.edits(since: outcome.version)
      else { continue }
      if pending.version == outcome.version { pendingRanges[outcome.request.kind] = nil }
      onAnalysis?(outcome.request, edits.reduce(outcome.ranges) { $1.edit.track($0) })
    }
    discardSettledEdits()
    if !changedRoles.isEmpty {
      surface.rolesDidChange(changedRoles)
      onRolesChange?(changedRoles)
    }
  }

  /// 結果を待っている版のうち最も古いものまでの編集を捨てる。構文の裏の仕事は、最後に受け取った版より後ろのどの版の結果も
  /// 置きうる。
  private func discardSettledEdits() {
    var oldest = version
    if syntax != nil { oldest = min(oldest, syntaxState.version) }
    if let pendingHunks { oldest = min(oldest, pendingHunks) }
    for pending in pendingRanges.values { oldest = min(oldest, pending.version) }
    log.discard(through: oldest)
  }
}

extension EditorDocument: TextSurfaceDelegate {
  /// 面の編集は、置換の前後で変わらない先頭と末尾を落とした最小の区間の編集として写し・役割・構文・配り先へ渡す——外部変更の
  /// 差し替え（全体の置換として届く）でも、変わっていない字は役割を保ち、構文も差分で解析する。
  public func surface(_ surface: any TextSurface, didChange whole: TextEdit) {
    let edit = narrowed(whole)
    let start = text.point(at: edit.range.location)
    let oldEnd = text.point(at: NSMaxRange(edit.range))
    text.replace(edit.range, with: edit.replacement)
    let newEnd = text.point(at: NSMaxRange(edit.newRange))
    let record = log.append(
      edit, start: TextPoint(row: start.row, column: start.column),
      oldEnd: TextPoint(row: oldEnd.row, column: oldEnd.column),
      newEnd: TextPoint(row: newEnd.row, column: newEnd.column))
    roles.apply(edit)
    syntax?.post(record, text: text)
    if !isReplacingFromDisk { isDirty = true }
    if baseline != nil {
      hunks = record.track(hunks)
      pushLineMarks()
      requestHunks()
    }
    onTextChange?(edit)
  }

  /// 置換の前後で変わらない先頭と末尾を落とした編集。サロゲートの対は割らない。
  private func narrowed(_ edit: TextEdit) -> TextEdit {
    guard edit.range.length > 0, edit.replacementLength > 0 else { return edit }
    let old = text.units(in: edit.range)
    let new = ContiguousArray(edit.replacement.utf16)
    let limit = min(old.count, new.count)
    var prefix = 0
    while prefix < limit, old[prefix] == new[prefix] { prefix += 1 }
    if prefix > 0, UTF16.isLeadSurrogate(old[prefix - 1]) { prefix -= 1 }
    var suffix = 0
    while suffix < limit - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
      suffix += 1
    }
    if suffix > 0, UTF16.isTrailSurrogate(old[old.count - suffix]) { suffix -= 1 }
    guard prefix > 0 || suffix > 0 else { return edit }
    return TextEdit(
      range: NSRange(location: edit.range.location + prefix, length: old.count - prefix - suffix),
      replacement: String(decoding: new[prefix..<(new.count - suffix)], as: UTF16.self))
  }

  public func surfaceDidChangeViewport(_ surface: any TextSurface) {
    if let syntax {
      let viewport = surface.viewport
      let first = text.row(containing: viewport.firstVisible)
      let last = first + Int(viewport.visibleLines.rounded(.up))
      syntax.setVisible(
        NSRange(location: text.lineStart(first), length: text.lineEnd(last) - text.lineStart(first))
      )
    }
    onViewportChange?()
  }

  public func surfaceDidChangeSelection(_ surface: any TextSurface) {
    onSelectionChange?()
  }

  public func surface(_ surface: any TextSurface, focusDidChange focused: Bool) {
    onFocusChange?(focused)
  }

  public func surface(_ surface: any TextSurface, rolesIn range: NSRange) -> [HighlightSpan] {
    roles.roles(in: range)
  }

  public func surfaceLineCount(_ surface: any TextSurface) -> Int {
    text.lineCount
  }

  public func surface(_ surface: any TextSurface, lineContaining offset: Int) -> Int {
    text.row(containing: offset)
  }

  public func surface(_ surface: any TextSurface, rangeOfLine line: Int) -> NSRange {
    let start = text.lineStart(line)
    return NSRange(location: start, length: text.lineEnd(line) - start)
  }
}
