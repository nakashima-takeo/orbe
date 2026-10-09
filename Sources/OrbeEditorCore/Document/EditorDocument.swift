import CryptoKit
import Foundation
import os

/// 開いたファイル 1 つ。識別（URL）・言語・未保存の有無と、本文の写し（ロープ）・版・役割の並びを持つ。テキスト面とは
/// 開いてから閉じるまで 1 対 1 で、文書は面の delegate として編集（置換後の文字列つき）を受けてロープを追う。本文の正は
/// このロープで、面は写し（`surfaceContent`）を引いて描く——面の契約に本文を読む口は無い。
///
/// 構文色・行差分（ハンク）・検索・出現は、ロープの写し（版つき）から裏の仕事が作る。打鍵 1 回で main がするのは、ロープの
/// 置換・役割の並びのずらし・裏への依頼だけで、文書の大きさに依らない。裏の結果は受け取り箱に置かれ、main は今の版の結果なら
/// そのまま、古い版の結果はその後の編集でずらして使う（字から離れない）。面は役割の並びを写しごと引く（色をどこに置くかは
/// 面が決める）。
///
/// 未保存は、本文が保存時の本文（最後に開いた・保存した・ディスクから取り込んだ本文）と違うかで決める——戻し方（⌘Z・
/// 打ち直し・変換の取り消し）を問わない。打鍵で main がするのは長さの比較だけで、長さが同じなら未保存を立てたまま裏で
/// 中身を比べ、同じと分かった時点で下ろす（誤るときは未保存の側）。
///
/// ディスクと揃えた時点の姿（保存時の本文・ファイルのバイト列のダイジェスト・BOM）を持ち、外部変更は監視の通知と保存の
/// 直前に実ファイルを読み直して比べる（`reconcileWithDisk` / `save`）。baseline（比べる底の本文）を持てば、本文との
/// 行差分を行の印（git ガター）として面へ押す。
@MainActor
public final class EditorDocument {
  /// 文書を初めて画面に出すとき、最初の色を待つ上限。
  public static let firstColorsWait = SyntaxReception.firstColorsWait

  public let url: URL
  public let language: SyntaxLanguage?
  public let surface: any TextSurface
  /// 本文の写し。面はこれを引いて描く。
  public private(set) var text: TextRope
  /// 文書全体の役割の並び。裏の最新の結果を、その後の編集に合わせてずらしたもの。
  public private(set) var roles: RoleRuns
  /// 本文の版と、届いていない結果を今の版まで写すための編集の記録。
  private var log = EditLog()
  /// 本文の版（編集 1 回で 1 進む）。
  public var version: Int { log.version }
  /// 本文が保存時の本文と違う（または同じかを裏で確かめている）。
  public var isDirty: Bool { diskSync.isDirty }
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
  /// 行差分の上限（共通の先頭・末尾を落とした残りの行数の和。越えれば残り全体を 1 つの区間にする——`LineDiff`）。既定は
  /// ガターの値。変えると裏へ行差分を頼み直す。
  public var hunkLimit = LineDiff.maximumComparedLines {
    didSet {
      guard hunkLimit != oldValue else { return }
      baselineGeneration += 1
      requestHunks()
    }
  }
  /// baseline と本文の行差分。編集の直後はずらした前のハンクで、裏の結果が届くと置き換わる。
  public private(set) var hunks: [LineHunk] = []
  /// 字下げの作法（単位とタブか）。開いたとき、および本文を丸ごと置き換えたときに本文から検出し直し、面へ押す。
  public private(set) var indentation = Indentation.fallback
  /// 面の見えている範囲が変わった（スクロール・窓の高さ）。
  public var onViewportChange: (() -> Void)?
  /// 面の選択が変わった。
  public var onSelectionChange: (() -> Void)?
  /// 本文が変わった。面の編集の束ごとに 1 回、適用した順の編集の列（どれもその直前の本文の座標で、行の増減が分かる行と桁
  /// つき）で、写しと役割の更新の後に届く——受け手は列を順に畳めば、束の途中の本文を見ずに今の本文へ追いつく。
  public var onTextChange: (([VersionedEdit]) -> Void)?
  /// 区間の列の問い（`analyze`）の結果（今の本文の上へずらしたもの）。問いが今と違うかは受け手が見る。
  public var onAnalysis: ((AnalysisRequest, [NSRange]) -> Void)?

  private let inbox: AnalysisInbox
  private var reception: SyntaxReception
  private let analysis: DocumentAnalysis
  private var baselineGeneration = 0
  /// 行差分を頼んで、まだその結果を受け取っていない版。
  private var pendingHunks: Int?
  /// 区間の列の問いのうち、まだ結果を受け取っていないもの（種類ごとに最新の問いと版）。
  private var pendingRanges: [AnalysisRequest.Kind: (request: AnalysisRequest, version: Int)] = [:]
  /// ディスクと揃えた時点の姿と未保存の状態。BOM は保存で同じように書き戻す。
  private var diskSync: DiskSync {
    didSet { if isDirty != oldValue.isDirty { onDirtyChange?(isDirty) } }
  }
  /// ディスクの内容で本文を差し替えている間は、その編集で未保存を動かさない（差し替えの後に揃えた姿を置く）。
  private var isReplacingFromDisk = false

  /// `surface` は、まだ文書と結ばれていない面。ロープは読んだ内容から組み、面は結ばれたときに写しを引く。構文の裏の仕事はここで起き、
  /// 全体の解析と先頭の画面ぶんの役割を作り始める（待たない）。
  public convenience init(
    url: URL, contents: Contents, surface: any TextSurface, registry: LanguageRegistry
  ) {
    self.init(
      url: url, contents: contents, surface: surface, registry: registry,
      quietDelay: SyntaxWorker.quietDelay)
  }

  /// `quietDelay` は、最後の編集から構文の見えていない範囲を作り始めるまでの待ち（テストが差し替える）。
  init(
    url: URL, contents: Contents, surface: any TextSurface, registry: LanguageRegistry,
    quietDelay: DispatchTimeInterval
  ) {
    self.url = url
    self.surface = surface
    language = SyntaxLanguage.detect(url: url)
    let text = TextRope(contents.text)
    self.text = text
    roles = RoleRuns(length: text.length)
    diskSync = DiskSync(.init(text: text, digest: contents.digest, hasBOM: contents.hasBOM))
    let inbox = AnalysisInbox()
    self.inbox = inbox
    reception = SyntaxReception(
      text: text, version: 0, language: language, registry: registry, inbox: inbox,
      quietDelay: quietDelay)
    analysis = DocumentAnalysis(inbox: inbox)
    inbox.setWake { [weak self] in self?.receive() }
    surface.delegate = self
    applyConventions()
  }

  /// 閉じた文書の大きな部品を手放す口（既定は裏で手放す）。テストは手放す時機を差し替える。
  var releaseParts: @Sendable (OSAllocatedUnfairLock<ReleasedParts?>) -> Void = { parcel in
    DispatchQueue.global(qos: .utility).async { parcel.withLock { $0 = nil } }
  }

  /// 構文の裏の仕事に走っている解析を打ち切らせ、閉じた文書の写し・保存時の本文・役割の並び・構文木を持つ裏の仕事は
  /// 裏で手放す（大きな木の解放を main で行わない）。裏へ渡す前に文書の欄から外す——欄は deinit の後に main で解放される
  /// ので、欄に残すと裏が先に済んだとき最後の解放が main で起きる。
  deinit {
    let parcel = OSAllocatedUnfairLock<ReleasedParts?>(
      initialState: ReleasedParts(
        text: text, synced: diskSync.releaseText(), roles: roles, syntax: reception.release()))
    text = TextRope()
    roles = RoleRuns(length: 0)
    releaseParts(parcel)
  }

  /// 構文の裏の仕事（無ければ nil）。
  var syntax: SyntaxWorker? { reception.worker }

  /// 初めて画面に出す前の上限待ちを済ませた。
  var hasBeenShown: Bool { reception.hasBeenShown }

  /// 区間の列の問いを裏へ頼む。結果は `onAnalysis` に届く。
  public func analyze(_ request: AnalysisRequest) {
    pendingRanges[request.kind] = (request, version)
    analysis.post(request, text: text, version: version)
  }

  /// 文書を初めて画面に出す直前に呼ぶ。構文の裏の仕事が見えている範囲の役割を作り終えていなければ、最初の描画に色が
  /// 間に合うよう最大 `firstColorsWait` 待つ（越えたら無色で出し、後から色が付く）。2 回目以降は何もしない。
  public func prepareToShow() {
    guard reception.beginShowing(ready: isFirstColorReady) else { return }
    _ = wait(until: .now() + Self.firstColorsWait) { $0.isFirstColorReady }
  }

  /// 裏の仕事（構文・比較・行差分・問い）がすべて今の版に追いつき、その結果を受け取るまで待つ（最大 `timeout`）。
  /// 追いついたら true。時間ではなく受け取り箱を見て待つ——描画やテストが、結果の出揃った状態を決定的に得る口。待つ間
  /// だけ、構文の見えていない範囲も打鍵が止むのを待たずに作らせる。
  @discardableResult
  public func waitUntilCaughtUp(timeout: TimeInterval = 5) -> Bool {
    SyntaxReception.hurrying(syntax) { wait(until: .now() + timeout) { $0.isCaughtUp } }
  }

  /// 受け取り箱に結果が届くたびに受け取り、`done` が成り立つか期限が来るまで待つ。
  private func wait(until deadline: DispatchTime, _ done: (EditorDocument) -> Bool) -> Bool {
    SyntaxReception.wait(on: inbox, until: deadline, receive: receive) { done(self) }
  }

  var isFirstColorReady: Bool { reception.isFirstColorReady(at: version) }

  /// 受け取った結果で、裏の仕事がすべて今の版に追いついている（待たず、裏を急かさない）。
  var isCaughtUp: Bool {
    reception.isComplete(at: version) && diskSync.dirtiness != .checking && pendingHunks == nil
      && pendingRanges.isEmpty
  }

  /// 本文の作法（字下げ・改行）を検出し直して面へ押す。
  private func applyConventions() {
    indentation = Indentation.detect(in: text.utf16)
    surface.setIndentation(indentation)
    surface.setLineBreak(LineBreak.detect(in: text.utf16))
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
    let hasBOM = diskSync.snapshot.hasBOM
    let data = (hasBOM ? Self.bom : Data()) + text.utf8Data()
    try data.write(to: url, options: .atomic)
    diskSync.sync(.init(text: text, digest: SHA256.hash(data: data), hasBOM: hasBOM))
    isDiskChanged = false
    surface.markUndoBoundary()
  }

  /// 実ファイルを読み直して揃えた姿と比べる。消えた・揃えた姿と同じなら印を消す。違っていて、読んだ本文が今の本文と
  /// 同じなら、本文に触れずにそれを揃えた姿として受け入れる（未保存も印も消える）。そうでなく未保存でなければ本文を
  /// 差し替え（undo 可、未保存にならない、undo の区切り）、未保存なら `isDiskChanged` を立てて本文は保つ。
  /// UTF-8 でない内容（別の符号化・バイナリ）が書かれていれば一致を証明できないので、差し替えずに印を立てる（外の
  /// 書き込みを ⌘S で潰さない）。
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
    guard onDisk.digest != diskSync.snapshot.digest else {
      isDiskChanged = false
      return
    }
    if TextRope(onDisk.text).hasSameContent(as: text) {
      diskSync.sync(.init(text: text, digest: onDisk.digest, hasBOM: onDisk.hasBOM))
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
    applyConventions()
    diskSync.sync(.init(text: text, digest: onDisk.digest, hasBOM: onDisk.hasBOM))
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
      text: text, version: version, baseline: baseline, limit: hunkLimit,
      generation: baselineGeneration)
  }

  /// 行の印を面へ押す。印はハンクが同じでも押す——同じ行の中の打鍵でハンクは変わらず区間のオフセットだけが動く。
  private func pushLineMarks() {
    surface.setLineMarks(LineMarks(hunks: hunks).spans(in: text))
  }

  /// 受け取り箱の結果を取り、今の版へ写して置く。比較が未保存を下ろしたとき外部変更の印が立っていれば、最後に照合し
  /// 直す（未保存でなくなったので外の内容に差し替わる）——差し替えは打鍵と同じ編集の道を通るので、ほかの結果を置き
  /// 終えるまで本文を変えない。
  private func receive() {
    let contents = inbox.take()
    let synced = contents.comparison.map { diskSync.settle($0, version: version) } ?? false
    let changedRoles = reception.receive(contents.syntax, roles: &roles) { log.edits(since: $0) }
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
      onAnalysis?(
        outcome.request,
        EditSweep.batches(applied: edits.map(\.edit)).reduce(outcome.ranges) { $1.track($0) })
    }
    discardSettledEdits()
    if !changedRoles.isEmpty { surface.rolesDidChange(changedRoles) }
    if synced, isDiskChanged { reconcileWithDisk() }
  }

  /// 結果を待っている版のうち最も古いものまでの編集を捨てる。構文の裏の仕事は、最後に受け取った版より後ろのどの版の結果も
  /// 置きうる。
  private func discardSettledEdits() {
    var oldest = version
    if let received = reception.receivedVersion { oldest = min(oldest, received) }
    if let pendingHunks { oldest = min(oldest, pendingHunks) }
    for pending in pendingRanges.values { oldest = min(oldest, pending.version) }
    log.discard(through: oldest)
  }
}

extension EditorDocument: TextSurfaceDelegate {
  /// 面の編集の束を後ろから 1 つずつ当てる——束の範囲は束の前の座標なので、後ろから当てればどれもその直前の本文の座標のまま
  /// 使える（座標の変換はここ 1 か所）。どの編集も、変わらない先頭と末尾を落とした最小の区間として写し・役割・構文・配り先へ
  /// 渡す（外部変更の差し替えでも、変わっていない字は役割を保ち、構文も差分で解析する）。版は編集 1 つで 1 進み、行の印・
  /// 行差分の依頼・配り先への知らせは束ごとに 1 回。
  public func surface(_ surface: any TextSurface, didChange edits: [TextEdit]) {
    guard !edits.isEmpty else { return }
    var applied: [VersionedEdit] = []
    applied.reserveCapacity(edits.count)
    var tracked = hunks
    for whole in edits.reversed() {
      let record = apply(whole.narrowed(replacing: text.units(in: whole.range)))
      if baseline != nil { tracked = record.track(tracked) }
      applied.append(record)
    }
    hunks = tracked
    if !isReplacingFromDisk, diskSync.textDidChange(length: text.length) {
      analysis.postComparison(text: text, version: version, synced: diskSync.snapshot.text)
    }
    if baseline != nil {
      pushLineMarks()
      requestHunks()
    }
    // 届きうる結果が無ければ、写すための記録は要らない（結果が一つも来ない文書で、差し替えの本文が溜まり続けない）。
    if syntax == nil, pendingHunks == nil, pendingRanges.isEmpty { log.discard(through: version) }
    onTextChange?(applied)
  }

  private func apply(_ edit: TextEdit) -> VersionedEdit {
    let start = text.point(at: edit.range.location)
    let oldEnd = text.point(at: NSMaxRange(edit.range))
    text.replace(edit.range, with: edit.replacement)
    let newEnd = text.point(at: NSMaxRange(edit.newRange))
    let record = log.append(edit, start: start, oldEnd: oldEnd, newEnd: newEnd)
    roles.apply(edit)
    reception.worker?.post(record, text: text)
    return record
  }

  public func surfaceDidChangeViewport(_ surface: any TextSurface) {
    reception.setVisible(SyntaxReception.lines(of: surface.viewport, in: text), in: text)
    onViewportChange?()
  }

  public func surfaceDidChangeSelection(_ surface: any TextSurface) {
    onSelectionChange?()
  }

  public func surface(_ surface: any TextSurface, focusDidChange focused: Bool) {
    onFocusChange?(focused)
  }

  public func surfaceContent(_ surface: any TextSurface) -> SurfaceContent {
    SurfaceContent(text: text, roles: roles, version: version)
  }
}
