const a = { name: "--a", args: b };
const b = { name: "b", suggestions: [a] };

const completionSpec: Fig.Spec = {
  name: "cyclic",
  options: [a, { name: "--ok" }],
  subcommands: [...[{ name: "base" }].concat([{ name: "added" }], { name: "single" })],
};

export default completionSpec;
