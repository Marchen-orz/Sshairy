const completionSpec: Fig.Spec = {
  name: "ctrl",
  description:
    "A deliberately long description that keeps going and going so the importer has to cut it at a word boundary rather than in the middle of a word, and it also carries\nnewlines   and   extra spaces that must be folded into single spaces.",
  options: [
    {
      name: "--write",
      args: {
        suggestions: [
          { name: "line", insertValue: "echo hi\n" },
          { name: "tab\there" },
          "plain",
          "",
        ],
      },
    },
  ],
};

export default completionSpec;
