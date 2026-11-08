import { createVersionedSpec } from "@fig/autocomplete-helpers";

const versionFiles = ["2.0.0", "1.0.0", "10.0.0"];

export const getVersionCommand: Fig.GetVersionCommand = async (executeShellCommand) =>
  (await executeShellCommand({ command: "versioned", args: ["--version"] })).stdout;

export default createVersionedSpec("versioned", versionFiles);
