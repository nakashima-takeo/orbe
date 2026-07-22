// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
//
// inshellisense `src/runtime/generator.ts` の改変版。
// シェル実行は Swift 経由（buildExecuteShellCommand → native）。JSC に process が無いため
// GeneratorContext の environmentVariables は空にする（curated spec は cwd 連動が主）。
import log from "../utils/log.js";
import { runTemplates } from "./template.js";
import { buildExecuteShellCommand } from "./utils.js";

const getGeneratorContext = (cwd: string): Fig.GeneratorContext => {
  return {
    environmentVariables: {},
    currentWorkingDirectory: cwd,
    currentProcess: "",
    sshPrefix: "",
    isDangerous: false,
    searchTerm: "",
  };
};

export const runGenerator = async (generator: Fig.Generator, tokens: string[], cwd: string, signal?: AbortSignal): Promise<Fig.Suggestion[]> => {
  signal?.throwIfAborted();
  const { script, postProcess, scriptTimeout, splitOn, custom, template, filterTemplateSuggestions } = generator;

  const executeShellCommand = buildExecuteShellCommand(scriptTimeout ?? 5000, signal);
  const suggestions = [];
  try {
    if (script) {
      const shellInput = typeof script === "function" ? script(tokens) : script;
      const scriptOutput = Array.isArray(shellInput)
        ? await executeShellCommand({ command: shellInput.at(0) ?? "", args: shellInput.slice(1), cwd })
        : await executeShellCommand({ ...shellInput, cwd });

      const scriptStdout = scriptOutput.stdout.trim();
      if (postProcess) {
        suggestions.push(...postProcess(scriptStdout, tokens));
      } else if (splitOn) {
        suggestions.push(...scriptStdout.split(splitOn).map((s) => ({ name: s })));
      }
    }

    if (custom) {
      suggestions.push(...(await custom(tokens, executeShellCommand, getGeneratorContext(cwd))));
    }

    if (template != null) {
      const templateSuggestions = await runTemplates(template, cwd, signal);
      if (filterTemplateSuggestions) {
        suggestions.push(...filterTemplateSuggestions(templateSuggestions));
      } else {
        suggestions.push(...templateSuggestions);
      }
    }
    return suggestions.filter((s) => s != null);
  } catch (e) {
    const err = typeof e === "string" ? e : e instanceof Error ? e.message : e;
    log.debug({ msg: "generator failed", err, script, splitOn, template });
  }
  return suggestions.filter((s) => s != null);
};
