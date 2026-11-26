/// エディター面の上のバーから開く器（一覧の器・ポップアップの器）を閉じたきっかけ。フォーカスを動かすかは、きっかけで
/// 決まる（その時点の first responder では決めない）。動かす先は器ごとに決まる——一覧の器は本体の行き先、ポップアップの器は
/// 開く前に在った所。
enum EditorDismissal {
  case escape
  case toggle
  case owner
  case itemGone
  case outsidePress
  /// フォーカスが器の外へ移った（first responder が替わる途中に届くので、フォーカスを動かさない）。
  case focusLeft
  case faceHidden
  /// 別の器を開いた（開いた器がフォーカスを受け取るので、フォーカスを動かさない）。
  case otherOpened

  var returnsFocus: Bool {
    switch self {
    case .escape, .toggle, .owner, .itemGone, .outsidePress: true
    case .focusLeft, .faceHidden, .otherOpened: false
    }
  }
}
