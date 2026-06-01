---
description: Rules for when and how to write or update tests
globs: test/**/*.sol
---

# Testing Rules

## When to Write Tests

- During **feature implementation**, tests are written only on explicit request -- do not auto-generate tests while building contracts.
- Once implementation is complete (e.g. during fixes, reviews, or audits), tests are expected and should be written when asked.
- Once tests exist and code changes are made later: make the code change first, then immediately ask the user if you should update the tests before touching them. _(Also in CLAUDE.md so this rule is always in context.)_
- Write tests against **intended behaviour**, not against what the code currently does. If a test fails, ask the user whether the behaviour is correct or the code has a bug -- never silently adjust a test to make it pass.

---

## Assertions

- **Always exact** -- `assertEq(actual, expected)`. Weak assertions like `assertGt(balance, 0)` when the expected value is known are not acceptable.
- Use `assertGt` / `assertLt` only when the result is genuinely variable (e.g. a loss scenario). Even then, compute the expected value and assert it exactly or near-exactly.
- `assertApproxEqRel` only when rounding genuinely prevents an exact comparison -- never as a shortcut.

---

## Events

- Always assert the primary function-specific event -- not just underlying `Transfer` / `Approval`.
- Use `vm.expectEmit` with all arguments verified (topic1, topic2, topic3, data).

---

## Mocking

- Prefer the real code path. Only mock external dependencies (oracles, external protocols) when there is no alternative.
- Never mock internal contract behaviour -- test it directly.
