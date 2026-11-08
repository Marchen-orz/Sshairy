import { ai } from "@fig/autocomplete-generators";
import { extraFlag, sharedOptions, SHELLS, versionArg } from "./shared";
import * as more from "./more";

const dynamicGenerator: Fig.Generator = {
  script: ["tool", "list"],
  postProcess: (out) => out.split("\n").map((name) => ({ name })),
};

const verbose = {
  name: ["-v", "--verbose"],
  description: `Print more
     output`,
  isRepeatable: 3,
  icon: "fig://icon?type=flag",
} as const;

const completionSpec: Fig.Spec = {
  name: ["tool", "tl", "al"],
  description: "A fixture tool " + "for the importer",
  parserDirectives: {
    flagsArePosixNoncompliant: true,
    optionArgSeparators: "=",
    unknownDirective: true,
  },
  options: [
    verbose,
    ...sharedOptions,
    extraFlag,
    more.namespaced,
    makeOptions(),
    {
      name: "--format",
      args: {
        name: "format",
        suggestions: [
          ...SHELLS,
          { name: "json", description: "JSON", icon: "x", priority: 90 },
          "yaml",
          { name: ["text", "txt"], insertValue: "text {cursor}" },
        ],
        default: "json",
        generators: ai(),
      },
      exclusiveOn: ["--json"],
      dependsOn: ["--output"],
      requiresSeparator: "=",
    },
  ],
  subcommands: [
    {
      name: "run",
      description: "Run it",
      args: [
        { name: "script", template: ["filepaths", "folders"], isVariadic: true },
        versionArg,
      ],
      generateSpec: async () => ({ name: "x" }),
      loadSpec: "tool/sub",
    },
    {
      name: "dyn",
      args: { generators: dynamicGenerator, isOptional: true },
      loadSpec: (token) => token,
    },
    { name: "cycle", loadSpec: "tool/cycle" },
    { name: "gone", loadSpec: "tool/missing" },
    {
      name: "danger",
      isDangerous: true,
      hidden: true,
      deprecated: { description: "gone" },
      priority: 20,
      insertValue: "danger {cursor}",
    },
    { description: "no name here" },
    { name: "multi\nline" },
    {
      name: "inline",
      args: {
        name: "team",
        isDangerous: true,
        loadSpec: { name: "team", subcommands: [{ name: "members" }] },
      },
    },
    { name: "tpl", description: `static ${"value"} ${1 + 1}` },
    { name: "nested-array", args: [[{ name: "ignored" }], { name: "kept", template: "history" }] },
  ],
  additionalSuggestions: ["extra", { name: "other", description: "Other" }],
};

export default completionSpec;
