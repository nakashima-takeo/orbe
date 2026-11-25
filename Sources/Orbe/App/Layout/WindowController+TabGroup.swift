import AppKit

/// 連（`TabGroup`）の寿命と、content の照合。連を作る・付け替える・畳むのはここだけで、キー K の連は「同じ workspace の
/// キー K のタブの所属」で引く（表を持たない——連の隣接は `SessionStore` が保証する）。
extension WindowController {
  /// `ws` の中で、`excluding` 以外のキー `key` のタブが属する連。無ければ nil。
  func group(forKey key: String, in ws: Workspace, excluding: TerminalTab? = nil) -> TabGroup? {
    ws.tabs.first { $0 !== excluding && $0.groupKey == key }?.group
  }

  /// 新しく足すタブの所属: `ws` の中の `cwd` の根の連、無ければ新しい連。
  func group(for cwd: String, in ws: Workspace) -> TabGroup {
    let key = GitWorktreeRoot.root(of: cwd)
    return group(forKey: key, in: ws) ?? makeGroup(key: key)
  }

  /// 連を作り、上位への通知を配線する（配線は作るときに 1 回だけ）。
  func makeGroup(key: String, state: EditorState? = nil) -> TabGroup {
    let group = TabGroup(key: key, state: state, editorSurfaces: editorSurfaces)
    group.onEditorChange = { [weak self] in
      self?.refreshChrome()
      self?.scheduleSave()
    }
    group.onWindowCommand = { [weak self] command in self?.handleWindowCommand(command) }
    group.onLocationChange = { [weak self] in self?.refreshChrome() }
    group.view.configure(
      translucency: chromeTranslucency, localization: localization, fontResolver: fontResolver,
      sidebar: editorSidebar)
    group.view.editor.settings = { [weak self, weak group] in
      guard let self else { return EffectiveSettings(SettingsLayer()) }
      let workspace = workspaces.first { $0.tabs.contains { $0.group === group } }
      return settingsStore.effective(override: workspace?.settingsOverride)
    }
    group.view.editor.isPeekingOverlay = { [weak self] in self?.browserPeeking ?? false }
    return group
  }

  /// cd で根が `key` に変わったタブの所属を付け替える。元の連に他のタブが残るなら、そのタブだけが行き先の連（無ければ
  /// 新しい連）へ移る。元の連の最後のタブなら、行き先が無ければ連ごとキーを付け替え、あれば元のエディターの開いている
  /// 文書を行き先へ移して連を畳む（diff は移らない → `TabGroup.absorb`）。エディターで見せているかは窓の状態なので変わらず、
  /// 付け替えの後の照合が行き先の器へ写す。
  func moveToGroup(_ tab: TerminalTab, key: String) {
    guard let ws = workspaces.first(where: { $0.tabs.contains { $0 === tab } }) else { return }
    let old = tab.group
    let dest = group(forKey: key, in: ws, excluding: tab)
    if ws.tabs.contains(where: { $0 !== tab && $0.group === old }) {
      tab.group = dest ?? makeGroup(key: key)
    } else if let dest {
      dest.absorb(old)
      tab.group = dest
    } else {
      old.rekey(key)
    }
  }

  /// content と器の中身を、タブの状態と選択に揃える（冪等。状態を変えた経路の終わりで毎回呼ぶ）。保つ不変条件は 3 つ。
  /// - 器の端末面に入っているのは、その連の materialize 済みのタブの端末だけ（器を窓に付けても休眠タブは起きない）。
  /// - content に載っているのは、前面の workspace の器のうち端末を 1 枚以上持つものと、前面の workspace がボードを持てば
  ///   ボードの面だけ。
  /// - 見えるのは選択が指すもの 1 つ。タブならその連の器（器の見せ方は、エディターで見せているならエディター、透かしている
  ///   なら透かし、そうでなければそのタブの端末）、ボードならボードの面、空なら何も見せず 0 タブの地を出す。前面の workspace の
  ///   ほかの器は端末の見せ方で、content に載っていない器も同じ（載せる前に見せ方を写し、外す器は端末にしてから外す）。見せ方は
  ///   即時に写し、同じ値なら器は何もしない（進行中の動きを切らない）。
  ///
  /// 焦点は当てない（器を外す・隠すと焦点は落ちうる。当て直すのは呼び手）。器は窓に付く前に大きさと可視を確定させる——窓に付いた瞬間の可視性で面
  /// （エクスプローラー）が根のサービスを握るか決まり、差した端末はその寸法で surface を起こす。器を初めて載せるときに
  /// 連の文書を戻す（`TabGroup.materialize`）。
  func reconcileContent() {
    reconcileTerminals()
    let selected = current.selectedTab
    var wanted: [NSView] = []
    for group in current.groups where !group.view.terminals.isEmpty {
      let view = group.view
      view.isHidden = group !== selected?.group
      if let selected, group === selected.group { view.show(terminal: selected.terminal) }
      view.show(facesMode(of: group), animated: false)
      if view.superview !== model.content {
        fitToContent(view)
        group.materialize()
        model.content.addSubview(view)
      }
      wanted.append(view)
    }
    if store.hasBoard(current) { wanted.append(placeBoard()) }
    for sub in model.content.subviews where !wanted.contains(where: { $0 === sub }) {
      (sub as? GroupFacesView)?.show(.terminal, animated: false)
      sub.removeFromSuperview()
    }
    let empty = current.selection == .empty
    if model.contentIsEmpty != empty { model.contentIsEmpty = empty }
  }

  /// 全 workspace の器の端末面を、その連の materialize 済みのタブの端末にそろえる。
  private func reconcileTerminals() {
    var placements: [(group: TabGroup, terminals: [SurfaceScrollView])] = []
    for ws in workspaces {
      for group in ws.groups {
        placements.append(
          (group, ws.tabs.filter { $0.group === group && $0.activated }.map(\.terminal)))
      }
    }
    for (group, terminals) in placements {
      for terminal in group.view.terminals where !terminals.contains(where: { $0 === terminal }) {
        group.view.remove(terminal: terminal)
      }
    }
    for (group, terminals) in placements {
      let missing = terminals.filter { terminal in
        !group.view.terminals.contains { $0 === terminal }
      }
      guard !missing.isEmpty else { continue }
      fitToContent(group.view)
      missing.forEach(group.view.add(terminal:))
    }
  }

  /// ボードの面を content の大きさにし、ボードを選んでいるときだけ見せて content に載せる。
  private func placeBoard() -> NSView {
    let view = boardView
    view.autoresizingMask = [.width, .height]
    if view.frame != model.content.bounds { view.frame = model.content.bounds }
    view.isHidden = current.selection != .board
    if view.superview !== model.content { model.content.addSubview(view) }
    return view
  }

  /// 器を content の大きさにする（窓に付く前に中身の寸法を確定させる）。
  func fitToContent(_ view: GroupFacesView) {
    view.autoresizingMask = [.width, .height]
    if view.frame != model.content.bounds { view.frame = model.content.bounds }
    view.layoutSubtreeIfNeeded()
  }
}
