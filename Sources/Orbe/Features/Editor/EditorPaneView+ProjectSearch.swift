import AppKit
import OrbeEditorCore

/// プロジェクト検索の結線——⌘⇧F で検索パネルを出す（Files の画面で）・検索パネルを離れてエクスプローラーへ戻す・種・
/// 結果を開いて一致を選び中央へ・パネルの中のキー
/// （⌘↓ / ⌘↑・⌥⌘C / W / R）・F4 / ⇧F4。列の外の押下で待っている ↑↓ の開きを捨てる（ソース管理の列も同じ）。
extension EditorPaneView {
  func wireProjectSearch() {
    projectSearch.documents = { [weak self] in self?.group?.editor.heldDocuments ?? [] }
    projectSearch.onOpen = { [weak self] id, opening in self?.openProjectMatch(id, opening) }
    projectSearch.onGroundChange = { [weak self] in self?.pushFindGround() }
    projectSearch.onLeave = { [weak self] in self?.showExplorer() }
  }

  /// Files の左の列をエクスプローラーにする。一致の地とパネルにあった焦点の後始末は、左の列の中身が替わったときの 1 か所が
  /// 行う（→ `syncPanel`）。
  func showExplorer() {
    filesPanel = .files
  }

  /// 検索パネルが見えている（左の列が開いていて、画面が Files で、左の列が検索）。
  var showsSearchPanel: Bool { sidebar.isOpen && shell.panel == .search }

  /// 焦点が左の列にあるか——左の列の host 配下か、一覧のために面が預かっている（→ `holdListFocus`）。
  var focusIsInSidebar: Bool {
    guard let responder = window?.firstResponder as? NSView else { return false }
    return responder.isDescendant(of: sideHost) || (heldListFocus != nil && responder === self)
  }

  /// 焦点が検索パネルの中（入力欄か結果の列）にあるか。
  var focusIsInSearchPanel: Bool {
    showsSearchPanel && focusIsInSidebar && projectSearch.focusedArea != nil
  }

  /// ⌘⇧F の種——押した時点の焦点がテキスト面で、選択が 1 行以内の非空ならその文字列、⌘F のバーの入力欄ならその
  /// 検索語。焦点が既に検索パネルにあれば種なし（キャレットの語は使わない。VS Code の `seedWithNearestWord` の既定）。
  /// 選択がプロジェクト検索の置いた選択のままでも種なし（結果を見て回った後の ⌘⇧F で、一致の字を検索語に入れて検索し直さない）。
  func projectSearchSeed() -> String? {
    guard let responder = window?.firstResponder as? NSView, !focusIsInSearchPanel else {
      return nil
    }
    if let document, responder === document.surface.responder {
      let selection = document.surface.selectedRange
      guard selection.length > 0,
        searchPlacedSelection?.isSelection(selection, in: document) != true
      else { return nil }
      let text = document.text.substring(selection)
      return text.contains(where: \.isNewline) ? nil : text
    }
    if let searchBar, responder.isDescendant(of: searchBar), !search.needle.isEmpty {
      return search.needle
    }
    return nil
  }

  /// Files の画面を選び、左の列を検索パネルで開き、入力欄に焦点を入れる（前の検索語は全選択）。種があれば入れて即時に検索する。
  func showProjectSearch(seed: String?) {
    showSearchPanel()
    if let seed { projectSearch.seed(seed) }
    projectSearch.requestFocus(.field)
    selectSearchFieldText()
    pushFindGround()
  }

  /// Files の画面を選び、左の列を検索パネルで開く。
  private func showSearchPanel() {
    filesPanel = .search
    group?.editor.selectScreen(.files)
    sidebar.setOpen(true)
  }

  /// 入力欄に焦点があれば検索語を全選択する（焦点がこれから入るなら、入るときに AppKit が全選択する）。
  private func selectSearchFieldText() {
    guard projectSearch.focusedArea == .field,
      let editor = window?.firstResponder as? NSTextView, editor.isDescendant(of: sideHost)
    else { return }
    editor.selectAll(nil)
  }

  /// 一致を `opening` の開き方で開く——文書を開いて Files の画面で見せてから、一致を選択に置き、その行を中央へ（見えていても送る。
  /// VS Code と同じ）、横に隠れていれば寄せる。本文へ焦点を移す開き方でなければ焦点に触らない（クリックでは列が押下で
  /// 焦点を取っていて、遅れて走るキーの開きは、その間に人が移した焦点を奪わない）。
  func openProjectMatch(_ id: ProjectSearch.RowID, _ opening: ProjectSearch.Opening) {
    guard let group else { return }
    let url = URL(fileURLWithPath: projectSearch.root, isDirectory: true)
      .appendingPathComponent(id.path)
    let document: EditorDocument
    do {
      document = try group.editor.open(url, as: opening.mode)
    } catch {
      NSSound.beep()
      return
    }
    group.editor.selectScreen(.files)
    tree.reveal(document.url)
    layoutSubtreeIfNeeded()
    projectSearch.documentDidShow(document)
    if let range = projectSearch.ground(for: document).current {
      searchPlacedSelection = SearchPlacedSelection(document: document, range: range)
      document.surface.selectedRange = range
      document.surface.reveal(range, policy: .center)
    }
    if opening.focusesText { window?.makeFirstResponder(document.surface.responder) }
    pushFindGround()
  }

  /// アプリがイベントを配る手前で見る口（窓に付いている間だけ）。F4 / ⇧F4 と PR の画面のキー v を拾う——修飾の無いキーは
  /// key equivalent として pane に届かずテキスト面の keyDown へ直行するので（テキスト面の契約は変えない）。結果の列の外を押したら、
  /// 待っている ↑↓ の開きを捨てる——人の注意が結果から移ったので、後から前の選択が開いて押したものを入れ替えない（焦点が
  /// 列に残る押下——上のバーのボタンなど——も含む）。一覧の器が開いていて、器と今の項目のボタンの外を押したら、器を閉じて
  /// フォーカスを本体へ戻してから、押下をそのまま通す（押した先は今までどおり働く）。ポップアップも同じで、置き場に並んでいる
  /// 物と右端の主な操作のボタンの外を押したら閉じて、開く前の場所へフォーカスを戻す。⌥ で透かしている間の押下では閉じない
  /// （透かしている間のクリックはエディターに届かない）。
  func updateEventMonitor() {
    if window == nil {
      eventMonitor.map(NSEvent.removeMonitor)
      eventMonitor = nil
    } else if eventMonitor == nil {
      eventMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
      ) { [weak self] event in
        guard let self, event.window === window else { return event }
        if event.type != .keyDown {
          pressWillArrive(event)
          return event
        }
        if escapeRepeatIsSwallowed(event) { return nil }
        return handleStepKey(event) || handleViewedKey(event) ? nil : event
      }
    }
  }

  /// 本文の選択が変わった。プロジェクト検索の置いた選択から動いていれば、置いた選択を忘れる。
  func searchPlacedSelectionDidChange(in document: EditorDocument) {
    guard let placed = searchPlacedSelection, placed.document === document,
      !placed.isSelection(document.surface.selectedRange, in: document)
    else { return }
    searchPlacedSelection = nil
  }

  /// 窓の押下 `event` が配られる手前（監視から）。
  func pressWillArrive(_ event: NSEvent) {
    if itemList.isOpen, !isPeeking, !pressIsOnItemList(event) { itemList.close(.outsidePress) }
    if popup.isOpen, !isPeeking, !pressIsOnDock(event) { popup.close(.outsidePress) }
    if !press(event, isIn: searchResults) { projectSearch.navigation.drop() }
    if !press(event, isIn: scmList) { scm.navigation.drop() }
    if !press(event, isIn: pullRequestList) { pullRequest.navigation.drop() }
  }

  /// 押した点が列（スクロールバーを含む）の上か。
  private func press(_ event: NSEvent, isIn list: NSView) -> Bool {
    guard let view = window?.contentView?.hitTest(event.locationInWindow) else { return false }
    return view.isDescendant(of: list)
  }

  /// エディター面（pane の配下）に焦点があるときの F4 / ⇧F4: 次・前の一致を開く（結果が無ければ素通し）。検索パネルが
  /// 隠れていれば出す（Files の画面で）。扱ったら true。
  func handleStepKey(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard event.specialKey == .f4, flags.isSubset(of: [.shift]), focusIsInside,
      projectSearch.step(forward: flags.isEmpty)
    else { return false }
    showSearchPanel()
    return true
  }

  /// 検索パネルの中のキー（⌥⌘C / W / R・⌘↓・⌘↑）。扱ったら true。
  func handleProjectSearchKey(_ event: NSEvent) -> Bool {
    guard focusIsInSearchPanel else { return false }
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    if flags == [.command, .option] {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "c": projectSearch.toggle(.matchCase)
      case "w": projectSearch.toggle(.wholeWord)
      case "r": projectSearch.toggle(.regex)
      default: return false
      }
      return true
    }
    guard flags == [.command] else { return false }
    switch event.specialKey {
    case .downArrow:
      if projectSearch.focusedArea == .field { projectSearch.focusResults() }
      return true
    case .upArrow:
      if projectSearch.focusedArea == .results { _ = projectSearch.returnToFieldIfAtTop() }
      return true
    default:
      return false
    }
  }
}

/// プロジェクト検索が一致を開いて本文に置いた選択（文書と区間）。
struct SearchPlacedSelection {
  weak var document: EditorDocument?
  let range: NSRange

  /// `document` の選択 `range` が、この置いた選択のままか。
  func isSelection(_ range: NSRange, in document: EditorDocument) -> Bool {
    self.document === document && self.range == range
  }
}
