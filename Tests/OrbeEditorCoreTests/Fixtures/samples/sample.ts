// Face layout of a tab.
export interface FaceLayout {
  editorRatio: number;
  focus: "terminal" | "editor";
}

export function normalize(layout: FaceLayout): FaceLayout {
  if (layout.editorRatio <= 0) {
    return { editorRatio: 0, focus: "terminal" };
  }
  return layout;
}
