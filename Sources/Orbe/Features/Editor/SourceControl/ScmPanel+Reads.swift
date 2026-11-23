import Foundation

/// Changes の画面を出している間の読み——グラフ・HEAD の push 済み・ステージ済みの行数。
extension ScmPanel {
  // MARK: - グラフと HEAD

  /// グラフと HEAD の push 済みを読み直す（パネルを出している間だけ）。`remoteRefsMayHaveMoved` なら、HEAD の push 済みは読み
  /// 終わるまで分からないとする（パネルを出した・再読込・remote 追跡 ref の変化・自分のネット操作の終わり）。git 管理下と
  /// 分かっていなければ（判定の前・管理外）、HEAD の push 済みを分からないにして返る（判定の後に管理下と分かれば、読みは
  /// 判定が済んだ知らせで始まる）。
  func readGraphAndHead(remoteRefsMayHaveMoved: Bool) {
    guard isShown else { return }
    guard liveFiles?.repo != nil else {
      headPush = nil
      return
    }
    readGraph()
    readHead(remoteRefsMayHaveMoved: remoteRefsMayHaveMoved)
  }

  /// グラフをいつも先頭から今の件数で読む（続きを継ぎ足さない——読みの間に HEAD が動くと重複・欠落する）。読めなければ
  /// 前の結果を保つ。
  private func readGraph() {
    guard isShown, let repo = liveFiles?.repo else { return }
    if graphJob.isRunning {
      graphJob.again = true
      return
    }
    graphJob.isRunning = true
    repo.commitGraph(limit: graphLimit) { [weak self] graph in
      guard let self else { return }
      graphJob.isRunning = false
      if let graph, graph != self.graph {
        self.graph = graph
        if isShown { updateGraphRows() }
      }
      if graphJob.again {
        graphJob.again = false
        readGraph()
      }
    }
  }

  /// HEAD のコミットと push 済みか（どれかの remote 追跡ブランチから届くか）を組で読む（グラフの口を通らない）。グラフの
  /// 50 件に HEAD が入る保証は無い（upstream が先に進んでいると上位を upstream が占める）ので、グラフの結果から拾わない。
  ///
  /// 分からないとした後は、その後に始めた読みが終わるまで分からないまま（走っている読みはきっかけより前を読んでいるかも
  /// しれないので、終わったらもう 1 回読む）。
  private func readHead(remoteRefsMayHaveMoved: Bool) {
    guard isShown, let repo = liveFiles?.repo else { return }
    if remoteRefsMayHaveMoved { headPushIsStale = true }
    if headJob.isRunning {
      headJob.again = true
      return
    }
    headJob.isRunning = true
    repo.headPush { [weak self] read in
      guard let self else { return }
      headJob.isRunning = false
      headPush = read
      if headJob.again {
        headJob.again = false
        readHead(remoteRefsMayHaveMoved: false)
      } else {
        headPushIsStale = false
      }
    }
  }

  /// グラフの列の行の組を今のブランチとグラフから作り、変わっていれば差し替えて列に読み直させる。
  func updateGraphRows() {
    let next = ScmGraphLayout.build(branch: ScmBranch(branch), graph: graph)
    guard next != graphLayout else { return }
    graphLayout = next
    graphRowsVersion &+= 1
  }

  /// 「さらに表示」: 件数を増やして頭から読み直す。
  func showMoreCommits() {
    graphLimit += Self.graphPage
    readGraph()
  }

  /// 再読込: status を取り直し、グラフと HEAD の push 済みを読み直す。
  func refresh() {
    liveFiles?.requestStatusRefresh()
    readGraphAndHead(remoteRefsMayHaveMoved: true)
  }

  // MARK: - ステージ済みの行数

  /// 行の組を差し替えた。ステージ済みが空なら行数を捨て、持っている行数の鍵と違えば読む。
  func stagedDidChange() {
    guard let key = changes.stagedKey else {
      stagedLines = nil
      return
    }
    if key != stagedLines?.key { readStagedLines() }
  }

  /// ステージ済みの行数を読む（1 本ずつ。読みの最中に来た要求は、読み終わったときの鍵の比較で拾う）。読み終わったら、
  /// 読み始めた時点の鍵と組で持ち、その間に行の組の鍵が変わっていれば読み直す。読めなければ前の行数を残す——読みの間も
  /// 前の数を出すのと同じく、ステージのたびにボタンの幅が跳ねないように。
  private func readStagedLines() {
    guard isShown, !isReadingStagedLines, let repo = liveFiles?.repo,
      let key = changes.stagedKey
    else { return }
    isReadingStagedLines = true
    repo.stagedLineCounts { [weak self] counts in
      guard let self else { return }
      isReadingStagedLines = false
      if let counts { stagedLines = (key, counts) }
      if changes.stagedKey != key { stagedDidChange() }
    }
  }
}
