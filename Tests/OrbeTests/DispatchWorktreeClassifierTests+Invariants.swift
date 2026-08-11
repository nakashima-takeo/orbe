import XCTest

@testable import Orbe

/// 分類器の出力が満たす**不変条件**（個別ケースではなく直積の総当たりで主張する）。
///
/// 主張の面は「モデルの配列に入っているか」ではなく **「ユーザーが到達できるか」**。
/// `lossNotes` / `overflowNotes` はサブラインが開く行でしか描かれないので、配列へ積んだだけの語は
/// 画面から消えているのと同じ——配列の上で不変条件を書くと、受け皿を広げても「開かない行」から
/// 別の語が落ち続ける。到達可能性の上に立てれば、その一群がまとめて落ちる。
extension DispatchWorktreeClassifierTests {

  /// **立った事実は、その行の状態で必ず画面から到達できる。**
  /// 右クラスタは常に描かれ、内訳と溢れは「サブラインを開ける行」でだけ描かれる。
  /// 開けない行に語を積んだら、それは不到達（＝消えている）。
  func testEveryRaisedFactIsReachable() {
    var violations: [String] = []
    forEachShape { facts, shape in
      let r = row(facts)
      // 安全行だけは 2 枚に載らなかった語が出ない（サブラインを開かないため。台帳 逸脱 18）。
      // **記録済みの唯一の不到達**で、その中身が安全な範囲に留まることは下の 2 本が別に固定する
      // ——loss は 1 つも立たない・安全の根拠は必ず右クラスタに載る。
      guard r.group != .safe else { return }
      let reachable = r.chips + (r.canExpandSubline ? r.lossNotes + r.overflowNotes : [])
      for chip in r.vocabulary where !reachable.contains(chip) {
        violations.append("\(chip.id) が不到達 — \(shape)")
      }
    }
    XCTAssertEqual(
      violations.count, 0,
      "立った語に画面へ出る経路が無い（先頭 3 件）: \(violations.prefix(3).joined(separator: " / "))")
  }

  /// **安全群の行は損失を 1 つも名乗らない。** 安全確認を全部通った行に黄の語が立つのは、
  /// 語の意味が行の事実と食い違っているということ——安全行はサブラインを開かないので、
  /// 立った時点で「安全の根拠を隠したまま警告だけ出す行」が作れてしまう。
  func testSafeRowsRaiseNoLoss() {
    var violations: [String] = []
    forEachShape { facts, shape in
      let r = row(facts)
      guard r.group == .safe else { return }
      for chip in r.vocabulary where chip.tone == .loss {
        violations.append("\(chip.id) — \(shape)")
      }
    }
    XCTAssertEqual(
      violations.count, 0,
      "安全行が損失を主張した（先頭 3 件）: \(violations.prefix(3).joined(separator: " / "))")
  }

  /// **安全群の行は安全の根拠を必ず右クラスタに出す。** 出ない語（安全行はサブラインを開かない）は
  /// 根拠を言い換えた safe / neutral の重複に限られる、というのが台帳 逸脱 18 の約束。
  func testSafeRowsAlwaysShowTheirEvidence() {
    var violations: [String] = []
    forEachShape { facts, shape in
      let r = row(facts)
      guard r.group == .safe else { return }
      let evidence = r.vocabulary.filter { $0.tone == .safe }
      if !evidence.isEmpty, !evidence.contains(where: { r.chips.contains($0) }) {
        violations.append("根拠が右クラスタに無い — \(shape)")
      }
      for chip in r.overflowNotes where chip.tone == .loss {
        violations.append("不到達の溢れが損失を含む: \(chip.id) — \(shape)")
      }
    }
    XCTAssertEqual(
      violations.count, 0,
      "安全行が根拠を隠した（先頭 3 件）: \(violations.prefix(3).joined(separator: " / "))")
  }

  /// 2 つの受け皿は重ならない（同じ語をサブラインに 2 度書かない）。
  func testTheTwoReceptaclesNeverOverlap() {
    var violations: [String] = []
    forEachShape { facts, shape in
      let r = row(facts)
      for chip in r.overflowNotes where r.chips.contains(chip) || r.lossNotes.contains(chip) {
        violations.append("\(chip.id) — \(shape)")
      }
    }
    XCTAssertEqual(
      violations.count, 0,
      "溢れが他の受け皿と重なった（先頭 3 件）: \(violations.prefix(3).joined(separator: " / "))")
  }

  /// 分類の入力になりうる形を総当たりする。
  /// **群を決めるフィールド（`isPrunable` / `isMain` / `occupancy` / `branch`）も振る**——
  /// 振らないと、不到達が最も起きやすい「安全行」「detached 行」「使用中行」が総当たりの外に残る。
  private func forEachShape(_ body: (DispatchCleanFacts, String) -> Void) {
    let occupancies: [PaneOccupancy?] = [nil, PaneOccupancy(cwd: "/wt/x", agentState: "waiting")]
    for branch in [nil, "feat/x"] as [String?] {
      for isPrunable in [false, true] {
        for isMain in [false, true] {
          for occupancy in occupancies {
            forEachDetail(branch, isPrunable, isMain, occupancy, body)
          }
        }
      }
    }
  }

  /// 群が決まった 1 つの形の下で、語彙を決めるフィールドを振る。
  private func forEachDetail(
    _ branch: String?, _ isPrunable: Bool, _ isMain: Bool, _ occupancy: PaneOccupancy?,
    _ body: (DispatchCleanFacts, String) -> Void
  ) {
    let statuses: [GitWorktreeStatusCounts?] = [
      nil, clean, GitWorktreeStatusCounts(modified: 2, untracked: 3),
    ]
    let operations: [GitWorktreeOperationState] = [.none, .unknown, .inProgress(.rebase)]
    for status in statuses {
      for operation in operations {
        for lockReason in [nil, "USB"] as [String?] {
          for upstream in [nil, "origin/feat/x"] as [String?] {
            for track in [nil, "[gone]", "[ahead 3]"] as [String?] {
              for unmergedCommits in [nil, 0, 4] as [Int?] {
                for openPR in [nil, 139] as [Int?] {
                  for merged in [nil, true, false] as [Bool?] {
                    let facts = DispatchCleanFacts(
                      path: "/wt/x", branch: branch, isMain: isMain, isPrunable: isPrunable,
                      lockReason: lockReason, upstream: upstream, track: track,
                      closedPR: merged.map { DispatchCleanPR(number: 142, isMerged: $0) },
                      openPR: openPR, status: status, unmergedCommits: unmergedCommits,
                      operation: operation, occupancy: occupancy)
                    body(facts, describe(facts))
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  private func describe(_ f: DispatchCleanFacts) -> String {
    """
    branch=\(f.branch ?? "nil") prunable=\(f.isPrunable) main=\(f.isMain) \
    pane=\(f.occupancy != nil) status=\(String(describing: f.status)) op=\(f.operation) \
    lock=\(f.lockReason != nil) up=\(f.upstream ?? "nil") track=\(f.track ?? "nil") \
    unmerged=\(String(describing: f.unmergedCommits)) openPR=\(String(describing: f.openPR)) \
    closedPR=\(String(describing: f.closedPR))
    """
  }
}
