const completionSpec: Fig.Spec = {
  name: "sub",
  description: "Nested spec reached through loadSpec",
  options: [{ name: "--depth", args: { name: "n" } }],
  subcommands: [{ name: "deeper", loadSpec: "tool/deeper" }],
};

export default completionSpec;
