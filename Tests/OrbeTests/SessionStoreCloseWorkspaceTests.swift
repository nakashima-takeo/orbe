import XCTest

@testable import Orbe

/// SessionStore.closeWorkspace(_:) の純ドメイン契約を固定する。
///
/// 契約は3つ。①アクティブ workspace を削除したら MRU（`lastUsedAt` 最大の他 workspace）を次のアクティブに
/// する（作成順の隣ではない）。②背景 workspace を削除してもアクティブ workspace の同一性は保つ。
/// ③最後の1つは削除しない（`.invalid`・配列不変）。併せて、アクティブ workspace の最後のタブを閉じても
/// `removeTab` は退避せずその場で空を維持する（`.emptiedActive`）ことを固定する。
/// Workspace は参照型のため、アクティブの同一性は index ではなくオブジェクト参照で照合する。
final class SessionStoreCloseWorkspaceTests: XCTestCase {

  /// 名前と lastUsedAt を与えて workspace を組む（closeWorkspace は tabs を触らないので空でよい）。
  private func ws(_ name: String, _ lastUsedAt: Date?) -> Workspace {
    let w = Workspace(name: name, rootPath: "/tmp")
    w.lastUsedAt = lastUsedAt
    return w
  }

  private let t1 = Date(timeIntervalSinceReferenceDate: 1_000)  // 最古
  private let t2 = Date(timeIntervalSinceReferenceDate: 2_000)  // 中間
  private let t3 = Date(timeIntervalSinceReferenceDate: 3_000)  // 最新

  // MARK: - 契約1: アクティブ削除 → MRU（作成順の隣ではない）

  /// MRU と「作成順の隣」が食い違う並びで、MRU 側が選ばれることを固定する。
  /// 作成順 [default, Alpha, Beta]、lastUsedAt は default 最新・Beta 中間・Alpha 最古。
  /// default（起源・アクティブ）を削除 → 作成順の隣なら Alpha だが、MRU は Beta。
  func testCloseActiveWorkspacePicksMRUNotArrayNeighbor() {
    let alpha = ws("Alpha", t1)
    let beta = ws("Beta", t2)
    let def = ws("default", t3)
    let store = SessionStore(workspaces: [def, alpha, beta], activeWorkspace: 0)

    XCTAssertEqual(store.closeWorkspace(0), .activeChanged)
    XCTAssertTrue(
      store.current === beta, "アクティブ削除後は MRU(lastUsedAt 最大)の Beta（作成順の隣 Alpha ではない）")
  }

  /// 削除で index がシフトしても、MRU target のオブジェクト参照へ正しく引き直される。
  /// 作成順 [A, B(active), C]、lastUsedAt は C 最新 → B 削除で MRU=C。C の index は 2→1 に詰まる。
  func testCloseActiveResolvesMRUByReferenceAfterIndexShift() {
    let a = ws("A", t1)
    let b = ws("B", t2)
    let c = ws("C", t3)
    let store = SessionStore(workspaces: [a, b, c], activeWorkspace: 1)

    XCTAssertEqual(store.closeWorkspace(1), .activeChanged)
    XCTAssertTrue(store.current === c, "MRU=C を参照で引き直す")
    XCTAssertEqual(store.activeWorkspace, 1, "C の index は削除で 2→1 に詰まる")
  }

  // MARK: - 契約2: 背景削除 → アクティブ不変

  /// アクティブより後ろの背景 workspace を削除しても、アクティブの同一性・index は不変。
  func testCloseBackgroundAfterActiveKeepsActive() {
    let a = ws("A", t1)
    let b = ws("B", t2)
    let c = ws("C", t3)
    let store = SessionStore(workspaces: [a, b, c], activeWorkspace: 1)

    XCTAssertEqual(store.closeWorkspace(2), .backgroundChanged, "背景(C)の削除")
    XCTAssertTrue(store.current === b, "アクティブは B のまま")
    XCTAssertEqual(store.activeWorkspace, 1, "後ろの削除では index は詰まらない")
  }

  /// アクティブより前の背景 workspace を削除すると、index は1つ詰めて同一アクティブを指し続ける。
  func testCloseBackgroundBeforeActiveShiftsIndexKeepsSameWorkspace() {
    let a = ws("A", t1)
    let b = ws("B", t2)
    let c = ws("C", t3)
    let store = SessionStore(workspaces: [a, b, c], activeWorkspace: 2)  // active = C

    XCTAssertEqual(store.closeWorkspace(0), .backgroundChanged, "背景(A・アクティブより前)の削除")
    XCTAssertTrue(store.current === c, "アクティブは同一 C を指し続ける")
    XCTAssertEqual(store.activeWorkspace, 1, "前の削除で index を 2→1 に詰める")
  }

  // MARK: - 契約3: 最後の1つ・範囲外

  func testCloseLastWorkspaceIsInvalidAndUnchanged() {
    let only = ws("only", t1)
    let store = SessionStore(workspaces: [only], activeWorkspace: 0)

    XCTAssertEqual(store.closeWorkspace(0), .invalid, "最後の1つは削除できない")
    XCTAssertEqual(store.workspaces.count, 1, "配列は不変")
    XCTAssertTrue(store.current === only)
  }

  func testCloseOutOfRangeIsInvalid() {
    let store = SessionStore(workspaces: [ws("a", t1), ws("b", t2)], activeWorkspace: 0)
    XCTAssertEqual(store.closeWorkspace(5), .invalid, "範囲外 index は .invalid")
    XCTAssertEqual(store.closeWorkspace(-1), .invalid, "負の index は .invalid")
    XCTAssertEqual(store.workspaces.count, 2, "配列は不変")
  }

  // MARK: - removeTab のアクティブ0タブ化はその場で空維持（退避しない）

  /// アクティブ workspace の最後のタブを閉じて 0タブ化 → 他 workspace へ退避せず、その workspace が
  /// 空のままアクティブで残る（`.emptiedActive`・単一/複数 workspace 問わず）。
  func testRemoveLastTabEmptiesActiveInPlace() {
    let active = ws("active", t3)
    let tab = TerminalController()
    active.tabs = [tab]
    let alpha = ws("Alpha", t1)  // 他 workspace があっても退避しない
    let beta = ws("Beta", t2)
    let store = SessionStore(workspaces: [active, alpha, beta], activeWorkspace: 0)

    guard case .emptiedActive = store.removeTab(tab) else {
      return XCTFail("アクティブ workspace の 0タブ化はその場で空維持（.emptiedActive）")
    }
    XCTAssertTrue(store.current === active, "退避せず同一 workspace がアクティブのまま")
    XCTAssertTrue(store.current.tabs.isEmpty, "その workspace は0タブの空状態で残る")
  }
}
