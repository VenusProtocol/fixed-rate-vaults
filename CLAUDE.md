# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Venus Protocol Fixed Rate Vaults. Solidity project using Foundry framework.

## Package Manager

- **Use `yarn`** — never use `npm`. Run `yarn install` for dependencies.

## Common Commands

```bash
forge build                    # compile contracts
forge test                     # run tests (fork tests auto-run when FORK_ENABLED=true)
forge test -vvv                # run tests with traces
forge test --match-test <name> # run specific test
forge fmt                      # format solidity files
forge fmt --check              # check formatting
solhint 'src/**/*.sol'         # lint solidity
```

## File Structure

```
src/
  ├── interfaces/              # All contract interfaces
  ├── lib/                     # Shared helpers (e.g. Addresses.sol)
  ├── <feature>/               # Feature folder (one per feature)
  │   ├── Contract.sol
  │   └── Helper.sol
  └── ...
test/                          # Forge test files
script/                        # Deployment scripts
lib/                           # Dependencies (submodules)
design/                          # Feature decision logs (git-tracked)
research/                      # Research & design docs (NOT git-tracked)
.task_plan.md                  # Claude's temp execution plan (NOT git-tracked)
```

- Each new feature gets its own folder under `src/`.
- All interfaces live in `src/interfaces/` — not inside feature folders.
- Shared helper contracts (non-feature-specific) go in `src/lib/`.

## Code Design

Must follow these Solidity rules:

### Contract Layout (top → bottom)

1. Constants (`public constant`)
2. Immutables (`public immutable` or `internal immutable`)
3. State variables (`public` for auto-getters where possible; `internal` for structs — see Structs below)
4. Events
5. Errors (custom errors only — **no `require` with strings**)
6. Modifiers
7. Constructor / `initialize`
8. `receive` / `fallback`
9. Functions (ordered by visibility, see below)

### Function Ordering

Within the functions section, order by visibility:

`external` → `public` → `internal` → `private`

Within each visibility group:
1. ACM / access-gated (e.g. `onlyOwner`, `_checkAccessAllowed`) first
2. Permissionless second

Within each access level:
1. State-changing
2. `view`
3. `pure`

### Function Visibility

- **No `public` functions** — Use `internal` helper + `external` wrapper instead.
  - **Exception:** Inherited/overridden functions from OZ or other base contracts (e.g. `totalAssets()`, `maxDeposit()`).
- State variables **should** be `public` (auto-getter). Define the corresponding getter signature in the interface.
  - **Exception:** Struct state variables — Solidity `public` structs generate flattened return values (one value per field), not a full struct return. Use `internal` storage + explicit `external` getter that returns the struct from `memory`.

### Constants

- Constants in contracts **must** be `public constant` (auto-getter).
- Constants in `library` contracts **must** be `internal constant` (Solidity restriction — libraries cannot have `public` state).

### NatSpec

**Comment style:**
- **Multiline** NatSpec (2+ tags or long descriptions) → use `/** ... */` block comments.
- **Single-line** NatSpec (one short tag) → use `///` inline comments.

Required on all `external` and `public` functions **and** their interface declarations:
- `@notice` — what the function does
- `@param` — each parameter
- `@return` — each return value
- `@custom:error` — each custom error the function can revert with
- `@custom:event` — each event the function can emit

**Error attribution rule:**
- `external`/`public` functions document **only** errors thrown directly in their own body.
- Errors originating from `internal` helpers are documented on those `internal` functions instead.
- **Interface declarations** may include the full list of possible errors (direct + internal) for integrator convenience. Only include errors added by the feature contract — no need to document errors from imported OZ or ACM base contracts.

### Caching

- **Cache everything** — Never SLOAD or external-call the same value twice. Cache in local variables.
- Copy storage structs to `memory` at function entry when reading multiple fields.
- Cache `msg.sender`, array lengths, and repeated mapping lookups.

### Error Handling

- **Custom errors only** — never `require(condition, "string")`.
- Define errors in the interface, not the implementation contract.
- Prefix errors with the contract/interface name context (e.g. `VaultNotActive`, `InsufficientCollateral`).

### General Style

- Use named return variables only when it improves readability; otherwise use explicit `return`.
- Use `uint256` over `uint` — always explicit bit width.
- Avoid magic numbers — define named constants.
- One contract per file; filename matches contract name.

## Feature Development Workflow

### Execution Order

1. **Restore context** — Read existing `design/<feature-name>.md` and `research/<feature-name>/` if they exist
2. **Create plan** — Write `.task_plan.md` with phases, checklist, and goals
3. **Implement** — Write contracts and interfaces following Code Design above
4. **Update notes** — Log decisions and progress at milestones to `design/<feature-name>.md`
5. **Tests** — Only when explicitly asked (see below)

### Testing

- Tests are written only on explicit request, not automatically during implementation.
- Once tests exist and code changes are made later:
  1. Make the code change first
  2. Ask the user if you should update the tests before touching them

### Task Planning — MANDATORY (`.task_plan.md`)

Always create `.task_plan.md` at the project root before starting feature work. This file:
- Contains the execution plan with phases and checklist
- Tracks progress, errors, and current status
- Is **not tracked by git** — purely a working file
- Persists across sessions for the same feature — append, don't overwrite
- **Must include a "Solidity Rules" section** at the top — read the **Code Design** section from `CLAUDE.md` and write a condensed summary of all rules into the plan file as a quick-reference checklist. This keeps the rules in working context even if `CLAUDE.md` gets compressed.

### Subagent Strategy
- Use subagents for side-effect-free tasks that don't need to persist in the main context window — e.g., when the user asks to explain a piece of code, asks "where is X used?", or wants to compare approaches ("would it be better to do A or B?"). Delegate the research/exploration to a subagent and return the answer.

### Design (`design/`)

At key milestones during feature development, update `design/<feature-name>.md` capturing:
- Feature name and one-line summary
- Key design decisions and **why** they were made
- Trade-offs considered
- Any gotchas or things to watch out for

Always read existing notes before starting work on a feature.

### Research (`research/`)

For every feature, check `research/<feature-name>/` for:
- **Design docs** — architecture, interface design, flow diagrams
- **Implementation docs** — step-by-step implementation details
- **Reference material** — relevant protocol docs, external references
- **Analysis** — security considerations, gas analysis, comparisons

These files can be created by the user (pasted in) or by Claude during research phases. Research folder is **not git-tracked**.

**Important**: Research docs (especially implementation docs) may contain code snippets — treat these as pseudo-code for inspiration only, NOT as source of truth. Always write correct, bug-free logic yourself. If you see a better approach than what's described in the docs, ask the user before deviating — unless explicitly told to follow the doc exactly.

### Rules

1. **Read before decide** — Before major decisions, re-read the plan file.
2. **No landmines** — Find root causes, no temporary fixes. Leave no hidden hazards in the code.
3. **2-Action Rule** — After every 2 search/browse operations, IMMEDIATELY save key findings to files.
4. **Update after act** — After completing any phase: mark status, log errors, note files modified.
5. **Log ALL errors** — Every error goes in the plan file.
6. **Never repeat failures** — `if action_failed: next_action != same_action`. Track attempts, mutate approach.
7. **3-Strike Protocol** — After 3 failed attempts at the same problem, escalate to user.

### Venus Context

For Venus-related source code search:
- **Local (submodules)**: `lib/governance-contracts/` (ACM, governance, cross-chain)
- **Remote**: https://github.com/VenusProtocol (consider use `gh`)