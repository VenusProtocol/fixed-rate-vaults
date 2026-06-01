---
name: unit-test
description: Write Foundry unit tests for a contract — reads the contract, studies existing test patterns, generates a comprehensive test file
argument-hint: <ContractName or path>
---

# Unit Test Skill

Write Foundry tests for: **$ARGUMENTS**

Follow all rules in `.claude/rules/testing.md` throughout.

---

## Workflow

Read the contract, its interface, and existing tests. Use subagents when needed. Draft a plan covering what to test and which paths to cover, present it to the user, and only proceed once confirmed.

The guidance below applies to whichever test type the user requests.

---

## Unit Tests

One test file per contract. The main feature contract is the primary focus. File structure:

```solidity
// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { VaultTestBase } from "./VaultTestBase.t.sol";

contract <ContractName>Test is <BaseContract> {
    function setUp() external {
        _makeActors();
        _deployTokens();
        _deploySystem();
        _createVault();
    }

    // ──────────────────────────────────────────────────────────────────────
    // 1A — Section Name
    // ──────────────────────────────────────────────────────────────────────
}
```

**Ordering:** Full path test first -- one comprehensive happy path test asserting every important value (balances, state, events). This is the canonical reference for how the feature behaves and makes manual review easy. Focused tests come after -- isolate a specific behaviour or edge case, with a comment explaining what is skipped and why:

```solidity
// Full deposit path covered in test_deposit_fullPath.
// This test focuses on fee scaling only -- vault state assertions skipped.
```

**Patterns:**

- **Setup**: Chain state helpers: `_openVault()` → `_lockVault()` → `_settleVault()`.
- **Actors**: `vm.prank()` for single calls, `vm.startPrank()`/`vm.stopPrank()` for sequences.
- **Tokens**: Always `mint` → `approve` → action.
- **Reverts**: `vm.expectRevert(ContractName.ErrorName.selector)` -- never string-based.
- **Time**: `vm.warp()` referencing runtime timestamps (e.g. `vault.runtime().lockEndTime + 1`).
- **Prices**: `_setPrice(address asset, uint256 priceUSD18)`.

**Don't:**

- Test OZ/base contract internals (ERC20, ERC4626, Ownable).
- Create new mocks if existing ones in `test/<feature>/mocks/` suffice.
- Duplicate revert paths already tested in another file.
- Add fuzz or invariant tests unless explicitly asked -- only for math-heavy functions where a wide input range genuinely uncovers bugs.

---

## E2E Tests

One `E2EScenarios.t.sol` per feature. Ask the user to confirm the path list before writing.

- **Full path test first** -- complete happy path, every important assertion. Serves as the canonical reference for how the feature works and makes manual review easy.
- **Focused tests after** -- specific scenarios. Add a comment explaining what is intentionally skipped and why:
  ```solidity
  // Full liquidation path covered in test_liquidate_fullPath.
  // This test focuses on incentive scaling only -- vault state assertions skipped.
  ```

---

## Fork Tests

Fork tests live in `test/fork/`. Run with `FORK_ENABLED=true`.

- Deploy the new contract inside the fork test itself -- do not rely on a live deployment.
- Use real mainnet addresses for already-deployed contracts (vTokens, oracles, comptroller, PSR) so live state (interest accrual, exchange rates) is part of the test.
- Mirror the E2E flow but validate calculations against real on-chain data.

---

## Verify

Run `forge test --match-contract <TestContractName> -vvv` and fix any failures before reporting to the user.

---

## Post-deployment Changes

This applies when a contract is already deployed in production and a subsequent PR introduces new functionality or changes — not the initial implementation PR.

- Update the existing unit test file for the affected contract.
- Create a new focused test file covering all scenarios introduced or affected by the change.
