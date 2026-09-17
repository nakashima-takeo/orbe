import AppKit
import GhosttyKit
import UniformTypeIdentifiers

/// libghostty ランタイム（プロセスに 1 つ）。
/// app/config の生成、runtime callbacks の配線、surface→view レジストリを持つ。
///
/// 注: コールバックは libghostty の任意スレッドから来うるが、本実装は
/// `ghostty_app_tick` を main で駆動するため action_cb も実質 main で発火する。
/// `nonisolated(unsafe)` は「main スレッド規律で同期を保証する」前提のエスケープ。
final class Ghostty {
  nonisolated(unsafe) static let shared = Ghostty()

  let app: ghostty_app_t
  private(set) var config: ghostty_config_t

  private final class WeakView {
    weak var view: SurfaceView?
    init(_ v: SurfaceView) { view = v }
  }
  nonisolated(unsafe) private var registry: [UnsafeMutableRawPointer: WeakView] = [:]

  private init() {
    if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
      fatalError("ghostty_init failed")
    }

    config = Config.load()

    var rt = ghostty_runtime_config_s()
    rt.userdata = nil
    rt.supports_selection_clipboard = false
    // 処理待ちイベント発生 → main で tick
    rt.wakeup_cb = { _ in
      DispatchQueue.main.async { Ghostty.shared.tick() }
    }
    // タイトル/描画要求/ベル等のアクション
    rt.action_cb = { appPtr, target, action in
      Ghostty.shared.handleAction(appPtr, target, action)
    }
    // クリップボードは text/plain だけを扱い、Orbe は確認 UI を持たない。端末アプリ発の読み取り
    // （OSC 52 / Kitty）は orbe-defaults の clipboard-read = deny で core が断つので、既定で host に
    // 届く読み取りはユーザー発のペーストとその型一覧だけ。user 設定で allow / ask に変えると
    // 端末アプリ発の読み取りも届く。
    // read: STARTED を返すのは complete を呼んだときだけ（呼ばずに STARTED は state をリークし、
    // 呼んで UNAVAILABLE は二重解放）。PRIMARY（X11 の選択クリップボード）は macOS に無いので
    // UNSUPPORTED。SELECTION は paste_from_selection（⌘⇧V）が使うので general に向ける。
    rt.read_clipboard_cb = { userdata, location, state, mimes, mimesLen, list in
      guard location != GHOSTTY_CLIPBOARD_PRIMARY, let userdata,
        let surface = SurfaceView.from(userdata).surfacePtr
      else {
        return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
      }
      let wantsText = (0..<mimesLen).contains { i in
        mimes?[i].map { strcmp($0, "text/plain") == 0 } ?? false
      }
      let text = NSPasteboard.general.string(forType: .string)
      guard (wantsText && text != nil) || list else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
      Ghostty.completeClipboardRead(
        surface, state: state, text: wantsText ? text : nil, listsText: list && text != nil)
      return GHOSTTY_CLIPBOARD_READ_STARTED
    }
    // confirm: 確認が要る操作のうち通すのはペーストだけ。渡された表現をそのまま確認済みで完了する
    // （借用ポインタはコールバック中だけ有効。同期に完了するのでコピー不要）。
    rt.confirm_read_clipboard_cb = { userdata, confirm, state, request in
      guard let userdata, let surface = SurfaceView.from(userdata).surfacePtr else { return }
      guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let confirm else {
        ghostty_surface_deny_clipboard_request(surface, state)
        return
      }
      let c = confirm.pointee
      var payload = ghostty_clipboard_complete_s(
        contents: c.contents, contents_len: c.contents_len,
        available: c.available, available_len: c.available_len,
        confirmed: true, remember: false)
      ghostty_surface_complete_clipboard_request(surface, &payload, state)
    }
    // write: 確認が要る書き込みは通さない。
    rt.write_clipboard_cb = { _, _, contents, len, confirm in
      guard !confirm, let contents else { return }
      Ghostty.writeClipboard(UnsafeBufferPointer(start: contents, count: len))
    }
    // surface クローズ要求（shell の exit 等）: 所属タブを閉じる
    rt.close_surface_cb = { userdata, _ in
      guard let userdata else { return }
      SurfaceView.from(userdata).tab?.close(origin: .process)
    }

    guard let a = ghostty_app_new(&rt, config) else { fatalError("ghostty_app_new failed") }
    app = a
  }

  func tick() {
    ghostty_app_tick(app)
  }

  /// 設定をディスクから読み直して app 全体へ適用する（キーバインド reload_config の hard reload）。
  /// update は内部で複製され全 surface へ伝播するため、適用後に旧 config を解放して差し替える。
  func reloadConfig() {
    let new = Config.load()
    ghostty_app_update_config(app, new)
    ghostty_config_free(config)
    config = new
  }

  /// 最初のテキスト表現を NSPasteboard の文字列として置く。テキスト表現が無ければ何もしない（クリップボードを消さない）。
  /// Kitty write の MIME は core が正規化せず端末アプリの書いた名前のまま来るので、plain text と見なすかは
  /// macOS の型システム（UTType）に判定させる。本文は UTF-8 としてしか読まないので、UTF-16 系の plain text は
  /// テキスト表現と見なさない（NUL 混じりの文字列を置かない）。
  private static func writeClipboard(_ contents: UnsafeBufferPointer<ghostty_clipboard_content_s>) {
    for content in contents {
      guard let mime = content.mime,
        let type = UTType(mimeType: String(cString: mime)),
        type.conforms(to: .plainText),
        !type.conforms(to: .utf16PlainText), !type.conforms(to: .utf16ExternalPlainText),
        let data = content.data,
        let text = String(
          bytes: UnsafeRawBufferPointer(start: data, count: content.len), encoding: .utf8)
      else { continue }
      let pb = NSPasteboard.general
      pb.clearContents()
      pb.setString(text, forType: .string)
      return
    }
  }

  /// text/plain 1 表現（と型一覧）でクリップボード読み取りを完了する。C 側へ渡すポインタは呼び出しの間だけ有効。
  private static func completeClipboardRead(
    _ surface: ghostty_surface_t, state: UnsafeMutableRawPointer?, text: String?, listsText: Bool
  ) {
    let mime = Array("text/plain".utf8CString)
    let data = Array((text ?? "").utf8CString)
    mime.withUnsafeBufferPointer { mime in
      data.withUnsafeBufferPointer { data in
        let contents: [ghostty_clipboard_content_s] =
          text == nil
          ? [] : [.init(mime: mime.baseAddress, data: data.baseAddress, len: data.count - 1)]
        let available: [UnsafePointer<CChar>?] = listsText ? [mime.baseAddress] : []
        contents.withUnsafeBufferPointer { contents in
          available.withUnsafeBufferPointer { available in
            var payload = ghostty_clipboard_complete_s(
              contents: contents.baseAddress, contents_len: contents.count,
              available: available.baseAddress, available_len: available.count,
              confirmed: false, remember: false)
            ghostty_surface_complete_clipboard_request(surface, &payload, state)
          }
        }
      }
    }
  }

  // MARK: - surface → view レジストリ

  func register(_ surface: ghostty_surface_t, view: SurfaceView) {
    registry[surface] = WeakView(view)
  }

  func unregister(_ surface: ghostty_surface_t) {
    registry.removeValue(forKey: surface)
  }

  func view(for surface: ghostty_surface_t) -> SurfaceView? {
    registry[surface]?.view
  }
}
