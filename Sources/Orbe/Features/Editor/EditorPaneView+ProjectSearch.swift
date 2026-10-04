import AppKit
import OrbeEditorCore

/// プロジェクト検索の結線——⌘⇧F とレールで検索パネルを出す・種・結果を開いて一致を選び中央へ・パネルの中のキー
/// （⌘↓ / ⌘↑・⌥⌘C / W / R）・F4 / ⇧F4。
extension EditorPaneView {
  func wireProjectSearch() {
    projectSearch.documents = { [weak self] in self?.tab?.editor.documents ?? [] }
    projectSearch.onOpen = { [weak self] id, opening in self?.openProjectMatch(id, opening) }
    projectSearch.onGroundChange = { [weak self] in self?.pushFindGround() }
  }

  /// 検索パネルが見えている（サイドバーが開いていて、検索のパネルを出している）。
  var showsSearchPanel: Bool { sidebar.isOpen && sidebar.panel == .search }

  /// 焦点がサイドバー（骨の host 配下）にあるか。
  var focusIsInSidebar: Bool {
    (window?.firstResponder as? NSView)?.isDescendant(of: sideHost) == true
  }

  /// 焦点が検索パネルの中（入力欄か結果の列）にあるか。
  var focusIsInSearchPanel: Bool {
    showsSearchPanel && focusIsInSidebar && projectSearch.focusedArea != nil
  }

  /// レールの項目を押した。検索のパネルを出したら入力欄に焦点を入れる（VS Code のアクティビティバーと同じ）。
  func selectPanel(_ panel: EditorSidebarState.Panel) {
    sidebar.select(panel)
    if showsSearchPanel { projectSearch.requestFocus(.field) }
  }

  /// ⌘⇧F の種——押した時点の焦点がテキスト面で、選択が 1 行以内の非空ならその文字列、⌘F のバーの入力欄ならその
  /// 検索語。焦点が既に検索パネルにあれば種なし（キャレットの語は使わない。VS Code の `seedWithNearestWord` の既定）。
  func projectSearchSeed() -> String? {
    guard let responder = window?.firstResponder as? NSView, !focusIsInSearchPanel else {
      return nil
    }
    if let document, responder === document.surface.responder {
      let selection = document.surface.selectedRange
      guard selection.length > 0 else { return nil }
      let text = document.text.substring(selection)
      return text.contains(where: \.isNewline) ? nil : text
    }
    if let searchBar, responder.isDescendant(of: searchBar), !search.needle.isEmpty {
      return search.needle
    }
    return nil
  }

  /// サイドバーを検索パネルで開き、入力欄に焦点を入れる（前の検索語は全選択）。種があれば入れて即時に検索する。
  func showProjectSearch(seed: String?) {
    sidebar.show(.search)
    if let seed { projectSearch.seed(seed) }
    projectSearch.requestFocus(.field)
    selectSearchFieldText()
    pushFindGround()
  }

  /// 入力欄に焦点があれば検索語を全選択する（焦点がこれから入るなら、入るときに AppKit が全選択する）。
  private func selectSearchFieldText() {
    guard projectSearch.focusedArea == .field,
      let editor = window?.firstResponder as? NSTextView, editor.isDescendant(of: sideHost)
    else { return }
    editor.selectAll(nil)
  }

  /// 一致を `opening` の開き方で開く——文書を開いて見せてから、一致を選択に置き、その行を中央へ（見えていても送る。
  /// VS Code と同じ）、横に隠れていれば寄せる。本文へ焦点を移す開き方でなければ焦点に触らない（クリックでは列が押下で
  /// 焦点を取っていて、遅れて走るキーの開きは、その間に人が移した焦点を奪わない）。
  func openProjectMatch(_ id: ProjectSearch.RowID, _ opening: ProjectSearch.Opening) {
    guard let tab else { return }
    let url = URL(fileURLWithPath: projectSearch.root, isDirectory: true)
      .appendingPathComponent(id.path)
    let document: EditorDocument
    do {
      document = try tab.editor.open(url, as: opening.mode)
    } catch {
      NSSound.beep()
      return
    }
    tree.reveal(document.url)
    layoutSubtreeIfNeeded()
    projectSearch.documentDidShow(document)
    if let range = projectSearch.ground(for: document).current {
      document.surface.selectedRange = range
      document.surface.reveal(range, policy: .center)
    }
    if opening.focusesText { window?.makeFirstResponder(document.surface.responder) }
    pushFindGround()
  }

  /// アプリがイベントを配る手前で見る口（窓に付いている間だけ）。F4 / ⇧F4 を拾う——修飾の無いファンクションキーは key
  /// equivalent として pane に届かずテキスト面の keyDown へ直行するので（テキスト面の契約は変えない）。結果の列の外を押したら、
  /// 待っている ↑↓ の開きを捨てる——人の注意が結果から移ったので、後から前の選択が開いて押したものを入れ替えない（焦点が
  /// 列に残る押下——タブの × など——も含む）。
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
          if !pressIsInResults(event) { projectSearch.dropPendingNavigation() }
          return event
        }
        return handleStepKey(event) ? nil : event
      }
    }
  }

  /// 押した点が検索結果の列（スクロールバーを含む）の上か。
  private func pressIsInResults(_ event: NSEvent) -> Bool {
    guard let view = window?.contentView?.hitTest(event.locationInWindow) else { return false }
    return view.isDescendant(of: searchResults)
  }

  /// エディター面（pane の配下）に焦点があるときの F4 / ⇧F4: 次・前の一致を開く（結果が無ければ素通し）。検索パネルが
  /// 隠れていれば出す。扱ったら true。
  func handleStepKey(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard event.specialKey == .f4, flags.isSubset(of: [.shift]), focusIsInside,
      projectSearch.step(forward: flags.isEmpty)
    else { return false }
    sidebar.show(.search)
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
