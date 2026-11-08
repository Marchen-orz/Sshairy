export { extraFlag } from "./more";

export const sharedOptions: Fig.Option[] = [
  { name: ["-h", "--help"], description: "Show help" },
  { name: "--version", description: "Show version", isPersistent: true },
];

export const SHELLS = ["bash", "zsh"] as const;

export const versionArg: Fig.Arg = { name: "version", isOptional: true };

export function helper() {
  return { name: "--never-evaluated" };
}
