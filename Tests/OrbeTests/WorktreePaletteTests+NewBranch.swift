import XCTest

@testable import Orbe

/// 新しいブランチの作成行・ベースのバー・ベースを選ぶ画面（モデル）。作成行の有無は git の答え（有効な
/// ブランチ名か）と衝突の規則で決まり、選択は入力の規則に従う。ベースは役割で持ち、組み直しで別の
/// ベースを指さない。壊れると、打った名前で作成できない・別のベースから作る・既存の行を差し置いて
/// 作成してしまう、のどれかが起きる。
@MainActor
extension WorktreePaletteTests {

  /// designSample の衝突の規則（作成先は `~/wt/<slug>`）と、前回・既定・現在が揃ったベースの事実。
  func makeCreatableModel(previous: String? = "origin/release/0.8") -> WorktreePaletteModel {
    let input = WorktreePaletteSectionBuilder.Input.designSample
    let p = makeModel(input)
    p.newBranchRules = WorktreeNewBranchRules(
      takenNames: Set(input.localBranches.map(\.name)).union(
        input.remoteBranches.map { GitBranch.localName(fromRemote: $0.name) }),
      worktreePaths: input.worktrees.map(\.path), template: "~/wt/{slug}",
      repoPath: NSHomeDirectory() + "/src/orbe")
    p.baseFacts = WorktreeBaseFacts(
      previous: previous, defaultBranch: "origin/main", current: "issue/212")
    p.baseCandidates = [
      .init(name: "issue/212", relativeDate: "1d", isRemote: false),
      .init(name: "fix/login-blank", relativeDate: "3d", isRemote: false),
      .init(name: "origin/main", relativeDate: "1h", isRemote: true),
      .init(name: "origin/release/0.9", relativeDate: "2d", isRemote: true),
    ]
    return p
  }

  /// 打って、その名前への git の答えを返す（provider の配線と同じ順）。
  func type(_ name: String, into p: WorktreePaletteModel, valid: Bool? = true) {
    var asked: [String] = []
    p.onCheckBranchName = { asked.append($0) }
    p.query = name
    p.onQueryChanged()
    XCTAssertEqual(asked, name.isEmpty ? [] : [name], "打った名前を git に問う")
    if let valid { p.applyBranchNameCheck(name, isValid: valid) }
  }

  // MARK: - 作成行

  /// 有効で、どれともぶつからない名前は先頭に作成行が出て、一致する既存の行が無ければ選ばれる。
  func testValidNewNameShowsTheCreateRowFirstAndSelectsIt() {
    let p = makeCreatableModel()
    type("feat/base-picker", into: p)
    XCTAssertEqual(p.visibleSections.first?.title, .newBranch)
    XCTAssertEqual(p.items.first?.action, .createBranch(name: "feat/base-picker"))
    XCTAssertEqual(p.selectedItem?.action, .createBranch(name: "feat/base-picker"))
    XCTAssertEqual(
      p.visibleSections.last?.emptyNote, .worktreePaletteNoMatch, "既存の行が無いことも言う")
  }

  /// 一致する既存の行があれば、作成行は出ても既存の行の先頭が選ばれる。
  func testExistingMatchIsSelectedOverTheCreateRow() {
    let p = makeCreatableModel()
    type("fix", into: p)
    XCTAssertEqual(p.items.first?.action, .createBranch(name: "fix"))
    XCTAssertEqual(p.selectedItem?.name, "fix/login-blank")
  }

  /// git が無効と答えた名前は作成行を出さない。
  func testInvalidNameHasNoCreateRow() {
    let p = makeCreatableModel()
    type("bad..name", into: p, valid: false)
    XCTAssertFalse(p.items.contains { if case .createBranch = $0.action { true } else { false } })
  }

  /// ローカルブランチ（checkout 中を含む）・リモートの行が作るローカル名と同じ名前は作成行を出さない。
  func testTakenNamesHaveNoCreateRow() {
    let p = makeCreatableModel()
    for name in ["fix/login-blank", "issue/212", "feat/fetch-progress"] {
      type(name, into: p)
      XCTAssertFalse(
        p.items.contains { if case .createBranch = $0.action { true } else { false } },
        "\(name) は作れない")
    }
  }

  /// 作成先が既存の worktree と同じ場所になる名前（`issue-212` と `issue/212` は同じ slug でも、
  /// ここでは `issue-212` 自体の作成先 `~/wt/issue-212`）は作成行を出さない。
  func testNameWhoseDestinationIsAnExistingWorktreeHasNoCreateRow() {
    let p = makeCreatableModel()
    type("issue-212", into: p)
    XCTAssertFalse(p.items.contains { if case .createBranch = $0.action { true } else { false } })
    type("pr/214", into: p)
    XCTAssertFalse(
      p.items.contains { if case .createBranch = $0.action { true } else { false } },
      "pr/214 の作成先は既存の ~/wt/pr-214")
  }

  /// 答えがまだ無い間は直前の答えで出すかを決め、名前は今の入力にする（打鍵のたびに消えて出直さない）。
  /// 古い名前への答えは捨てる。
  func testCreateRowFollowsTheLastAnswerUntilTheNewOneArrives() {
    let p = makeCreatableModel()
    type("feat/a", into: p)
    type("feat/ab", into: p, valid: nil)
    XCTAssertEqual(p.items.first?.action, .createBranch(name: "feat/ab"), "直前の答え（有効）で出す")
    XCTAssertTrue(p.isAwaitingBranchNameAnswer)

    p.applyBranchNameCheck("feat/a", isValid: false)
    XCTAssertEqual(p.items.first?.action, .createBranch(name: "feat/ab"), "古い問いの答えは捨てる")

    p.applyBranchNameCheck("feat/ab", isValid: false)
    XCTAssertTrue(p.items.isEmpty, "今の名前が無効と分かったら消える")
  }

  /// 選択を動かした後は、答えの到着で選択を動かさない。
  func testAnswerDoesNotMoveASelectionTheUserMoved() {
    let p = makeCreatableModel()
    type("fix", into: p, valid: nil)
    XCTAssertEqual(p.selectedItem?.name, "fix/login-blank")
    p.applyBranchNameCheck("fix", isValid: true)
    XCTAssertEqual(p.selectedItem?.name, "fix/login-blank", "既存の一致の先頭のまま")

    p.move(-1)
    XCTAssertEqual(p.selectedItem?.action, .createBranch(name: "fix"), "前提: ユーザーが作成行へ動かした")
    rebuild(p, with: .designSample)
    XCTAssertEqual(p.selectedItem?.action, .createBranch(name: "fix"), "データの到着でも同じ行のまま")
  }

  // MARK: - 決定

  /// 作成行の ↵ は、ベースのバーで選んだベースから作る。初期は前回。
  func testEnterOnTheCreateRowCreatesFromTheSelectedBase() {
    let p = makeCreatableModel()
    var executed: [WorktreePaletteDestination] = []
    p.onExecute = { executed.append($0) }
    type("feat/base-picker", into: p)
    p.activate()
    XCTAssertEqual(
      executed, [.newBranch(name: "feat/base-picker", base: .ref("origin/release/0.8"))])
  }

  /// 前回が無ければ既定（意図のまま渡し、名前の解決は作成の直前）。
  func testInitialBaseIsTheDefaultWithoutAPrevious() {
    let p = makeCreatableModel(previous: nil)
    var executed: [WorktreePaletteDestination] = []
    p.onExecute = { executed.append($0) }
    type("feat/x", into: p)
    XCTAssertEqual(p.selectedBaseChoice?.role, .defaultBranch)
    p.activate()
    XCTAssertEqual(executed, [.newBranch(name: "feat/x", base: .defaultBranch)])
  }

  /// 名前を打ってすぐの ↵（答えより前）は預かり、有効と分かったら作成する。
  func testEnterBeforeTheAnswerIsHeldThenCreates() {
    let p = makeCreatableModel()
    var executed: [WorktreePaletteDestination] = []
    p.onExecute = { executed.append($0) }
    type("feat/a", into: p)
    type("feat/quick", into: p, valid: nil)
    p.activate()
    XCTAssertTrue(executed.isEmpty, "答えが届くまで作らない")
    XCTAssertTrue(p.isLocked)

    p.applyBranchNameCheck("feat/quick", isValid: true)
    XCTAssertEqual(
      executed, [.newBranch(name: "feat/quick", base: .ref("origin/release/0.8"))])
  }

  /// 預かった ↵ は、名前が無効と分かって選べる行が無ければ何もしない（ロックも解ける）。
  func testHeldEnterDoesNothingWhenTheNameTurnsOutInvalid() {
    let p = makeCreatableModel()
    var executed = 0
    p.onExecute = { _ in executed += 1 }
    type("feat/a", into: p)
    type("feat/a..", into: p, valid: nil)
    p.activate()
    p.applyBranchNameCheck("feat/a..", isValid: false)
    XCTAssertEqual(executed, 0)
    XCTAssertFalse(p.isLocked)
  }

  /// 答えを待っている間（直前の答えで出ている作成行）は、作成行をクリックしても作らない。答えが届いた後の
  /// クリックで作る。
  func testTapOnTheCreateRowBeforeTheAnswerDoesNotCreate() throws {
    let p = makeCreatableModel()
    var executed: [WorktreePaletteDestination] = []
    p.onExecute = { executed.append($0) }
    type("feat/a", into: p)
    type("feat/ab", into: p, valid: nil)
    let row = try XCTUnwrap(p.items.firstIndex { $0.action == .createBranch(name: "feat/ab") })

    p.activate(at: row)
    XCTAssertTrue(executed.isEmpty, "まだ git が有効と答えていない名前では作らない")

    p.applyBranchNameCheck("feat/ab", isValid: true)
    p.activate(at: row)
    XCTAssertEqual(executed, [.newBranch(name: "feat/ab", base: .ref("origin/release/0.8"))])
  }

  /// `-` で始まる名前（`-D` など）は git に問わずに無効とし、作成行を出さない。直前の名前が有効でも、
  /// ↵ でもクリックでも作成に進まない——作成で `git worktree add -b` のオプションとして渡り、ベースの
  /// ブランチを消しうるため。
  func testNameStartingWithADashNeverCreates() {
    let p = makeCreatableModel()
    var executed: [WorktreePaletteDestination] = []
    p.onExecute = { executed.append($0) }
    type("D", into: p)
    XCTAssertEqual(p.items.first?.action, .createBranch(name: "D"), "前提: 直前の名前では作成行が出ている")
    var asked: [String] = []
    p.onCheckBranchName = { asked.append($0) }

    p.query = "-D"
    p.onQueryChanged()

    XCTAssertEqual(asked, [], "git に問わない")
    XCTAssertFalse(p.items.contains { $0.action == .createBranch(name: "-D") })
    p.activate()
    p.activate(at: 0)
    XCTAssertEqual(executed, [], "作成に進まない")
  }

  /// 答えを待っていても、一致する既存の行を選んでいれば ↵ はすぐ効く。
  func testEnterOnAnExistingMatchDoesNotWaitForTheAnswer() {
    let p = makeCreatableModel()
    var executed: [WorktreePaletteDestination] = []
    p.onExecute = { executed.append($0) }
    type("fix", into: p, valid: nil)
    p.activate()
    XCTAssertEqual(executed, [.localBranch(name: "fix/login-blank")])
  }

  // MARK: - ベースのバー

  /// 選択肢は 前回 / 既定 / 現在 / ほか…。⇧⇥ で巡回し、末尾から先頭へ回る。作成行以外では動かない。
  func testCycleBaseOnlyOnTheCreateRow() {
    let p = makeCreatableModel()
    XCTAssertEqual(
      p.baseChoices.map(\.role), [.previous, .defaultBranch, .current, .other])
    p.cycleBase()
    XCTAssertEqual(p.selectedBaseChoice?.role, .previous, "作成行でなければ動かない")

    type("feat/x", into: p)
    p.cycleBase()
    XCTAssertEqual(p.selectedBaseChoice?.role, .defaultBranch)
    p.cycleBase()
    XCTAssertEqual(p.selectedBaseChoice?.role, .current)
    p.cycleBase()
    XCTAssertEqual(p.selectedBaseChoice?.role, .other)
    p.cycleBase()
    XCTAssertEqual(p.selectedBaseChoice?.role, .previous, "末尾から先頭へ")
  }

  /// 「ほか…」に止まった ↵ はベースを選ぶ画面を開く（作らない）。
  func testEnterOnOtherOpensTheBasePicker() {
    let p = makeCreatableModel()
    var executed = 0
    p.onExecute = { _ in executed += 1 }
    type("feat/x", into: p)
    p.chooseBase(.other)
    XCTAssertEqual(p.mode, .basePicker, "クリックでも開く")
    p.exitBasePicker()
    XCTAssertEqual(p.selectedBaseChoice?.role, .other, "esc で戻ると「ほか…」のまま")
    p.activate()
    XCTAssertEqual(p.mode, .basePicker)
    XCTAssertEqual(executed, 0)
  }

  /// 選んだ名前は「ほか…」の直前に出て選ばれ、その名前から作る。
  func testPickedBaseAppearsBeforeOtherAndIsUsed() throws {
    let p = makeCreatableModel()
    var executed: [WorktreePaletteDestination] = []
    p.onExecute = { executed.append($0) }
    type("feat/x", into: p)
    p.chooseBase(.other)
    let picker = try XCTUnwrap(p.basePicker)
    picker.query = "0.9"
    XCTAssertEqual(picker.items.map(\.name), ["origin/release/0.9"])
    p.submit()

    XCTAssertEqual(p.mode, .list)
    XCTAssertEqual(
      p.baseChoices.map(\.role), [.previous, .defaultBranch, .current, .picked, .other])
    XCTAssertEqual(p.selectedBaseChoice?.name, "origin/release/0.9")
    p.activate()
    XCTAssertEqual(executed, [.newBranch(name: "feat/x", base: .ref("origin/release/0.9"))])
  }

  /// 既にある選択肢と同じ名前を選んだら、その選択肢にまとまって選ばれる。
  func testPickingAnExistingChoiceSelectsThatChoice() {
    let p = makeCreatableModel()
    type("feat/x", into: p)
    p.chooseBase(.other)
    p.basePicker?.query = "origin/main"
    p.submit()
    XCTAssertEqual(p.baseChoices.map(\.role), [.previous, .defaultBranch, .current, .other])
    XCTAssertEqual(p.selectedBaseChoice?.role, .defaultBranch)
  }

  /// 選んだ役割が組み直しで消えたら未選択に戻り、初期規則（前回、無ければ既定）が当たる。前回が
  /// 着地で現れたら、未選択の間は前回が選ばれる。
  func testBaseSelectionSurvivesRebuildsByRole() {
    let p = makeCreatableModel(previous: nil)
    type("feat/x", into: p)
    XCTAssertEqual(p.selectedBaseChoice?.role, .defaultBranch)
    p.baseFacts = WorktreeBaseFacts(
      previous: "origin/release/0.8", defaultBranch: "origin/main", current: "issue/212")
    XCTAssertEqual(p.selectedBaseChoice?.role, .previous, "未選択なら現れた前回を選ぶ")

    p.cycleBase()
    p.cycleBase()
    XCTAssertEqual(p.selectedBaseChoice?.role, .current)
    p.baseFacts = WorktreeBaseFacts(
      previous: "origin/release/0.8", defaultBranch: "origin/main", current: nil)
    XCTAssertEqual(p.selectedBaseChoice?.role, .previous, "現在が消えたら初期規則へ")
  }

  // MARK: - ベースを選ぶ画面

  /// 候補はローカルの後にリモート。絞り込みでカーソルが先頭へ戻り、↑↓ は端で回る。
  func testBasePickerFiltersAndMoves() throws {
    let p = makeCreatableModel()
    type("feat/x", into: p)
    p.chooseBase(.other)
    let picker = try XCTUnwrap(p.basePicker)
    XCTAssertEqual(
      picker.items.map(\.name),
      ["issue/212", "fix/login-blank", "origin/main", "origin/release/0.9"])
    picker.move(-1)
    XCTAssertEqual(picker.selectedItem?.name, "origin/release/0.9")
    picker.query = "origin"
    XCTAssertEqual(picker.selected, 0)
    XCTAssertEqual(picker.items.count, 2)
  }

  /// 行タップはその候補で決まる。
  func testBasePickerTapConfirms() {
    let p = makeCreatableModel()
    type("feat/x", into: p)
    p.chooseBase(.other)
    p.confirmBasePick(at: 1)
    XCTAssertEqual(p.mode, .list)
    XCTAssertEqual(p.selectedBaseChoice?.name, "fix/login-blank")
  }
}
