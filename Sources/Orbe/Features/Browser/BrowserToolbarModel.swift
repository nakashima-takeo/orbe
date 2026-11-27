import Foundation

/// 36px ブラウザツールバーの観測モデル。`BrowserLayerView` が書き、SwiftUI `BrowserBarRoot` が読む。
@Observable final class BrowserToolbarModel {
  var mode: BrowserMode = .closed
  var isSidebarOpen = false
  var displayURL: BrowserDisplayURL?
  var rawURL = ""
  var canGoBack = false
  var canGoForward = false
  var isLoading = false
  var estimatedProgress = 0.0
  /// ツールバー子要素を通常濃度（1.0）で描くか。false のとき子要素だけ 0.68 へ落ち着かせる。
  var isInteractiveFocused = true
  var isPeeking = false
  var peekUnderlay: BrowserPeekUnderlay = .terminal
  var isEditingURL = false
  var editingText = ""
  /// インライン URL 編集の開始ごとに進めるトークン。入力欄のフォーカス＋全選択を 1 回だけ起動する。
  var editSessionToken = 0

  var onToggleSidebar: () -> Void = {}
  var onBack: () -> Void = {}
  var onForward: () -> Void = {}
  var onReloadOrStop: () -> Void = {}
  var onToggleFull: () -> Void = {}
  var onBeginURLEditing: () -> Void = {}
  /// 確定入力を受け、URL として受理・遷移できたなら true（編集終了）、不可なら false（編集継続）。
  var onCommitURL: (String) -> Bool = { _ in false }
  var onCancelURL: () -> Void = {}
  var onBlurURL: () -> Void = {}
}

/// リサイズ中のスナップ表示モデル。ドラッグしていない間は `kind == nil`。
@Observable final class BrowserSnapBadgeModel {
  var kind: BrowserResizeSession.SnapBadgeKind?
}
