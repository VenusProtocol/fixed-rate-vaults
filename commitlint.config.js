module.exports = {
  extends: ["@commitlint/config-conventional"],
  ignores: [commit => commit.includes("[skip ci]"), commit => commit.includes("Merge pull request")],
  rules: {
    "type-enum": [2, "always", ["build", "chore", "ci", "docs", "feat", "fix", "refactor", "test"]],
  },
};
