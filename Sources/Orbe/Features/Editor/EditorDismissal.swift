/// エディター面の器（上のバーから開く一覧の器・ポップアップの器と、面の中の確認）を閉じたきっかけ。フォーカスを動かすかは、
/// きっかけで決まる（その時点の first responder では決めない）。動かす先は器ごとに決まる——一覧の器は本体の行き先、
/// ポップアップの器は開く前に在った所、面の中の確認は出す前に在った所（ポップアップが開いていたなら、それを開く前の所）。
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
