// 複数カーソルの規則（⌘D・⌘⇧L・⌥⌘↑↓・⌘U・Esc・全カーソルでの編集と移動・コピー／カット／ペーストの配り方・重なった
// カーソルのまとめ方）の正解を、VS Code の同じコード（monaco-editor の esm の編集器を jsdom の上で）を動かして作り、Swift の
// テストの表として標準出力へ書く。scripts/gen-vscode-edit-cases.sh から呼ぶ（MONACO は css の import を外した monaco の
// 置き場、JSDOM は jsdom を入れた node_modules の親）。
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { JSDOM } = require(`${Deno.env.get("JSDOM")}/node_modules/jsdom`);
const dom = new JSDOM("<!doctype html><div id=host></div>", { pretendToBeVisual: true });
const w = dom.window;
// Orbe と同じ macOS の WebKit として振る舞わせる（空の選択のコピー・カット（`emptySelectionClipboard`）は WebKit と Firefox
// だけで効く）。deno の navigator は jsdom のものに差し替える。
Object.defineProperty(w.navigator, "userAgent", {
  value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
});
Object.defineProperty(globalThis, "navigator", { value: w.navigator, configurable: true, writable: true });
for (const key of Object.getOwnPropertyNames(w)) {
  if (!(key in globalThis)) {
    try {
      Object.defineProperty(globalThis, key, { value: w[key], configurable: true, writable: true });
    } catch {
      // 読み取り専用の口は飛ばす。
    }
  }
}
globalThis.window = w;
globalThis.document = w.document;
globalThis.CSS = w.CSS = { escape: (v) => String(v).replace(/[^a-zA-Z0-9_-]/g, (c) => `\\${c}`), supports: () => false };
globalThis.matchMedia = w.matchMedia = () => ({
  matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {},
});
globalThis.ResizeObserver = w.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
w.HTMLCanvasElement.prototype.getContext = () => null;
w.document.queryCommandSupported = () => false;

const base = `${Deno.env.get("MONACO")}/esm/vs/editor`;
const monaco = await import(`${base}/editor.api.js`);
await import(`${base}/contrib/multicursor/browser/multicursor.js`);
await import(`${base}/contrib/cursorUndo/browser/cursorUndo.js`);
await import(`${base}/contrib/wordOperations/browser/wordOperations.js`);
const { Selection } = monaco;

const editor = monaco.editor.create(w.document.getElementById("host"), {
  value: "", language: "plaintext", automaticLayout: false, wordWrap: "off",
});
const model = editor.getModel();
const viewModel = editor._getViewModel();

/** 「|」（キャレット）と「[」「]」（選択。`[` が動かない側）を含む本文の、本文とカーソルの列（[動かない端, 動く端] の
 * オフセット。`primary` 番目（文書の順）が先頭）。Swift の `Editing.parseAll` と同じ書き方。 */
function parse(marked, primary = 0) {
  let text = "";
  const cursors = [];
  let open = null;
  for (const ch of marked) {
    if (ch === "|") cursors.push([text.length, text.length]);
    else if (ch === "[" || ch === "]") {
      if (open) {
        cursors.push(ch === "]" ? [open.offset, text.length] : [text.length, open.offset]);
        open = null;
      } else open = { ch, offset: text.length };
    } else text += ch;
  }
  const [first] = cursors.splice(primary, 1);
  return { text, cursors: [first, ...cursors] };
}

const selectionOf = ([anchor, active]) => {
  const a = model.getPositionAt(anchor);
  const b = model.getPositionAt(active);
  return new Selection(a.lineNumber, a.column, b.lineNumber, b.column);
};
const cursorsNow = () =>
  editor.getSelections().map((s) => [
    model.getOffsetAt({ lineNumber: s.selectionStartLineNumber, column: s.selectionStartColumn }),
    model.getOffsetAt({ lineNumber: s.positionLineNumber, column: s.positionColumn }),
  ]);

let clipboard = null;
function copy() {
  const selections = viewModel.getCursorStates().map((state) => state.modelState.selection);
  const emptySelectionClipboard = editor.getOption(monaco.editor.EditorOption.emptySelectionClipboard);
  const { sourceText } = viewModel.getPlainTextToCopy(selections, emptySelectionClipboard, false);
  const pieces = Array.isArray(sourceText) ? sourceText : null;
  clipboard = {
    text: pieces ? pieces.join(model.getEOL()) : sourceText,
    pieces,
    entireLine: emptySelectionClipboard && selections.length === 1 && selections[0].isEmpty(),
  };
}

/** VS Code の Esc の割り当て——カーソルが複数なら removeSecondaryCursors、1 本で選択があれば cancelSelection。 */
function escape() {
  const selections = editor.getSelections();
  if (selections.length > 1) editor.trigger("keyboard", "removeSecondaryCursors");
  else if (!selections[0].isEmpty()) editor.trigger("keyboard", "cancelSelection");
}

function act(action) {
  switch (action.kind) {
    case "command": return editor.trigger("keyboard", action.id);
    case "type":
      for (const ch of action.text) editor.trigger("keyboard", "type", { text: ch });
      return;
    case "escape": return escape();
    case "copy": return copy();
    case "cut":
      copy();
      return editor.trigger("keyboard", "cut");
    case "paste":
      return editor.trigger("keyboard", "paste", {
        text: clipboard.text, pasteOnNewLine: clipboard.entireLine, multicursorText: clipboard.pieces, mode: null,
      });
    case "pasteExternal":
      return editor.trigger("keyboard", "paste", {
        text: action.text, pasteOnNewLine: false, multicursorText: null, mode: null,
      });
  }
}

const c = (id) => ({ kind: "command", id });
const D = c("editor.action.addSelectionToNextFindMatch");
const L = c("editor.action.selectHighlights");
const UP = c("editor.action.insertCursorAbove");
const DOWN = c("editor.action.insertCursorBelow");
const U = c("cursorUndo");
const ESC = { kind: "escape" };
const type = (text) => ({ kind: "type", text });
const COPY = { kind: "copy" };
const CUT = { kind: "cut" };
const PASTE = { kind: "paste" };
const pasteExternal = (text) => ({ kind: "pasteExternal", text });

/** [名前, 本文（印つき）, 主の番号（文書の順）, 操作の列]。 */
const scenarios = [
  // ⌘D——空のキャレットから（語の単位・大小区別、回り込み、選ばれていれば変わらない）
  ["⌘D は空のキャレットから語を選び語の単位・大小区別で足して回る", "foo b|ar Bar bar barx bar\nbar", 0, [D, D, D, D, D, D]],
  ["⌘D は語の終わりのキャレットからも語を選ぶ", "ab cd| cd", 0, [D, D]],
  ["⌘D は語に接しないキャレットでは何もしない", "a  |  b a", 0, [D]],
  ["⌘D は最後に足した選択の後ろから探して先頭へ回る", "x foo foo |foo foo", 0, [D, D, D, D]],
  // ⌘D——選択から（⌘F の規則）
  ["⌘D は選択から大小を区別しない素の文字列で足す", "[ab]c AB xab\nAb", 0, [D, D, D, D]],
  ["⌘D は逆向きの選択からも足す", "]ab[ x ab ab", 0, [D, D]],
  ["⌘D は重なりうる一致を重ねずに足す", "[aa]aaa", 0, [D, D, D]],
  ["⌘D は複数行の選択の一致を足す", "[a\nb] a\nb a\nb", 0, [D, D]],
  // ⌘D——続きの無いカーソルの列
  ["⌘D はそろっていない空のカーソルを語に広げるだけ", "a|bc x|yz abc xyz", 0, [D, D]],
  ["⌘D は空のカーソルと選択が混ざれば広げるだけ", "[abc] abc| abc", 0, [D, D, D]],
  ["⌘D は日本語の並びの中の語を選ぶ", "東京|都に行く。東京タワー", 0, [D, D]],
  ["⌘D はそろった選択の列から主で続きを作る", "[ab] x [AB] ab ab", 0, [D, D]],
  ["⌘D は主が後ろのそろった選択から続きを作る", "[ab] x [ab] ab ab", 1, [D, D]],
  // ⌘⇧L
  ["⌘⇧L は選択の全出現を選び主の場所を保つ", "x ab y AB [ab] z ab", 0, [L]],
  ["⌘⇧L は空のキャレットから語の全出現を選ぶ", "ab x a|b y abc AB ab", 0, [L]],
  ["⌘⇧L は ⌘D の続きの全出現を選ぶ", "a|b x ab ab", 0, [D, D, L]],
  ["⌘⇧L は一致が 1 つなら主だけ", "[xyz] abc", 0, [L]],
  ["⌘⇧L は語の無いキャレットでは何もしない", "a | b", 0, [L]],
  ["⌘⇧L はカーソルが複数でも主から始める", "a|b ab c|d cd", 1, [L]],
  // ⌥⌘↑↓
  ["⌥⌘↓ は短い行を越えて覚えた横位置へ戻る", "abc|d\nx\n\nabcdef\nab", 0, [DOWN, DOWN, DOWN, DOWN, DOWN]],
  ["⌥⌘↑ は短い行を越えて覚えた横位置へ戻る", "ab\nabcdef\n\nx\nabc|d", 0, [UP, UP, UP, UP, UP]],
  ["⌥⌘↓ は選択の両端を写す", "a[bc]d\nxyzw\nq\nabcd", 0, [DOWN, DOWN, DOWN]],
  ["⌥⌘↓ は逆向きの選択の両端を写す", "a]bc[d\nxyzw\nabcd", 0, [DOWN, DOWN]],
  ["⌥⌘↓ は行をまたぐ選択を写す", "a[b\ncd]e\nfghi\njk", 0, [DOWN, DOWN]],
  ["⌥⌘↓ は最終行の下には足さない", "abc\nx|y", 0, [DOWN, UP]],
  ["⌥⌘↑ は先頭行の上には足さない", "a|bc\nxy", 0, [UP, DOWN, DOWN]],
  ["⌥⌘↓ は複数のカーソルそれぞれの下に足して重なりをまとめる", "a|b\nc|d\nef\ngh", 0, [DOWN, DOWN]],
  ["⌥⌘↑ は複数のカーソルそれぞれの上に足す", "ab\ncd\ne|f\ng|h", 1, [UP, UP]],
  ["⌥⌘↓ は全角の字の行から横位置を写す", "あい|う\nabcdef", 0, [DOWN]],
  ["⌥⌘↓ の後の打鍵は全カーソルに入る", "a|b\ncd\nef", 0, [DOWN, DOWN, type("X"), c("deleteLeft")]],
  // ⌘U
  ["⌘U は ⌘D の足し方を 1 つずつ戻し次の ⌘D がまた足す", "a|b ab ab ab", 0, [D, D, D, U, U, D]],
  ["⌘U は移動と ⌥⌘↓ を戻す", "|abc\nabc\nabc", 0, [c("cursorRight"), DOWN, c("cursorRight"), U, U, U]],
  ["⌘U は本文を変えると戻すものが無い", "a|b ab ab", 0, [D, D, type("x"), U]],
  ["⌘U は戻すものが無ければ何もしない", "a|b", 0, [U]],
  // Esc
  ["Esc は主の 1 本に戻し選択を残し次に選択を解く", "[ab] [ab] [ab]", 0, [ESC, ESC, ESC]],
  ["Esc は主が文書の後ろでも主を残す", "[ab] [ab] [ab]", 2, [ESC]],
  ["Esc は ⌘D で足した後も主の選択を残す", "x|y xy xy", 0, [D, D, D, ESC, ESC]],
  ["Esc は逆向きの選択を動く端のキャレットにする", "]ab[ x", 0, [ESC]],
  ["Esc はキャレットが複数なら主に戻す", "a|b c|d e|f", 1, [ESC, ESC]],
  // 全カーソルでの編集
  ["打鍵は全キャレットに入る", "a|b\nc|d\n|", 0, [type("x"), type("yz")]],
  ["打鍵は全選択を置き換える", "[ab] c [ab] d ]ab[", 0, [type("Z")]],
  ["改行を含む打鍵は全カーソルに入る", "a|b c|d", 0, [type("1\n2")]],
  ["⌫ は全キャレットの前の字を消し行頭なら行をつなぐ", "ab|\n|cd\nef|g", 0, [c("deleteLeft"), c("deleteLeft")]],
  ["⌫ は接するキャレットの消し方をまとめる", "a|b|c|d", 0, [c("deleteLeft"), c("deleteLeft")]],
  ["⌫ は選択とキャレットが混ざっても全部に当たる", "[ab]c|d e]fg[h", 0, [c("deleteLeft")]],
  ["⌦ は全キャレットの後ろの字を消し行末なら行をつなぐ", "a|b|\ncd|\n|ef", 0, [c("deleteRight"), c("deleteRight")]],
  ["⌦ は文書の終わりのキャレットでは消さない", "ab|c|", 0, [c("deleteRight"), c("deleteRight")]],
  ["⌥⌫ は全キャレットの前の語を消す", "foo bar|\nbaz.qux|  x|", 0, [c("deleteWordLeft"), c("deleteWordLeft")]],
  ["改行は全カーソルで字下げを引き継ぐ", "  a|b\n    c|d", 0, [type("\n")]],
  // 全カーソルでの移動・伸縮
  ["←→ は全カーソルで選択の端へ畳み、重なればまとまる", "[ab]|c d]ef[", 0, [c("cursorLeft"), c("cursorRight"), c("cursorLeft"), c("cursorLeft")]],
  ["← は行頭のキャレットを前の行の終わりへ動かす", "ab\n|cd\n|ef", 0, [c("cursorLeft"), c("cursorRight"), c("cursorRight")]],
  ["↑↓ はカーソルごとに覚えた横位置を保つ", "abcd|ef\nx\nabcdefg|h\nab\nabcdefghij", 0, [c("cursorDown"), c("cursorDown"), c("cursorUp")]],
  ["↑↓ は端の行で行頭・行末へ寄せ、重なればまとまる", "a|b\nc|d", 0, [c("cursorUp"), c("cursorDown"), c("cursorDown")]],
  ["↓ は選択を畳んで下へ動く", "a[bc]\nd]ef[\nghi", 0, [c("cursorDown")]],
  ["⇧←→ は全カーソルで伸び、重なればまとまる", "a|b|cd e|f", 0, [c("cursorRightSelect"), c("cursorRightSelect"), c("cursorLeftSelect"), c("cursorLeftSelect"), c("cursorLeftSelect"), c("cursorLeftSelect")]],
  ["⇧← で前へ伸ばした選択が重なると最後に足した向きに倣う", "ab|cd|ef", 1, [c("cursorLeftSelect"), c("cursorLeftSelect"), c("cursorLeftSelect")]],
  ["⇧↑↓ は全カーソルで行をまたいで伸びる", "ab|c\nde|f\nghi\njkl", 0, [c("cursorDownSelect"), c("cursorDownSelect"), c("cursorUpSelect")]],
  ["⌥← は複数のカーソルで 1 字の区切りを飛ばさない", "foo.bar(baz)| qux\na.b|", 0, [c("cursorWordLeft"), c("cursorWordLeftSelect")]],
  ["⌥←→ は全カーソルで語を移る", "foo.bar(baz)| qux\n|  let x = a->b;", 0, [c("cursorWordLeft"), c("cursorWordLeft"), c("cursorWordEndRight"), c("cursorWordEndRight")]],
  ["⇧⌥←→ は全カーソルで語の単位に伸びる", "foo b|ar baz\nqux q|uux", 0, [c("cursorWordEndRightSelect"), c("cursorWordEndRightSelect"), c("cursorWordLeftSelect"), c("cursorWordLeftSelect"), c("cursorWordLeftSelect")]],
  ["⌘←→ は全カーソルで行頭と行末へ動く", "  ab|c\nde|f\n\tg|h", 0, [c("cursorHome"), c("cursorHome"), c("cursorEnd"), c("cursorHomeSelect")]],
  // コピー・カット・ペースト
  ["写した選択は同じ数のカーソルへ 1 つずつ配られる", "[a]-1\n[b\n2] c d e", 0, [COPY, c("cursorEnd"), PASTE]],
  ["写した選択は数の違うカーソルへは全体が入る", "[ab] [cd]\nx y z", 0, [COPY, c("cursorDown"), type("_"), PASTE]],
  ["写した中身に改行があっても配り方は崩れない", "[a\nb] [c\nd]\n12", 0, [COPY, ESC, ESC, c("cursorDown"), c("cursorDown"), D, PASTE]],
  ["空のキャレットの列は行を 1 つずつ写し同じ行は 1 回", "li|n|e1\nline2\nli|ne3", 0, [COPY, ESC, DOWN, PASTE]],
  ["空のキャレットと選択が混ざれば行と選択を写す", "a|bc\n[de]f\nghi", 0, [COPY, PASTE]],
  ["1 本のキャレットで写した行は全カーソルの行の上へ入る", "a|b\ncd\nef", 0, [COPY, c("cursorDown"), DOWN, PASTE]],
  ["1 本の選択を写すと行の数が合えば配られる", "[1\n2\n3]\nab\ncd\nef", 0, [COPY, c("cursorDown"), DOWN, DOWN, PASTE]],
  ["外から写した行は数が合えば 1 行ずつ配られる", "x| y| z|", 0, [pasteExternal("1\n2\n3\n")]],
  ["外から写した CRLF の行も配られる", "x| y|", 0, [pasteExternal("1\r\n2\r\n")]],
  ["外から写した行の数が違えば全体が入る", "x| y| z|", 0, [pasteExternal("1\n2\n")]],
  ["外から写した末尾の改行は 1 つだけ除いて数える", "x| y|", 0, [pasteExternal("1\n2\n\n")]],
  ["配る行が空のカーソルも他のカーソルが入れた分だけずれる", "x| y|", 0, [pasteExternal("1\n\n")]],
  ["カットは全選択を消して写し、同じ数へ配る", "[ab] x [cd] y", 0, [CUT, PASTE]],
  ["空のキャレットの列のカットは行を消して写す", "a|b\ncd\ne|f\ngh", 0, [CUT, PASTE]],
  // 重なったカーソルのまとめ方
  ["⌥⌘↓ が写した選択が重なればまとまる", "a[bc\nd]ef\nghi", 0, [DOWN, DOWN]],
  ["重なった選択は最後に足したカーソルの向きに倣う", "a]bc[d\na[bc]d", 0, [UP, ESC]],
  ["重なった選択は最後に足したのでなければ先にあった向きを保つ", "a]bc[d\na[bc]d\nxy|", 0, [UP, ESC]],
  ["⇧→ で接した選択はまとまらず重なればまとまる", "[a]b[c]d", 0, [c("cursorRightSelect"), c("cursorRightSelect")]],
];

/** 上限の確かめ（本文は `unit` を `count` 回並べたもの。手順ごとの全カーソルを書く代わりに、最後の数と主と最後を書く）。 */
const limits = [
  ["⌘⇧L は上限で後ろから切り押した場所の出現を主に残す", "a ", 10005, 2 * 10004, [L]],
  ["⌥⌘↓ は上限を越えて足さない", "ab\n", 10005, 1, [L, DOWN]],
  ["⌘U は 50 段まで戻す", "a", 60, 0, [...Array(52).fill(c("cursorRight")), ...Array(51).fill(U)]],
];

const swiftString = (s) => JSON.stringify(s);
const swiftCursors = (cs) => `[${cs.map(([a, b]) => `[${a}, ${b}]`).join(", ")}]`;
const swiftAction = (a) => {
  switch (a.kind) {
    case "command": return `.command(${swiftString(a.id)})`;
    case "type": return `.type(${swiftString(a.text)})`;
    case "pasteExternal": return `.pasteExternal(${swiftString(a.text)})`;
    default: return `.${a.kind}`;
  }
};

/** 操作の列（同じ操作の続きは `Array(repeating:count:)` にまとめる）。 */
const swiftActions = (actions) => {
  const runs = [];
  for (const action of actions) {
    const text = swiftAction(action);
    if (runs.length && runs[runs.length - 1].text === text) runs[runs.length - 1].count++;
    else runs.push({ text, count: 1 });
  }
  return runs.map(({ text, count }) => (count === 1 ? `[${text}]` : `Array(repeating: ${text}, count: ${count})`)).join(" + ");
};

const cases = [];
for (const [name, marked, primary, actions] of scenarios) {
  const { text, cursors } = parse(marked, primary);
  model.setValue(text);
  editor.setSelections(cursors.map(selectionOf));
  clipboard = null;
  const out = [];
  for (const action of actions) {
    act(action);
    const board = action.kind === "copy" || action.kind === "cut"
      ? `, clipboard: .init(text: ${swiftString(clipboard.text)}, pieces: ${clipboard.pieces ? `[${clipboard.pieces.map(swiftString).join(", ")}]` : "nil"}, entireLine: ${clipboard.entireLine})`
      : "";
    out.push(
      `        .init(action: ${swiftAction(action)}, text: ${swiftString(model.getValue())}, ` +
        `cursors: ${swiftCursors(cursorsNow())}${board}),`,
    );
  }
  cases.push(
    `    .init(\n      name: ${swiftString(name)}, text: ${swiftString(text)},\n      cursors: ${swiftCursors(cursors)},\n` +
      `      steps: [\n${out.join("\n")}\n      ]),`,
  );
}

const limitCases = [];
for (const [name, unit, count, caret, actions] of limits) {
  model.setValue(unit.repeat(count));
  editor.setSelections([selectionOf([caret, caret])]);
  for (const action of actions) act(action);
  const all = cursorsNow();
  limitCases.push(
    `    .init(\n      name: ${swiftString(name)}, unit: ${swiftString(unit)}, count: ${count}, caret: ${caret},\n` +
      `      actions: ${swiftActions(actions)}, cursorCount: ${all.length},\n` +
      `      primary: [${all[0].join(", ")}], last: [${all[all.length - 1].join(", ")}]),`,
  );
}
editor.dispose();

console.log(`// swiftlint:disable file_length type_body_length

/// VS Code の複数カーソルの規則の正解——monaco-editor ${Deno.env.get("MONACO_VERSION")} の編集器（jsdom の上）で、カーソルの列を置いて
/// 操作を順に当てた結果（scripts/gen-vscode-edit-cases.sh が生成する。手で直さない）。位置はどれも本文のオフセット。
/// カーソルは [動かない端, 動く端] で、列の先頭が主（VS Code の \`getSelections()\` の順）。
enum VSCodeMultiCursorCases {
  /// 当てる操作。\`command\` は VS Code のコマンドの名前。\`escape\` は Esc の割り当て（カーソルが複数なら
  /// \`removeSecondaryCursors\`、1 本で選択があれば \`cancelSelection\`）。\`paste\` は直前に写したもの（行ごと写した印と断片
  /// つき）を、\`pasteExternal\` は印も断片も無い文字列を貼る。
  enum Action: Equatable {
    case command(String)
    case type(String)
    case escape, copy, cut, paste
    case pasteExternal(String)
  }

  /// 写したもの。\`pieces\` は VS Code の \`multicursorText\`、\`entireLine\` は \`isFromEmptySelection\`。
  struct Clipboard: Equatable {
    let text: String
    let pieces: [String]?
    let entireLine: Bool
  }

  struct Step {
    let action: Action
    let text: String
    let cursors: [[Int]]
    var clipboard: Clipboard?
  }

  struct Case {
    let name: String
    let text: String
    let cursors: [[Int]]
    let steps: [Step]
  }

  /// 本文が \`unit\` を \`count\` 回並べたもの、カーソルが \`caret\` のキャレット 1 本から、\`actions\` を当てた結果の数と主と
  /// 最後のカーソル。
  struct LimitCase {
    let name: String
    let unit: String
    let count: Int
    let caret: Int
    let actions: [Action]
    let cursorCount: Int
    let primary: [Int]
    let last: [Int]
  }

  static let cases: [Case] = [
${cases.join("\n")}
  ]

  static let limits: [LimitCase] = [
${limitCases.join("\n")}
  ]
}
// swiftlint:enable type_body_length`);
Deno.exit(0);
