# CLAUDE.md

Venus Protocol Fixed Rate Vaults — Solidity smart contract project using Foundry.

This is a DeFi protocol handling real funds. Always write clean, secure code — never apply quick patches or workarounds without understanding all side effects. Verify the impact of every change across the codebase. Every task deserves the same level of rigour; nothing should be treated as low priority or left at low quality. Never assume — if in doubt, ask and confirm before proceeding.

---

## Package Manager

Use **yarn** — never use npm.

```bash
yarn install                   # install dependencies
```

---

## Dependencies

Contract dependencies (OpenZeppelin, Venus, etc.) are managed as **git submodules** under `lib/`.

```bash
forge install <org>/<repo>             # add dependency (e.g. OpenZeppelin/openzeppelin-contracts)
forge install <org>/<repo>@<tag>       # pin to a version/tag
forge update <dep>                     # update existing dependency
forge remove <dep>                     # remove dependency
git submodule update --init --recursive  # restore submodules after fresh clone
```

---

## Common Commands

```bash
forge build                    # compile contracts
forge test                     # run tests (fork tests need FORK_ENABLED=true)
forge test -vvv                # run tests with traces
forge test --match-test <name> # run a specific test
yarn format                    # format everything (forge fmt + prettier)
forge fmt                      # format .sol files only
forge fmt --check              # check .sol formatting only
yarn lint:sol                  # lint solidity
```

---

## File Structure

```
src/
  ├── interfaces/              # All contract interfaces
  ├── lib/                     # Shared helpers (e.g. Addresses.sol)
  └── <feature>/               # One folder per feature
        ├── Contract.sol
        └── Helper.sol

test/
  ├── <feature>/               # Tests per feature (mirrors src/)
  └── fork/                    # Fork tests (FORK_ENABLED=true)

script/                        # Deployment scripts
lib/                           # External dependencies (git submodules)
out/                           # Compiled ABIs & artifacts (NOT git-tracked)
research/                      # Research & design docs (NOT git-tracked)

feature-docs/                  # Feature documentation (git-tracked)
                               #   — Single source of truth for each feature
                               #   — How it works, design decisions, trade-offs, and gotchas

foundry.toml                   # Foundry configuration
remappings.txt                 # Import remappings for dependencies
package.json                   # yarn scripts (format, lint, etc.)
```

---

## Tests

If tests exist and code changes are made: make the code change first, then immediately ask the user if you should update the tests before touching them.

---

## Venus Source Code

- **Local (submodules)**: `lib/governance-contracts/` — ACM, governance, cross-chain
- **Remote**: https://github.com/VenusProtocol (use `gh` for CLI access)
