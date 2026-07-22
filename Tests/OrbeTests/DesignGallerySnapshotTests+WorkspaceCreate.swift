import SwiftUI
import XCTest

@testable import Orbe

/// ワークスペース作成フォームの gallery 描画（既存フォルダ / git clone の両ソース・全状態）。
/// 本体（`DesignGallerySnapshotTests`）から分離し、突合対象を1ファイルに集約する
/// （production の `WorkspaceCreateCard+Clone.swift` と同じ関心分離）。
extension DesignGallerySnapshotTests {

  /// ワークスペース作成フォームを design 正典 ステージ同寸（640×520）で撮る。folder=(a)追従＋補完・
  /// (b)リンク解除中／clone=(c)通常・(d)URL空・(e)リンク解除中・(f)待機・(g)失敗。見本と突合。
  func renderWorkspaceCreateSnapshots(dir: URL) throws {
    let stage = NSSize(width: 640, height: 520)
    func write(_ name: String, _ model: WorkspaceCreateModel) throws {
      try writePNG(
        ZStack {
          BackgroundGlow()
          WorkspaceCreateOverlay(model: model)
        }.frame(width: stage.width, height: stage.height),
        size: stage, name: name, dir: dir)
    }

    // (a) 追従＋補完: 見本 FS（~/dev で "orb" 前方一致）。fullPath は ~ 短縮が効くよう実ホーム基準。
    let home = NSHomeDirectory()
    let follow = WorkspaceCreateModel(path: "~/dev/orb")
    follow.suggestions = [
      FolderSuggestion(name: "orbe", fullPath: "\(home)/dev/orbe", isRepo: true),
      FolderSuggestion(name: "orbe-agent", fullPath: "\(home)/dev/orbe-agent", isRepo: true),
      FolderSuggestion(name: "orbe-mobile", fullPath: "\(home)/dev/orbe-mobile", isRepo: false),
    ]
    try write("workspacecreate_follow.png", follow)

    // (b) リンク解除中: 実在パス（~＝ホーム）で名前を手入力＝フッターは作成プレビュー文＋done 名。
    let unlinked = WorkspaceCreateModel(path: "~")
    unlinked.setName("my-workspace")
    try write("workspacecreate_unlinked.png", unlinked)

    // --- git clone ソース（見本 WorkspaceCreateFlow.tsx の src==="clone" と突合）---
    let repoURL = "https://github.com/you/repo.git"
    func cloneModel() -> WorkspaceCreateModel {
      let model = WorkspaceCreateModel(path: "~")  // 親=home（実在）で canCreate 可
      model.setSource(.clone)
      model.setCloneURL(repoURL)
      return model
    }

    // (c) 通常入力: URL を打ち込み名前が追従（done 色 /repo）。
    try write("workspacecreate_clone.png", cloneModel())

    // (d) URL 空欄: placeholder（薄字の例 URL）と /workspace サフィックスを確認。
    let cloneEmpty = WorkspaceCreateModel(path: "~")
    cloneEmpty.setSource(.clone)
    try write("workspacecreate_clone_empty.png", cloneEmpty)

    // (e) 名前リンク解除中: 手入力で「リンク解除中 — 再リンク」affordance を出す。
    let cloneUnlinked = cloneModel()
    cloneUnlinked.setName("my-fork")
    try write("workspacecreate_clone_unlinked.png", cloneUnlinked)

    // (f) clone 実行中の待機表示: onClone を no-op にし submit＝running のまま（スピナー）。
    let cloneWaiting = cloneModel()
    cloneWaiting.onClone = { _, _, _ in }  // 完了を呼ばない＝running のまま
    cloneWaiting.submit()
    try write("workspacecreate_clone_waiting.png", cloneWaiting)

    // (g) clone 失敗の inline エラー: onClone が stderr を返す＝danger バナー表示。
    let cloneError = cloneModel()
    cloneError.onClone = { _, _, done in done("fatal: repository '\(repoURL)' not found") }
    cloneError.submit()
    try write("workspacecreate_clone_error.png", cloneError)
  }
}
