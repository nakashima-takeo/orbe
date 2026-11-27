import AppKit
import Foundation

/// エクスプローラーのツリー——根の実ファイルの、展開集合・一覧・git status・選択・行内の新規入力。
/// 面が画面に見えている間だけ（`isLive`）根のサービスを握り、離すと監視は止まるが一覧と status の
/// キャッシュは保つ（隠れて戻るたびに空から描き直さない）。
///
/// 一覧は展開したディレクトリだけ遅延で取り、監視の通知で変わったパスの親のうち展開中のものを取り直す。
/// status はツリー自身のキャッシュで、サービスの status が非 nil のときだけ上書きする——握り直した直後の
/// 新しいサービスは git が返るまで nil で、それを写すとバッジが毎回消えて戻る。
/// 展開集合は根からの相対パスの集合で、祖先について閉じている（畳めば配下も外れる）。永続しない。
///
/// 子がフォルダ 1 つだけのフォルダの連なりは 1 行にまとめる（行の組み立ては `FileTree+Rows`）。連なりは「フォルダ → ただ 1 つの
/// 子フォルダ」の覚え（`onlyChild`）から導く。覚えは、一覧を持つフォルダについては一覧から書き、開いていないフォルダについては
/// 根が git の作業ツリーのときだけ裏の先読み（`FileTreeLookahead`）が書く。覚えは調べ直した結果が届くまでの仮の姿で、一覧を
/// 新しく取ったフォルダの開いていない子フォルダは、覚えの有無に依らず調べ直す（先読みしない根では覚えを消す）。
@MainActor @Observable
final class FileTree: RootFilesObserver {
  /// 行内入力の状態。打ちかけの名前もここに持つ——view の寿命（容器が行を捨てて作り直す）に依らない。
  struct NewEntry: Equatable {
    /// 挿す先のディレクトリ（相対パス。根は空）。
    let directory: String
    let isDirectory: Bool
    /// 出すたびに進む番号。行の同一性を出すたびに作り直し、取り消しを「その入力がまだ出ている間」に限る
    /// ——古い入力の blur が新しい入力を消さない。
    let generation: Int
    var name = ""
  }

  /// 根（正規形）。
  let root: String
  private(set) var expanded: Set<String> = []
  /// 相対ディレクトリ → 一覧。空文字が根。
  private(set) var entries: [String: [RootFiles.Entry]] = [:]
  private(set) var status: GitStatus?
  /// 開いている文書（仮の文書を含む）の、根からの相対パス → 行の印（×・未保存の丸・ディスクが変わったときの丸）。面が
  /// セッションから作って書く写し。
  private(set) var openMarks: [String: EditorItemListRow.Mark] = [:]
  /// フォルダ（根からの相対）→ ただ 1 つの子フォルダの名前。中身がフォルダ 1 つだけでないフォルダは持たない。
  private(set) var onlyChild: [String: String] = [:]
  /// エクスプローラーの中の入力のフォーカス（絞り込みの欄か、行内入力とその世代）。
  enum ExplorerFocus: Hashable {
    case filter
    case input(generation: Int)
  }

  /// エクスプローラーの中の 2 つの入力のどちらがフォーカスを持つか（無ければ nil）。view が、フォーカスが変わるたびに写す
  /// （行内入力から絞り込みの欄へ移るのは 1 回の変化として届く）。行内入力から絞り込みの欄へ移ったら、その入力を取り消す。欄に入ったら
  /// 対象の一覧が無いか古ければ取り、欄から出て字が空なら一覧を捨てる。
  var explorerFocus: ExplorerFocus? {
    didSet { if explorerFocus != oldValue { explorerFocusDidChange(from: oldValue) } }
  }
  /// エクスプローラーが出ているか（面が見えていて、左の列が開いていて、Files の左の列がエクスプローラー）。面が書く。出し
  /// 直したとき、絞り込み中で対象の一覧が古ければ取り直す。
  var isExplorerShown = false {
    didSet { if isExplorerShown, !oldValue { refreshFilterListIfStale() } }
  }
  /// 絞り込み（字・結果・絞り込みの間の開閉と、裏の仕事）。
  @ObservationIgnored let filter: FileTreeFilter
  struct Selection: Equatable {
    let path: String
    let isDirectory: Bool
  }

  /// 選択表示する行と、その種別（新規作成の挿し先を決める）。種別は選ばせた側が知っているので一緒に持つ——
  /// 一覧のキャッシュから引き直すと、すべて畳んだ後は親の一覧が無く、ディレクトリがファイル扱いになる。
  private(set) var selection: Selection?
  /// 選択表示する行（相対パス）。
  var selected: String? { selection?.path }
  /// 行内入力。非 nil → nil へ落ちることが「入力の終わり」で、理由（Enter・Esc・取り消し・畳む・閉じる・cd）を
  /// 問わず `onInputEnded` を同期に出す。
  private(set) var newEntry: NewEntry? {
    didSet { if oldValue != nil, newEntry == nil { onInputEnded?() } }
  }
  private var newGeneration = 0
  /// 行内入力でファイルを作った（呼び手が開く）。
  @ObservationIgnored var onCreated: ((URL) -> Void)?
  /// 行内入力が終わった（呼び手が焦点を引き取る）。
  @ObservationIgnored var onInputEnded: (() -> Void)?
  @ObservationIgnored private var files: RootFiles?
  @ObservationIgnored private let lookahead: FileTreeLookahead
  /// 一覧のスクロール位置（送れる範囲に対する比。0 が先頭、1 が末尾）。画面を切り替えて・左の列を閉じて一覧の view が
  /// 作り直されても戻すために、ツリーが覚える。
  @ObservationIgnored var scrollFraction: CGFloat = 0
  /// `scrollFraction` を覚えたときの選択。作り直した一覧は、今の選択がこれと違えば位置を戻さずに選択の行を見せる（隠れて
  /// いる間に選択が替わると、祖先が開いて中身の長さも変わり、覚えた位置は当てにならない）。
  @ObservationIgnored var scrolledSelection: String?

  /// 面が見えている間 true。立てると根のサービスを握って展開中を取り直し、下ろすと離す。
  var isLive = false {
    didSet {
      guard isLive != oldValue else { return }
      if isLive {
        let files = RootFiles.shared(for: root)
        self.files = files
        files.addObserver(self)
        reloadAll()
        if let status = files.status { self.status = status }
        // 見えていなかった間の変化は、通知が届いていない。
        filter.markStale()
        refreshFilterListIfStale()
      } else {
        files?.removeObserver(self)
        files = nil
      }
    }
  }

  init(root: String) {
    self.root = root
    lookahead = FileTreeLookahead(root: root)
    filter = FileTreeFilter(root: root)
  }

  // MARK: - 開閉・選択

  /// 行 `head`（連なりの先頭のフォルダ）を開閉する。開いていなければ連なりの全部を開き（どれも一覧を取る。覚えが古くて
  /// 連なりが途中で切れていれば、取った一覧が正になる）、開いていれば先頭から配下ごと畳む（覚えは残す）。選択は、連なりの
  /// いちばん深いフォルダ。
  func toggle(_ head: String) {
    if filter.shown != nil { return filter.toggle(head) }
    if expanded.contains(deepest(from: head)) {
      collapse(head)
    } else {
      var path = head
      expand(path)
      while let child = onlyChild[path] {
        path = Self.join(path, child)
        expand(path)
      }
    }
    selection = Selection(path: deepest(from: head), isDirectory: true)
  }

  /// 展開をすべて畳む。
  func collapseAll() {
    if filter.shown != nil { return filter.collapseAll() }
    expanded = []
    entries = entries.filter { $0.key.isEmpty }
    newEntry = nil
  }

  /// 文書をアクティブにした。根の下なら祖先を開いてその行を選択表示し、根の外なら選択を外す。
  func reveal(_ url: URL) {
    guard let path = relativePath(of: url) else {
      selection = nil
      return
    }
    revealPath(path, isDirectory: false)
  }

  private func revealPath(_ path: String, isDirectory: Bool) {
    for ancestor in Self.ancestors(of: path) { expand(ancestor) }
    selection = Selection(path: path, isDirectory: isDirectory)
  }

  private func expand(_ directory: String) {
    guard !directory.isEmpty else { return }
    expanded.insert(directory)
    if entries[directory] == nil { reload(directory) }
  }

  /// 畳む（配下ごと）。挿し先が畳まれれば入力行は画面から消えるので、入力も終わる。
  private func collapse(_ directory: String) {
    for path in expanded where path == directory || path.hasPrefix(directory + "/") {
      expanded.remove(path)
      entries[path] = nil
    }
    if let newEntry,
      newEntry.directory == directory || newEntry.directory.hasPrefix(directory + "/")
    {
      self.newEntry = nil
    }
  }

  /// 開いている印の写しを置き換える（変わったときだけ書く）。
  func setOpenMarks(_ marks: [String: EditorItemListRow.Mark]) {
    if marks != openMarks { openMarks = marks }
  }

  // MARK: - 新規作成

  /// 行内入力を出す。挿す先は、選択がディレクトリならそこから覚えをたどったいちばん深いフォルダ、ファイルならその親、
  /// 無ければ根。
  func beginNew(isDirectory: Bool) {
    setFilterText("")
    let directory: String
    if let selection {
      directory =
        selection.isDirectory ? deepest(from: selection.path) : Self.parent(of: selection.path)
    } else {
      directory = ""
    }
    for ancestor in Self.ancestors(of: directory) + [directory] { expand(ancestor) }
    newGeneration += 1
    newEntry = NewEntry(directory: directory, isDirectory: isDirectory, generation: newGeneration)
  }

  /// 入力行の `Row.id`。NUL はファイル名に入らないので実ファイルの行と衝突しない。
  static func inputRowID(_ entry: NewEntry) -> String { "\0new:\(entry.generation)" }

  /// 打ちかけの名前。
  func setNewName(_ name: String) {
    newEntry?.name = name
  }

  /// 名前を確定して作る。空・`/` 入り・既に在る・作れないは beep して入力に留まる（false）。
  /// 作った変化は監視が拾うが、体感のため親をその場で取り直す。ファイルなら `onCreated` で開く。
  @discardableResult
  func commitNew() -> Bool {
    guard let newEntry, let files else { return false }
    let name = newEntry.name.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, !name.contains("/") else {
      NSSound.beep()
      return false
    }
    let url = url(of: newEntry.directory).appendingPathComponent(
      name, isDirectory: newEntry.isDirectory)
    do {
      if newEntry.isDirectory {
        try files.createDirectory(at: url)
      } else {
        try files.createFile(at: url)
      }
    } catch {
      NSSound.beep()
      return false
    }
    self.newEntry = nil
    reload(newEntry.directory)
    selection = Selection(
      path: Self.join(newEntry.directory, name), isDirectory: newEntry.isDirectory)
    if !newEntry.isDirectory { onCreated?(url) }
    return true
  }

  /// 行内入力を取り消す。その世代がまだ出ているときだけ（古い入力の blur は今の入力に触れない）。
  func cancelNew(_ generation: Int) {
    guard newEntry?.generation == generation else { return }
    newEntry = nil
  }

  /// 出ている行内入力を取り消す（サイドバーを閉じる・cd）。
  func cancelNew() {
    newEntry = nil
  }

  // MARK: - 一覧

  /// 一覧を持つフォルダを全部取り直す（面が見え直した・取りこぼし）。どれも一覧を新しく取ったものとして、開いていない子
  /// フォルダを先読みへ頼む（見えていなかった間の変化は、通知が調べ直していない）。
  private func reloadAll() {
    var lookaheads = Set<String>()
    reload("", fresh: true, lookaheads: &lookaheads)
    for directory in expanded.sorted(by: { $0.count < $1.count }) where expanded.contains(directory)
    {
      reload(directory, fresh: true, lookaheads: &lookaheads)
    }
    requestLookahead(lookaheads)
  }

  /// 一覧を取り直す（ほかの取り直しと先読みを束ねない 1 回）。
  private func reload(_ directory: String) {
    var lookaheads = Set<String>()
    reload(directory, fresh: false, lookaheads: &lookaheads)
    requestLookahead(lookaheads)
  }

  /// 一覧を取り直す。読めなければ空として扱い、展開中なら畳む。取り直した親に無くなった展開中の
  /// ディレクトリは配下ごと畳み、その覚えも消す。覚えは一覧から書き、一覧を新しく取った（それまで持っていなかった）か
  /// `fresh` なら、開いていない子フォルダを `lookaheads` へ足す。
  private func reload(_ directory: String, fresh: Bool, lookaheads: inout Set<String>) {
    guard let files else { return }
    let isNew = fresh || entries[directory] == nil
    if let list = try? files.entries(of: url(of: directory)) {
      entries[directory] = list
      let folders = list.filter(\.isDirectory).map { Self.join(directory, $0.name) }
      let present = Set(folders)
      for path in expanded where Self.parent(of: path) == directory && !present.contains(path) {
        collapse(path)
      }
      var memo = onlyChild
      memo[directory] = list.count == 1 && list[0].isDirectory ? list[0].name : nil
      for path in memo.keys where Self.isGone(path, under: directory, present: present) {
        memo[path] = nil
      }
      if memo != onlyChild { onlyChild = memo }
      if isNew { lookaheads.formUnion(present.subtracting(expanded)) }
    } else if directory.isEmpty {
      entries[directory] = []
    } else {
      collapse(directory)
      entries[directory] = nil
    }
  }

  // MARK: - 先読み

  /// `paths`（開いていないフォルダ）の連なりを裏で調べさせる。届いた結果は、今も開いていないフォルダの分だけを覚えへ
  /// 書く（開いたフォルダは一覧が正）。根が git の作業ツリーでなければ調べず、その覚えを消す——調べ直せない覚えを古い形の
  /// まま残さない。git 管理下かの判定の前は何もしない（覚えはそのまま出し、判定が済んだときに扱い直す）。
  private func requestLookahead(_ paths: Set<String>) {
    guard let files, files.isResolved else { return }
    guard files.repo != nil else {
      let stale = paths.filter { onlyChild[$0] != nil && !expanded.contains($0) }
      if !stale.isEmpty { onlyChild = onlyChild.filter { !stale.contains($0.key) } }
      return
    }
    lookahead.request(paths) { [weak self] result in
      guard let self else { return }
      var memo = onlyChild
      for (path, child) in result where !expanded.contains(path) { memo[path] = child }
      if memo != onlyChild { onlyChild = memo }
    }
  }

  // MARK: - 通知

  /// 変わったパスを含む、一覧を持つフォルダのうちいちばん深いものを求める。パスがその直下なら一覧を取り直し、そのパスが
  /// 開いていない子フォルダなら、その連なりを先読みへ頼む。直下でなければ、その一覧の子のうちパスを含むフォルダの連なりを
  /// 先読みへ頼む。
  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {
    switch change {
    case .scanAll:
      reloadAll()
    case .paths(let paths):
      var directories = Set<String>()
      var direct = Set<String>()
      var lookaheads = Set<String>()
      for path in paths {
        guard let relative = relativePath(ofAbsolute: path) else { continue }
        var listed = Self.parent(of: relative)
        while !listed.isEmpty, !expanded.contains(listed) { listed = Self.parent(of: listed) }
        let child = Self.child(of: listed, toward: relative)
        if child == relative {
          directories.insert(listed)
          direct.insert(child)
        } else if !expanded.contains(child) {
          lookaheads.insert(child)
        }
      }
      // 浅い順。親の取り直しで畳まれたディレクトリは取り直さない。
      for directory in directories.sorted(by: { $0.count < $1.count })
      where directory.isEmpty || expanded.contains(directory) {
        reload(directory, fresh: false, lookaheads: &lookaheads)
      }
      for child in direct where !expanded.contains(child) && isListedFolder(child) {
        lookaheads.insert(child)
      }
      requestLookahead(lookaheads)
    }
    filterSawChange()
  }

  /// git 管理下かの判定が済んだ。判定の前に先読みを頼めなかった分も含め、一覧に在る開いていないフォルダを全部扱い直す。
  func rootFilesDidResolve(_ files: RootFiles) {
    requestLookahead(listedFolders.subtracting(expanded))
    filterSawChange()
  }

  func rootFilesStatusDidChange(_ files: RootFiles) {
    if let status = files.status { self.status = status }
  }

  func rootFiles(_ files: RootFiles, versionDidChange version: RootFiles.Version) {}

  // MARK: - 絞り込み

  /// 絞り込みの字を置き換える（欄が書く）。空になり、欄にフォーカスも無ければ対象の一覧を捨てる。
  func setFilterText(_ text: String) {
    filter.setText(text, files: files)
    if text.isEmpty, explorerFocus != .filter { filter.discardList() }
  }

  private func explorerFocusDidChange(from old: ExplorerFocus?) {
    if case .input(let generation) = old, explorerFocus == .filter { cancelNew(generation) }
    if explorerFocus == .filter {
      if filter.isStale, let files { filter.relist(files) }
    } else if old == .filter, !filter.isActive {
      filter.discardList()
    }
  }

  /// 根の下が変わった・git 管理下かの判定が済んだ。絞り込み中でエクスプローラーが出ていれば対象の一覧を取り直し、それ以外は
  /// 「古い」の印だけを立てる。
  private func filterSawChange() {
    if filter.isActive, isExplorerShown, let files {
      filter.relist(files)
    } else {
      filter.markStale()
    }
  }

  private func refreshFilterListIfStale() {
    if filter.isActive, isExplorerShown, filter.isStale, let files { filter.relist(files) }
  }
}
