const completionSpec: Fig.Spec = {
  name: "cycle",
  subcommands: [{ name: "back", loadSpec: "tool" }],
};

export default completionSpec;
