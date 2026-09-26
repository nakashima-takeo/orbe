import XCTest

@testable import Orbe

/// PR 行の決定と選択。Enter の動きは行き先で決まり、手元で開けない PR 行はブラウザで開く（パレットは
/// 閉じない）。PR 行の行き先はデータの到着で変わるので、選択は PR の番号で保つ。
///
/// 崩れると、ブラウザ行の Enter で agent の起動に進んで赤エラーになるか、fetch の着地や worktree の作成の
/// たびに選択が PR 行から外れて別の行を指す（そのまま Enter すると意図しない行が開く）。
@MainActor
extension DispatchPaletteTests {

  private var repository: GitHubRepoName { GitHubRepoName(nameWithOwner: "o/r") }

  private func pullRequestInput(remoteBranches: [String] = [], landed: Bool = true)
    -> DispatchSectionBuilder.Input
  {
    DispatchSectionBuilder.Input(
      remoteBranches: remoteBranches.map {
        GitBranch(name: $0, relativeDate: "3h前", upstream: nil)
      },
      issues: [GitHubIssue(number: 5, title: "bug")],
      pullRequests: [
        GitHubPullRequest(
          number: 9, title: "feat", headRefName: "feat", reviewDecision: nil,
          headRepository: repository)
      ],
      githubState: .ready,
      remoteLedger: .settled(.init(repositories: ["origin": .github(repository)])),
      remoteFetchLanded: landed)
  }

  private func index(of number: Int, in p: DispatchPaletteModel) throws -> Int {
    try XCTUnwrap(p.items.firstIndex { $0.idText == "#\(number)" })
  }

  /// 手元で開けない PR 行の Enter と行タップは、⌘↵ と同じくブラウザで開き、agent は起動しない。
  func testBrowserPullRequestRowOpensTheWebInsteadOfExecuting() throws {
    let p = makeModel(pullRequestInput())
    var executed: [DispatchDestination] = []
    var opened: [String?] = []
    var dismissed = 0
    p.onExecute = { executed.append($0) }
    p.onOpenWeb = { opened.append($0.idText) }
    p.onDismiss = { dismissed += 1 }

    p.activate(at: try index(of: 9, in: p))
    p.activate()

    XCTAssertEqual(opened, ["#9", "#9"], "行タップも Enter も PR をブラウザで開く")
    XCTAssertTrue(executed.isEmpty, "agent の起動へ進まない")
    XCTAssertEqual(dismissed, 0, "パレットは開いたまま")
    XCTAssertEqual(p.mode, .list)
  }

  /// 手元で開ける PR 行の Enter は、その行き先を起動へ渡す。
  func testPullRequestRowWithADestinationExecutesIt() throws {
    let p = makeModel(pullRequestInput(remoteBranches: ["origin/feat"]))
    var executed: [DispatchDestination] = []
    var opened = 0
    p.onExecute = { executed.append($0) }
    p.onOpenWeb = { _ in opened += 1 }

    p.activate(at: try index(of: 9, in: p))

    XCTAssertEqual(executed, [.remoteBranch(name: "origin/feat", existingWorktree: nil)])
    XCTAssertEqual(opened, 0)
  }

  /// fetch の着地前に Enter した PR 行は、「作成中…」のまま着地を待ち（重ねた Enter は撃たない）、
  /// 着地後に組み直した同じ PR 行の行き先を起動へ渡す。
  func testPullRequestEnteredBeforeTheFetchLandsRunsItsLandedDestination() throws {
    let p = makeModel(pullRequestInput(landed: false))
    var resumes: [() -> Void] = []
    var executed: [DispatchDestination] = []
    var opened = 0
    p.onAwaitRemoteFetch = { resumes.append($0) }
    p.onExecute = { executed.append($0) }
    p.onOpenWeb = { _ in opened += 1 }

    p.activate(at: try index(of: 9, in: p))
    p.activate()

    XCTAssertTrue(p.isPreparing, "作成中のまま待つ")
    XCTAssertEqual(resumes.count, 1, "重ねた Enter は待ちを重ねない")
    XCTAssertTrue(executed.isEmpty, "着地前には起動しない")

    p.sections = DispatchSectionBuilder.build(
      pullRequestInput(remoteBranches: ["origin/other", "origin/feat"]))
    resumes.forEach { $0() }

    XCTAssertFalse(p.isPreparing)
    XCTAssertEqual(executed, [.remoteBranch(name: "origin/feat", existingWorktree: nil)])
    XCTAssertEqual(opened, 0)
  }

  /// 着地後に作れない（`origin/<head>` が来ない shallow clone 等）・PR 行が消えていたときは、Enter した
  /// PR をブラウザで開く。赤エラーにせず、パレットは開いたまま。
  func testPullRequestEnteredBeforeTheFetchLandsBrowsesWhenItCannotBeCreated() throws {
    var vanished = pullRequestInput()
    vanished.pullRequests = []
    let landings = [("origin/<head> が来ない", pullRequestInput()), ("PR 行が消えた", vanished)]
    for (label, landed) in landings {
      let p = makeModel(pullRequestInput(landed: false))
      var resume: (() -> Void)?
      var executed: [DispatchDestination] = []
      var opened: [String?] = []
      var dismissed = 0
      p.onAwaitRemoteFetch = { resume = $0 }
      p.onExecute = { executed.append($0) }
      p.onOpenWeb = { opened.append($0.idText) }
      p.onDismiss = { dismissed += 1 }
      p.activate(at: try index(of: 9, in: p))

      p.sections = DispatchSectionBuilder.build(landed)
      try XCTUnwrap(resume, label)()

      XCTAssertEqual(opened, ["#9"], "\(label): Enter した PR をブラウザで開く")
      XCTAssertTrue(executed.isEmpty, label)
      XCTAssertNil(p.errorMessage, "\(label): 赤エラーにしない")
      XCTAssertFalse(p.isPreparing, label)
      XCTAssertEqual(dismissed, 0, "\(label): パレットは開いたまま")
    }
  }

  /// 提示時の fetch が着地すると、PR 行は着地待ちから作成へ変わる。行の並びがずれても、選んでいた
  /// PR 行の選択は保たれる。
  func testSelectionStaysOnThePullRequestWhenItsDestinationChanges() throws {
    let p = makeModel(pullRequestInput(landed: false))
    p.selected = try index(of: 9, in: p)
    XCTAssertEqual(
      p.selectedItem?.action, .pullRequest(number: 9, route: .awaitingFetch), "前提: 着地待ちの行")

    let action = p.selectedItem?.action
    p.sections = DispatchSectionBuilder.build(
      pullRequestInput(remoteBranches: ["origin/feat", "origin/other"]))
    p.restoreSelection(matching: action)

    XCTAssertEqual(p.selectedItem?.idText, "#9", "Remote branches が増えて index がずれても PR 行のまま")
    XCTAssertEqual(
      p.selectedItem?.action,
      .pullRequest(
        number: 9, route: .open(.remoteBranch(name: "origin/feat", existingWorktree: nil))))
  }
}
