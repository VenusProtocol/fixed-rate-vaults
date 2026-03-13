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
notes/                         # Feature decision logs (git-tracked)
research/                      # Research & design docs (NOT git-tracked)
.task_plan.md                  # Claude's temp execution plan (NOT git-tracked)
```

- Each new feature gets its own folder under `src/`.
- All interfaces live in `src/interfaces/` — not inside feature folders.
- Shared helper contracts (non-feature-specific) go in `src/lib/`.

## Code Design

Must follow these Solidity rules:

- **Custom errors only** — No `require` with strings.
- **NatSpec** on all external/public functions + their interface declarations. Include `@notice`, `@param`, `@return`, `@custom:error`, `@custom:event`.
- **Contract layout:** Constants → Immutables → State vars → Events → Errors → Modifiers → Constructor → receive/fallback
- **Function order:** `external` → `public` → `internal` → `private`. Within each visibility: ACM/access-gated first, then permissionless. Within each access level: state-changing → view → pure.
- **No `public` functions** — Use `internal` + `external` wrapper instead. Exception: inherited/overridden functions (e.g. OZ). State variables **should** be `public` (auto-getter); define the corresponding getter in the interface.
- **Cache everything** — Never SLOAD or external-call the same thing twice. Cache in locals.

## Feature Development Workflow

### Execution Order

1. **Restore context** — Read existing `notes/<feature-name>.md` and `research/<feature-name>/` if they exist
2. **Create plan** — Write `.task_plan.md` with phases, checklist, and goals
3. **Implement** — Write contracts and interfaces following Code Design above
4. **Update notes** — Log decisions and progress at milestones to `notes/<feature-name>.md`
5. **Tests** — Only when explicitly asked (see below)

### Testing

- Tests are written only on explicit request, not automatically during implementation.
- Once tests exist and code changes are made later:
  1. Make the code change first
  2. Ask the user if you should update the tests before touching them

### Task Planning (`.task_plan.md`)

Always create `.task_plan.md` at the project root before starting feature work. This file:
- Contains the execution plan with phases and checklist
- Tracks progress, errors, and current status
- Is **not tracked by git** — purely a working file
- Persists across sessions for the same feature — append, don't overwrite

### Subagent Strategy
- Use subagents for side-effect-free tasks that don't need to persist in the main context window — e.g., when the user asks to explain a piece of code, asks "where is X used?", or wants to compare approaches ("would it be better to do A or B?"). Delegate the research/exploration to a subagent and return the answer.

### Notes (`notes/`)

At key milestones during feature development, update `notes/<feature-name>.md` capturing:
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