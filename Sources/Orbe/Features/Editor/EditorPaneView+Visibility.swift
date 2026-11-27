import AppKit

/// 面の可視性——ツリー・プロジェクト検索・ソース管理パネル・PR のパネルが根のサービスを握る寿命と、本体の diff を見る寿命。
extension EditorPaneView {
  /// 窓から外れる前に、面の中の確認をキャンセルで閉じ、ポップアップを閉じる（閉じる直前の知らせの中で、中身はまだ窓に
  /// 居る）。
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      confirm.close(.faceHidden)
      popup.close(.faceHidden)
    }
    super.viewWillMove(toWindow: newWindow)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { itemList.close(.faceHidden) }
    updateLiveness()
    updateEventMonitor()
  }

  override func viewDidHide() {
    super.viewDidHide()
    itemList.close(.faceHidden)
    popup.close(.faceHidden)
    confirm.close(.faceHidden)
    updateLiveness()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    updateLiveness()
  }

  /// 面が画面に見えているか（窓に付き、隠れていない）が変わりうる。見えていれば、テキスト面を描く用意も裏で始める（端末
  /// だけを使う間は払わない）。ソース管理の一覧は、Changes の画面の間だけ行とグラフを組む。PR のパネルは、面が見えている間は
  /// worktree の今の PR を追い、PR の画面の間だけ中身も読む。本体の PR の diff は、面が見えている間だけ PR ごとの状態を見る。本体の diff を整合させ、配置を
  /// 頼み、見えるようになった本体を初めて見せる前の待ちをその配置で通す（隠れている間に配置が済んでいても、見えたときにもう
  /// 一度配置して待つ）。
  func updateLiveness() {
    let live = isFaceVisible
    tree.isLive = live
    projectSearch.isLive = live
    scm.isLive = live
    updatePanelsShown()
    updateDiffWatching()
    if live { group?.editor.prepareSurfaces() }
    reconcileWithLists()
    needsLayout = true
  }

  /// 面が画面に見えているか（窓に付き、隠れていない）。
  var isFaceVisible: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

  /// ソース管理の一覧が行を組むか（面が見えていて、画面が Changes）と、PR のパネルが worktree の今の PR を追うか（面が
  /// 見えている間。上のバーの番号）と中身も読むか（面が見えていて、画面が PR）を写す。左の列を閉じていても同じ——Changes・
  /// PR の画面で本体に自動で開く行を決めるのに一覧が要る。
  func updatePanelsShown() {
    let visible = isFaceVisible
    let screen = group?.editor.screen
    scm.isShown = visible && screen == .changes
    if !visible { pullRequest.isShown = false }
    pullRequest.isTracking = visible
    pullRequest.isShown = visible && screen == .pullRequest
  }

  /// 本体の diff を、面が見えている間だけ見る（PR の diff はこの間だけ PR ごとの状態を見る）。替われば前の diff を見終わる。
  func updateDiffWatching() {
    let next = isFaceVisible ? diff : nil
    guard next !== watchedDiff else { return }
    watchedDiff?.endWatching()
    next?.beginWatching()
    watchedDiff = next
  }
}
