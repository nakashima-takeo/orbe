import Foundation
import OrbeEditorCore

/// diff 1 つ——根の下の 1 つのパスの、古い側と新しい側と、その行差分。両側の本文は種類ごとの出どころ（`EditorDiffSource`）が
/// 決める——作業ツリー: index の版 ↔ 文書（Files の開いている文書と同じ文書と面。開いていれば未保存を含む今の本文で、diff の中でも
/// 編集できる）／ステージ済み: HEAD の版（rename なら元のパス）↔ index の版／PR: PR のマージベースのコミットの版（rename
/// なら元のパス）↔ PR の先頭のコミットの版。diff が持つのは、種類に依らない見せ方・面・並び・初めての位置決めと、版の本文
/// から作る読むだけの文書。両側とも版の本文なら、どちらかが変わったときに 1 回、両側と並びを入れ替える——行差分をその場で
/// 取るか裏で取るかは本文から決め（→ `diffsInPlace`）、ファイルとサブモジュールの置き換えは行差分を取らない。
///
/// 見せ方（インライン / 並列）と見え方の付け外しは `present` / `dismiss` の 2 つの口だけで行う。見せていない間は版と
/// 文書の変化を追わず、見せたときに今の版で作り直す（打鍵中に隠れた diff が裏の仕事を起こさない）。
@MainActor
final class EditorDiff {
  /// diff の上限——diff を出している間の行差分の上限。編集の数で切るので、大きなファイルの離れた変更も行ごとに取り、
  /// 裏の時間は 1MB 級でも 1 秒未満に収まる。
  static let hunkLimit = LineDiff.Limit.edits(10_000)

  let id: Key
  let source: any EditorDiffSource
  let surfaces: EditorSurfaces
  /// 古い側と、新しい側が版の本文のときの新しい側（その面も diff が持つ）。その版に無い側も空の本文の文書を持つ（面は空の
  /// 行を 1 つ持つが、大きさ `oldSide`・`newRevisionSide` は 0 行で、その行に番号を描かない）。
  private(set) var old: RevisionDocument?
  private(set) var newRevision: RevisionDocument?
  private var newRevisionSurface: (any TextSurface)?
  /// 並列の古い側の面（並列で見せている間だけ）。
  var oldSurface: (any TextSurface)?
  /// 版の本文どうしの並び——行差分。ファイルとサブモジュールの置き換えなら、丸ごとの置き換え（新しい側が文書なら、
  /// 文書のハンクを直に使う——`currentRows`）。
  private(set) var revisionHunks: [LineHunk] = []
  /// `revisionHunks` を作った両側の本文と、`revisionHunks` が行差分か。この値は、両側を入れ替えて並びを置いたときだけ
  /// 付け、どちらかの側が替われば外す——どの経路で側が替わっても、この値が付いている間だけ、`revisionHunks` は今の両側の
  /// 並びである（→ `currentRows`）。
  private(set) var revisionHunksSides: (texts: SideTexts, lineDiff: Bool)?
  private(set) var content: Content = .loading
  /// 面の焦点が変わった（古い側・新しい側の版の本文の面。作り直した文書にも結び直す）。
  var onFocusChange: ((Bool) -> Void)?
  /// 見せている見せ方（見せていなければ nil）。
  private(set) var presented: Mode?
  /// 中身・面・並びが変わった・初めての位置を決めた（見せている間だけ。pane が本体を置き直す）。
  var onPresentationChange: (() -> Void)?
  /// 今の古い側・新しい側の本文の元（その版に無ければ nil。まだ決めていなければ外側の nil）と大きさ。
  private(set) var oldSource: String??
  private var newSource: String??
  private(set) var oldSide = DiffRows.Side(nil)
  private(set) var newRevisionSide = DiffRows.Side(nil)
  /// 新しい側が文書のとき、古い側が文書の行差分の底であるか。そうでなければ、並びは丸ごとの置き換え。
  private(set) var oldIsBase = true
  /// 裏で行差分を取っている両側の版の本文（取っていなければ nil）。
  private var revisionsComputing: SideTexts?
  /// 見せている側と並びが、出どころの今の材料に揃っていない（出どころが待つと答えた、または頼んだ行差分が届いていない）。
  private(set) var pending = false
  /// 見せていない間に変わった。
  private var stale = true
  /// 初めての位置決めの段階。
  var placement = Placement.catchingUp
  /// 初めて画面に出す前の色の上限待ちを済ませた（diff ごとに 1 回。版の本文を作り直しても待ち直さない）。
  private(set) var hasBeenShown = false
  /// 面を置き換えた・外した（pane が本体を置き直す）。
  var surfacesChanged = false
  /// 新しい側の版の面を作り直したとき、新しい面で先頭に置く所。
  var carried: Carried?
  /// PR の diff のコメントの層（ほかの種類の diff には無い）。
  let comments: PrCommentLayer?

  init(
    id: Key, source: any EditorDiffSource, surfaces: EditorSurfaces,
    comments: PrCommentLayer? = nil
  ) {
    self.id = id
    self.source = source
    self.surfaces = surfaces
    self.comments = comments
    source.onChange = { [weak self] change in
      switch change {
      case .material: self?.sourcesDidChange()
      case .document(let previous): self?.documentDidSwitch(from: previous)
      }
    }
    comments?.onRowsChange = { [weak self] in self?.applyRows() }
    comments?.onRevealChange = { [weak self] in self?.revealRequestedThread() }
  }

  /// 種類の出どころで開く。作業ツリー diff は `documents`（セッション）から新しい側の文書を引く。テキスト面を作れなければ
  /// `EditorSurfaceError.noMetalDevice` で失敗する。
  convenience init(id: Key, documents: Documents, surfaces: EditorSurfaces) throws {
    switch id.kind {
    case .workingTree:
      try self.init(
        id: id, source: EditorDiffWorkingTree(id: id, documents: documents), surfaces: surfaces)
    case .staged: self.init(id: id, source: EditorDiffStaged(id: id), surfaces: surfaces)
    case .pullRequest(let state):
      let source = EditorDiffPullRequest(id: id, state: state)
      self.init(
        id: id, source: source, surfaces: surfaces,
        comments: PrCommentLayer(pullRequest: source, language: surfaces.language))
    }
  }

  // MARK: - 側

  /// 新しい側の文書（出どころが新しい側に文書を使っていなければ nil）。
  var document: EditorDocument? { source.document }

  /// 主の入力欄（PR のコメントの返信・新しいコメントの欄）が居る面（無ければ nil）。
  var primaryFieldSurface: (any TextSurface)? { comments?.primaryFieldSurface }

  /// 新しい側の面（作業ツリーなら文書の面、ほかは diff が持つ面。中身が見せられなければ nil）。
  var newSurface: (any TextSurface)? {
    guard content == .ready else { return nil }
    return document?.surface ?? newRevisionSurface
  }

  /// 新しい側の文書が `previous` から替わった（出どころが知らせる）——前の文書をコードの見え方に戻し、今の文書の
  /// ハンクを追う（見せていれば）。面が替わるので古い側の面も閉じ、pane に置き直させる。新しい側で並びを置けるように
  /// なるまで、中身は「読み込み中」（本体に何も出さない。開くときと同じ）——文書が無くなって版の本文に替わるときも同じ。
  private func documentDidSwitch(from previous: EditorDocument?) {
    dropOldSurface()
    surfacesChanged = true
    content = .loading
    if presented != nil, let previous { restoreCode(previous) }
    guard presented != nil, let document else { return }
    document.onHunksChange = { [weak self] in self?.sourcesDidChange() }
    document.hunkLimit = Self.hunkLimit
  }

  // MARK: - 付け替え（cd で連が畳まれた）

  /// 新しい側を、同じ実体の文書 `next` にする（セッションが勝ち負けを決めた勝者。文書を持っていなければ、作業ツリーの
  /// 姿より未保存の `next` が先に立つ）。前の文書は手放さない（結線の後始末はセッションがまとめてする）。作り直しは
  /// 積むだけで、見せていれば `settle` で行う。新しい側に文書を使わない diff では何もしない。
  func replaceDocument(with next: EditorDocument) {
    let previous = document
    guard source.replaceDocument(with: next) else { return }
    documentDidSwitch(from: previous)
    stale = true
  }

  /// 新しい側の文書の未保存が変わった（セッションが配る）。未保存の間に保留した作業ツリーの読み直しを、未保存でなくなった
  /// 時点で行う。
  func documentDirtyDidChange() {
    source.documentDirtyDidChange()
  }

  /// 本体に出ていて面が見えている間の始まりと終わり（pane が対で呼ぶ。→ `EditorDiffSource.beginWatching`）。
  func beginWatching() { source.beginWatching() }
  func endWatching() { source.endWatching() }

  /// 積んだ作り直しを、見せていれば今行う。
  func settle() {
    guard stale, presented != nil else { return }
    refresh()
  }

  // MARK: - 見せる

  /// 見せ方 `mode` で見せる——古い側・新しい側の本文と並びを今の版に合わせ、面に diff の見え方を載せる。並列なら古い側の
  /// 面を作り、新しい側の面とスクロールを共にする。初めて見せるときは最初の変更区間へ送る。
  func present(_ mode: Mode) {
    let switching = presented != nil && presented != mode
    if switching { dropOldSurface() }
    presented = mode
    document?.onHunksChange = { [weak self] in self?.sourcesDidChange() }
    document?.hunkLimit = Self.hunkLimit
    if stale { refresh() } else { applyRows() }
  }

  /// 初めての位置を決めた画面を出す直前の、色の上限待ち（diff ごとに 1 回）。古い側の版の文書・新しい側の版の文書・作業
  /// ツリーの文書を、1 つの期限（今から `EditorDocument.firstColorsWait`）まで順に待つ。待つ前に見えている範囲——インラインの
  /// 古い側は見えている削除行——を裏へ渡す。位置を決める前に出る画面と、待った後に作り直した版の文書では待たない。
  func prepareToShow() {
    guard content == .ready, placement == .placed, !hasBeenShown else { return }
    hasBeenShown = true
    viewportDidChange()
    let deadline = DispatchTime.now() + EditorDocument.firstColorsWait
    old?.prepareToShow(until: deadline)
    newRevision?.prepareToShow(until: deadline)
    document?.prepareToShow(until: deadline)
  }

  /// 見せるのをやめる——古い側の面を閉じ（スクロールの共有が外れる）、文書の面にコードの見え方を戻し、文書のハンクを
  /// 追うのをやめる（次に見せるときに今の版で作り直す）。
  func dismiss() {
    guard presented != nil else { return }
    presented = nil
    stale = true
    dropOldSurface()
    if let document { restoreCode(document) }
  }

  /// 文書の面をコードの見え方に戻し、文書のハンクを追うのをやめる。
  private func restoreCode(_ document: EditorDocument) {
    document.onHunksChange = nil
    SurfaceLook.code.apply(to: document.surface, document: document)
  }

  /// 並列の古い側の面を閉じる（view を本体から外すのは pane——焦点を持っていれば、外す前に新しい行き先を決める）。
  private func dropOldSurface() {
    old?.detach()
    guard oldSurface != nil else { return }
    oldSurface = nil
    surfacesChanged = true
  }

  /// 面を置き換えた・外したら pane へ知らせる。
  private func settleSurfaces() {
    guard surfacesChanged else { return }
    surfacesChanged = false
    onPresentationChange?()
  }

  /// 新しい側の面の見えている範囲が変わった（インラインでは古い側の見えている削除行を先に色付けする）。
  func viewportDidChange() {
    guard presented != nil, let surface = newSurface else { return }
    if placement != .placed || carried != nil { placeFirstView(on: surface) }
    revealRequestedThread()
    sendVisibleRemovedLines(on: surface)
  }

  /// 新しい側の文書の本文が変わった（diff の中の編集・外部変更の差し替え）。古い側が文書の底ではない diff
  /// （`oldReplacesWhole`）は、並びを今の行の数で置き直す。この diff では、新しい側の文書は底を持たず、ハンクの知らせも
  /// 来ない。
  func documentTextDidChange() {
    guard presented != nil, oldReplacesWhole else { return }
    sourcesDidChange()
  }

  // MARK: - 出どころ

  /// 出どころの材料が変わった。見せていれば今作り直し、見せていなければ次に見せるときに作り直す。
  func sourcesDidChange() {
    stale = true
    guard presented != nil else { return }
    refresh()
  }

  // MARK: - 作り直し

  /// 今の版の本文の状態から中身・側・行差分を作り直し、見せていれば並びを置く。
  private func refresh() {
    stale = false
    let next = resolve()
    if next != content {
      content = next
      if next != .ready { dropOldSurface() }
      surfacesChanged = true
    }
    applyRows()
    settleSurfaces()
  }

  /// 出どころの答えに従って、両側と並びを今の材料に合わせ、中身を決める。実行中の行差分の依頼は、出どころが答えた両側の
  /// 本文がその依頼の本文と同じときだけ続けて待つ。出どころが別の本文を答えた後や、表示できないと答えた後に届いた結果は使わない。
  private func resolve() -> Content {
    let computing = revisionsComputing
    revisionsComputing = nil
    pending = false
    // 出どころが `resolve` の中で新しい側の文書を替えると、その知らせ（→ `documentDidSwitch`）で中身が読み込み中に戻るので、
    // 待つ間の中身は答えを受けた後で決める。
    let resolution = source.resolve()
    let waiting: Content = content == .ready ? .ready : .loading
    switch resolution {
    case .wait:
      oldIsBase = true
      pending = true
      return waiting
    case .unavailable(let reason):
      return .unavailable(reason)
    case .document(let base):
      oldIsBase = true
      setOld(base)
      return .ready
    case .documentReplacing(let old):
      oldIsBase = false
      setOld(old)
      return .ready
    case .revisionsReplacing(let texts):
      oldIsBase = true
      swapRevisions(texts, lineDiff: false) { old, new in
        [LineHunk(old: 0..<DiffRows.Side(old).lines, new: 0..<DiffRows.Side(new).lines)]
      }
      return .ready
    case .revisions(let texts):
      oldIsBase = true
      // 今の並びがこの両側の本文の行差分なら、実行中の依頼を手放すだけで済む。
      if let made = revisionHunksSides, made.lineDiff, made.texts == texts { return .ready }
      if Self.diffsInPlace(texts) {
        swapRevisions(texts, lineDiff: true) {
          DiffRows.hunks(old: $0, new: $1, limit: Self.hunkLimit)
        }
        return .ready
      }
      pending = true
      revisionsComputing = texts
      if texts != computing { requestRevisionHunks(texts) }
      return waiting
    }
  }

  /// 両側の本文 `texts` の行差分を裏で取り、届いたときにまだその本文を待っていれば、両側と並びを一緒に入れ替える。
  private func requestRevisionHunks(_ texts: SideTexts) {
    let limit = Self.hunkLimit
    Task.detached(priority: .userInitiated) { [weak self] in
      let hunks = DiffRows.hunks(
        old: texts.old.map(TextRope.init), new: texts.new.map(TextRope.init), limit: limit)
      await MainActor.run { [weak self] in
        guard let self, revisionsComputing == texts else { return }
        revisionsComputing = nil
        pending = false
        swapRevisions(texts, lineDiff: true) { _, _ in hunks }
        if content != .ready {
          content = .ready
          surfacesChanged = true
        }
        applyRows()
        settleSurfaces()
      }
    }
  }

  /// 両側の版の本文どうしの行差分を、その場で取れる——片側が無い（行差分は区間 1 つで、手間は本文の大きさに依らない）。
  private static func diffsInPlace(_ texts: SideTexts) -> Bool {
    texts.old == nil || texts.new == nil
  }

  /// 両側を版の本文 `texts` にし、並びを `hunks`（入れ替えた両側の文書の本文から求める。その版に無い側は nil）にする。
  /// `lineDiff` は、`hunks` が両側の行差分か（ファイルとサブモジュールの置き換えの丸ごとの並びでないか）。古い側が
  /// 変わらなければ、作り直す新しい側の面では古い側の行を錨にして、前の面で先頭に見えていた所を先頭に置く。
  private func swapRevisions(
    _ texts: SideTexts, lineDiff: Bool, hunks: (_ old: TextRope?, _ new: TextRope?) -> [LineHunk]
  ) {
    let keepsOld = oldSource == .some(texts.old)
    setOld(texts.old)
    setNewRevision(texts.new, keepsOld: keepsOld)
    revisionHunks = hunks(
      oldSide.isAbsent ? nil : old?.text, newRevisionSide.isAbsent ? nil : newRevision?.text)
    revisionHunksSides = (texts, lineDiff)
  }

  /// 古い側を本文 `text`（その版に無ければ nil——空の本文の文書で、大きさは 0 行）にする。変われば作り直す。
  private func setOld(_ text: String?) {
    guard oldSource != .some(text) else { return }
    oldSource = .some(text)
    revisionHunksSides = nil
    dropOldSurface()
    let revision = RevisionDocument(text: text ?? "", name: id.url, registry: surfaces.registry)
    revision.onRolesChange = { [weak self] ranges in
      guard let self else { return }
      (document?.surface ?? newRevisionSurface)?.rowSourceRolesDidChange(ranges)
    }
    revision.onFocusChange = { [weak self] focused in self?.onFocusChange?(focused) }
    revision.onUserInput = { [weak self] in self?.userDidInput() }
    old = revision
    oldSide = DiffRows.Side(text == nil ? nil : revision.text)
  }

  /// 新しい側を版の本文 `text`（その版に無ければ nil——空の本文の文書で、大きさは 0 行）にする。文書と面は 1 対 1 なので、面も
  /// 作り直す——前の面で先頭に見えていた所を新しい面でも先頭に置き（`keepsOld` なら変わらない古い側の行を錨に写し、
  /// 古い側も変わるなら前の位置のまま）、並列なら古い側の面も作り直して新しい面と結ぶ。行差分（`revisionHunks`）は
  /// まだ前の並びのもの。
  private func setNewRevision(_ text: String?, keepsOld: Bool) {
    guard newSource != .some(text) else { return }
    newSource = .some(text)
    revisionHunksSides = nil
    if let previous = newRevisionSurface {
      let top = previous.viewport.top
      // 位置を決める前の作り直しは引き継がない（追いついた並びで 1 回だけ決める）。
      if placement == .placed {
        carried =
          keepsOld
          ? .anchor(
            DiffRows.anchor(at: previous.lineRow(of: top), revisionHunks, side: presented == .side))
          : .position(top)
      }
      dropOldSurface()
      surfacesChanged = true
    }
    let revision = RevisionDocument(text: text ?? "", name: id.url, registry: surfaces.registry)
    newRevision?.detach()
    revision.onViewportChange = { [weak self] in self?.viewportDidChange() }
    revision.onFocusChange = { [weak self] focused in self?.onFocusChange?(focused) }
    revision.onUserInput = { [weak self] in self?.userDidInput() }
    newRevision = revision
    newRevisionSide = DiffRows.Side(text == nil ? nil : revision.text)
    newRevisionSurface = surfaces.make()
    if let surface = newRevisionSurface { revision.attach(surface) }
  }
}
