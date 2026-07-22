// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
//
// inshellisense `src/runtime/template.ts` の改変版。
// ディレクトリ列挙を node:fs から Swift 注入の native readdir へ置換。
// history / help テンプレートは未対応。
import log from "../utils/log.js";
import { readdir } from "../native/exec.js";

const filepathsTemplate = async (cwd: string, signal?: AbortSignal): Promise<Fig.TemplateSuggestion[]> => {
  signal?.throwIfAborted();
  const files = await readdir(cwd);
  return files.map((f) => ({
    name: f.name,
    priority: 55,
    context: { templateType: "filepaths" },
    type: f.isDirectory() ? "folder" : "file",
  }));
};

const foldersTemplate = async (cwd: string, signal?: AbortSignal): Promise<Fig.TemplateSuggestion[]> => {
  signal?.throwIfAborted();
  const files = await readdir(cwd);
  return files
    .filter((f) => f.isDirectory())
    .map((f) => ({ name: f.name, priority: 55, context: { templateType: "folders" }, type: "folder" }));
};

export const runTemplates = async (template: Fig.TemplateStrings[] | Fig.Template, cwd: string, signal?: AbortSignal): Promise<Fig.TemplateSuggestion[]> => {
  const templates = template instanceof Array ? template : [template];
  return (
    await Promise.all(
      templates.map(async (t) => {
        try {
          switch (t) {
            case "filepaths":
              return await filepathsTemplate(cwd, signal);
            case "folders":
              return await foldersTemplate(cwd, signal);
            case "history":
            case "help":
              return [];
          }
        } catch (e) {
          log.debug({ msg: "template failed", e, template: t, cwd });
          return [];
        }
      }),
    )
  ).flat();
};
