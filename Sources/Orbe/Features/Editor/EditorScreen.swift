/// エディターの画面——Changes（作業ツリーの変更）・PR（今のブランチの PR）・Files（開いている文書）。連のセッションが
/// 選んだ画面を持ち、本体と左の列の中身は画面で決まる。rawValue は永続の値。
enum EditorScreen: String {
  case changes
  case pullRequest
  case files
}
