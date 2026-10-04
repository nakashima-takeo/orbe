import Foundation
import OrbeEditorCore
import os

/// プロジェクト検索の状態（タブごと。pane が 1 つ持つ）——問い・検索の進み・結果・平らな行・選択・折りたたみ。規則（問いの
/// 組み立て・行の中の一致・順序・上限）は Core、1 回の検索の裏の仕事は `ProjectSearchRun`。検索パネル（SwiftUI と結果の列）は
/// これを読み、操作は閉包で pane へ戻る（開く・焦点）。
///
/// 打鍵は 300ms 後に検索し、Enter・切替・更新は即時。どの検索でも前の結果は消さず、新しい結果が最初に届いたとき（または
/// 検索が終わった・止めたとき）に差し替える（VS Code と同じ。切り替えるたびに列がちらつかない）。検索を始め直すたびに
/// 世代を進め、古い世代の結果は捨てる。開いている文書は保存前の中身を探し、結果の鮮度を文書の版で持つ
/// （→ `ProjectSearch+Documents`）。
@MainActor @Observable
final class ProjectSearch {
  static let typingDelay: TimeInterval = 0.3
  static let progressDelay: TimeInterval = 0.3
  static let slowAfter: TimeInterval = 2
  /// キーで一致へ動いたときの開きを間引く窓（VS Code の検索結果と同じ 75ms）。
  static let navigationWindow: TimeInterval = 0.075

  enum Phase: Equatable {
    case idle
    case searching
    /// 2 秒を超えた検索（ヘッダーの更新が停止に替わる）。
    case slow
    case done
  }

  /// パネルの中の焦点の置き場（SwiftUI の焦点を写したもの）。
  enum Area: Equatable {
    case field
    case results
  }

  /// 問い。打鍵・切替は `setPattern` / `toggle` を通す（検索を予約する）。復元は `restore`。
  private(set) var query = SearchQuery()
  private(set) var phase = Phase.idle
  /// 進捗の細い線（打鍵の検索では 300ms 遅れて出す）。
  private(set) var showsProgress = false
  /// 問いのエラー。
  private(set) var error: Failure?

  enum Failure: Equatable {
    /// ICU が断った正規表現。
    case invalidPattern
    /// ディスク側（git grep）が始められなかった・断った。
    case disk(GitGrep.Failure)
  }
  var results = ProjectSearchResults()
  /// 折りたたみを映した平らな行の数（行そのものは `row(at:)` で引く）。
  var rowCount = 0
  /// 平らな行が変わるたびに進む（結果の列はこれを見て読み直す）。
  var rowsVersion = 0
  /// 見せる選択（位置で持つ `anchor` から導く。選ぶのは `select`）。変われば地を押し直させる。
  var selection: RowID? {
    didSet { if selection != oldValue { onGroundChange() } }
  }
  var collapsed: Set<String> = []
  /// パネルの中の焦点（入力欄と結果の列が `focusDidChange` で書く）。
  private(set) var focusedArea: Area?
  /// 焦点を入れる要求。パネルがその場所へ焦点を移したら消す（入力欄なら全選択）——出来事なので、当てた後に残すと
  /// パネルが次に現れたときに古い要求が焦点を奪う。
  private(set) var focusRequest: Area?

  /// 根（正規形）。
  @ObservationIgnored private(set) var root: String
  /// 範囲に入りうる開いている文書（タブのセッションの列）。
  @ObservationIgnored var documents: () -> [EditorDocument] = { [] }
  /// 一致を開く。呼ぶのは出口（`open(_:_:)`）だけ。
  @ObservationIgnored var onOpen: (RowID, Opening) -> Void = { _, _ in }
  /// 焦点の文書の一致の地が変わりうる（結果・選択・見え隠れ）。
  @ObservationIgnored var onGroundChange: () -> Void = {}
  /// 永続する問いが変わった。
  @ObservationIgnored var onQueryChange: () -> Void = {}
  @ObservationIgnored let runner: GitRunner
  @ObservationIgnored let typingDelay = EditorDelay()
  @ObservationIgnored let progressDelay = EditorDelay()
  @ObservationIgnored let slowDelay = EditorDelay()
  /// キーで一致へ動いたときの開きの窓（→ `ProjectSearch+Open`）。
  @ObservationIgnored let navigationDelay = EditorDelay()
  @ObservationIgnored var isNavigationWindowOpen = false
  /// キーで動かした後、まだ離していない（押し続けている）。
  @ObservationIgnored var isNavigationKeyHeld = false
  /// 窓の中で動いた（窓が閉じたら、その時点の選択を開く）。
  @ObservationIgnored var hasPendingNavigation = false
  @ObservationIgnored private var run: ProjectSearchRun?
  @ObservationIgnored private(set) var compiled: CompiledSearchQuery?
  @ObservationIgnored private(set) var generation = 0
  /// 次に届いた結果（か検索の終わり）が前の結果を差し替える。
  @ObservationIgnored private var replacesOnArrival = false
  /// 選択の実体（→ `ProjectSearch+Rows`）。
  @ObservationIgnored var anchor: Anchor?
  /// 開いている文書ごとに、結果が映している版（頼んでまだ届いていない版も含む）。
  @ObservationIgnored var searchedVersions: [String: Int] = [:]
  /// 開いている文書ごとの取り直しの予約と、走っている取り直しの取り消しの印。
  @ObservationIgnored var refreshDelays: [String: EditorDelay] = [:]
  @ObservationIgnored var refreshCancels: [String: OSAllocatedUnfairLock<Bool>] = [:]
  /// 外部変更を聞く根のサービス（面が見えている間だけ握る）。
  @ObservationIgnored var files: RootFiles?
  /// 面が見えている間 true。立てると根のサービスを握って外部変更を聞き、結果が映している版を文書の版と比べ直す。
  @ObservationIgnored var isLive = false {
    didSet { if isLive != oldValue { liveDidChange() } }
  }
  /// まとまりごとの見出しの行の位置（`results.files` と同じ順）。
  @ObservationIgnored var fileRowStarts: [Int] = []

  init(root: String, runner: GitRunner = .shared) {
    self.root = root
    self.runner = runner
  }

  /// タブを閉じたら走っている git も止める（裏の仕事はこの型を弱く持つので、止めなければ閉じた後も走り続ける）。
  deinit {
    run?.cancel()
  }

  var isSearching: Bool { phase == .searching || phase == .slow }

  // MARK: - 問い

  /// 入力欄に打った。300ms 後に検索する（空なら止めて結果を消す）。
  func setPattern(_ pattern: String) {
    guard pattern != query.pattern else { return }
    query.pattern = pattern
    onQueryChange()
    guard !pattern.isEmpty else {
      typingDelay.cancel()
      clearResults()
      return
    }
    typingDelay.run(after: Self.typingDelay) { [weak self] in self?.search(typed: true) }
  }

  enum Option {
    case matchCase
    case wholeWord
    case regex
  }

  /// 切替（Aa / ab / .* と ⌥⌘C / W / R）。即時に検索する。
  func toggle(_ option: Option) {
    switch option {
    case .matchCase: query.matchCase.toggle()
    case .wholeWord: query.wholeWord.toggle()
    case .regex: query.isRegex.toggle()
    }
    onQueryChange()
    search()
  }

  /// 永続から戻す。入力欄に入れるだけで検索しない。
  func restore(_ query: SearchQuery) {
    self.query = query
  }

  /// ⌘⇧F の種。検索語に入れて即時に検索する（正規表現が有効なら字どおりになるようエスケープする）。
  func seed(_ text: String) {
    query.pattern = query.isRegex ? SearchQuery.escaped(text) : text
    onQueryChange()
    search()
  }

  // MARK: - 検索の実行

  /// 今の問いで検索し直す（Enter・切替・更新・根の変化）。`typed` は打鍵の検索（進捗の線を遅らせる）。
  func search(typed: Bool = false) {
    typingDelay.cancel()
    stopRun()
    cancelRefreshes()
    generation += 1
    error = nil
    guard !query.isEmpty else {
      clearResults()
      return
    }
    let compiled: CompiledSearchQuery
    do {
      compiled = try query.compiled()
    } catch {
      clearResults()
      self.error = .invalidPattern
      return
    }
    self.compiled = compiled
    replacesOnArrival = true
    phase = .searching
    showsProgress = !typed
    if typed {
      progressDelay.run(after: Self.progressDelay) { [weak self] in
        guard let self, isSearching else { return }
        showsProgress = true
      }
    }
    slowDelay.run(after: Self.slowAfter) { [weak self] in
      guard let self, phase == .searching else { return }
      phase = .slow
    }
    let documents = searchableDocuments()
    searchedVersions = Dictionary(
      documents.map { ($0.path, $0.version) }, uniquingKeysWith: { first, _ in first })
    let current = generation
    let run = ProjectSearchRun(
      query: compiled, root: root, documents: documents, runner: runner
    ) { [weak self] batch in self?.receive(batch, generation: current) }
    self.run = run
    run.start()
  }

  /// 検索を止める（停止・Esc）。この検索で届いた結果は残る（まだ 1 つも届いていなければ前の問いの結果を消す）。
  func stop() {
    guard isSearching else { return }
    stopRun()
    settle(.done)
  }

  /// ヘッダーのクリア。検索語と結果を消す。
  func clear() {
    setPattern("")
    requestFocus(.field)
  }

  /// 根が変わった（cd）。止めて結果を捨て、`searchNow` なら今の問いで検索し直す。
  func setRoot(_ root: String, searchNow: Bool) {
    guard root != self.root else { return }
    let wasLive = files != nil
    isLive = false
    self.root = root
    isLive = wasLive
    typingDelay.cancel()
    clearResults()
    if searchNow { search() }
  }

  private func receive(_ batch: ProjectSearchRun.Batch, generation: Int) {
    guard generation == self.generation else { return }
    if replacesOnArrival {
      replacesOnArrival = false
      replaceResults()
    }
    accept(batch.files)
    if batch.finished {
      run = nil
      error = batch.error.map(Failure.disk)
      settle(.done)
    }
    resultsDidChange()
  }

  private func stopRun() {
    run?.cancel()
    run = nil
  }

  /// 検索の進みを終える（終わった・止めた・消した）。差し替えを待っていた前の問いの結果はここで捨てる——残すと前の問いの
  /// 結果が今の問いの結果として見える。
  private func settle(_ phase: Phase) {
    if replacesOnArrival {
      replacesOnArrival = false
      replaceResults()
    }
    self.phase = phase
    showsProgress = false
    progressDelay.cancel()
    slowDelay.cancel()
  }

  /// 結果を空にして新しい検索を受ける（折りたたみ・選択も捨てる。既定は全部開く）。
  private func replaceResults() {
    results = ProjectSearchResults()
    collapsed = []
    select(nil)
    resultsDidChange()
  }

  private func clearResults() {
    stopRun()
    generation += 1
    compiled = nil
    error = nil
    cancelRefreshes()
    searchedVersions = [:]
    replacesOnArrival = false
    replaceResults()
    settle(.idle)
  }

  /// 結果が変わった。平らな行を数え直し、地を押し直させる。
  func resultsDidChange() {
    indexRows()
    onGroundChange()
  }

  // MARK: - 焦点

  func requestFocus(_ area: Area) {
    focusRequest = area
  }

  /// パネルが要求を当てた。
  func focusRequestDidApply() {
    focusRequest = nil
  }

  /// 入力欄か結果の列の焦点が入った・抜けた。焦点は片方ずつ入れ替わるので、抜けたほうが今の置き場のときだけ消す（入ったほうの
  /// 知らせが先に届いても上書きしない）。結果の列から抜けたら、押していたキーは離したものとして扱う（離した知らせは届かない）。
  func focusDidChange(_ area: Area, focused: Bool) {
    if area == .results, !focused { navigationKeyDidRelease() }
    if focused {
      focusedArea = area
    } else if focusedArea == area {
      focusedArea = nil
    }
  }

  /// パネルが隠れた。焦点の置き場も消える（隠れた view は焦点が抜けたことを知らせない）。
  func panelDidHide() {
    focusedArea = nil
  }
}
