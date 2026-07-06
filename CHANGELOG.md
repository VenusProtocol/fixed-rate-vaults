## [1.0.0-dev.3](https://github.com/VenusProtocol/fixed-rate-vaults/compare/v1.0.0-dev.2...v1.0.0-dev.3) (2026-07-06)

### Bug Fixes

* disable provenance for private project ([ec81d05](https://github.com/VenusProtocol/fixed-rate-vaults/commit/ec81d0580c7bace758fcb5a3cd1ac52c74aaaaa5))

## [1.0.0-dev.2](https://github.com/VenusProtocol/fixed-rate-vaults/compare/v1.0.0-dev.1...v1.0.0-dev.2) (2026-07-06)

### Features

* add renamable institutionName to institutional vault config ([a405d07](https://github.com/VenusProtocol/fixed-rate-vaults/commit/a405d079b0787394784d1a09fd2fbe8749ae2534))
* move institutionName to standalone vault field with controller override for legacy vaults ([69d24e4](https://github.com/VenusProtocol/fixed-rate-vaults/commit/69d24e413992e2575ca6f72193d2e640c238a1a2))
* updating deployment files ([58e64a3](https://github.com/VenusProtocol/fixed-rate-vaults/commit/58e64a3f7c37071ea909959bb7b7cbcdb81c71f9))
* updating deployment files ([1f813ec](https://github.com/VenusProtocol/fixed-rate-vaults/commit/1f813ecf5e972c06a74da6985bc54df906ee2b58))
* updating deployment files ([8aabb08](https://github.com/VenusProtocol/fixed-rate-vaults/commit/8aabb0883232eed9ec95be4543577f3c1878bb37))

### Bug Fixes

* [I02] setInstitutionNameOverride Mistaken Override Cannot Be Undone ([cd804d0](https://github.com/VenusProtocol/fixed-rate-vaults/commit/cd804d0f01db7eabaaec9fa06d0f8e64774f4f57))
* append trailing newline to deployment export so CI gate only trips on real changes ([9609d17](https://github.com/VenusProtocol/fixed-rate-vaults/commit/9609d174a2c1ed9e43c3b37a5e6462f8cdfea482))

## 1.0.0-dev.1 (2026-06-30)

### Features

* (wip) margin deposit mechanism, institution adds collateral during open period ([126e540](https://github.com/VenusProtocol/fixed-rate-vaults/commit/126e5408c7500d551b393635f2f9622e3978549e))
* add MAX_APY_BPS cap on fixedAPY and tidy comments and variable names ([dc57e93](https://github.com/VenusProtocol/fixed-rate-vaults/commit/dc57e93be55b1efdda035c3b97fae649ec3596a0))
* **deployment:** add deployment scripts and deployment on testnet ([dd88bdd](https://github.com/VenusProtocol/fixed-rate-vaults/commit/dd88bddd6047def1b7a291b32f31170726793f91))
* updating deployment files ([0474b60](https://github.com/VenusProtocol/fixed-rate-vaults/commit/0474b60833e83d5f0c67094a97ea999caf7ef7eb))
* updating deployment files ([b2810e7](https://github.com/VenusProtocol/fixed-rate-vaults/commit/b2810e7d1ba8f1a84c8bb438117dddfe1e3e0201))
* **WIP:** add institutional vault contracts ([9530847](https://github.com/VenusProtocol/fixed-rate-vaults/commit/95308478880b3901028af4038655d50847768cd9))

### Bug Fixes

* [14] extract _getAssetValueUSD to eliminate oracle pricing duplication ([38393a6](https://github.com/VenusProtocol/fixed-rate-vaults/commit/38393a6427bcfe78cf9ec385f0498d6f33b29d4f))
* [15] Unnecessary address prediction in createVault ([a756a8d](https://github.com/VenusProtocol/fixed-rate-vaults/commit/a756a8d6eb7e32a0a13cc6b77b36caf01881ced4))
* [8] _baseURI not being overridden returns empty metadata ([1f94eba](https://github.com/VenusProtocol/fixed-rate-vaults/commit/1f94eba3c2cb1b1d6d8d1989cebc82fc966063f2))
* [9] Inconsistent handling of Fee-on-Transfer tokens ([cb3037a](https://github.com/VenusProtocol/fixed-rate-vaults/commit/cb3037aa4a8ada9089191c886e1203ddce5c95a1))
* [I01] Remove unused idealCollateralValuation field and oracle call ([9d5b8e5](https://github.com/VenusProtocol/fixed-rate-vaults/commit/9d5b8e5036a480e05159453779c034a84460b6d6))
* [I03] Remove unreachable maxBorrowCap == 0 check ([e8e0456](https://github.com/VenusProtocol/fixed-rate-vaults/commit/e8e0456161214377c799c1dae7c411febf1b137f))
* [I04] Add ACM-gated refundCollateral to recover institution collateral from MarginDeposited ([b0201f5](https://github.com/VenusProtocol/fixed-rate-vaults/commit/b0201f5fe77338f9d524202b3db0d31aee0852a7))
* [I04] Rename refundCollateral to cancelVault and allow WaitingForMargin ([2aa546d](https://github.com/VenusProtocol/fixed-rate-vaults/commit/2aa546d269c5d18cdc41ff50b0cd807269f6864a))
* [I05] Remove unused ZeroAddress error from InstitutionalLoanVault ([ec80e0c](https://github.com/VenusProtocol/fixed-rate-vaults/commit/ec80e0cedc338fc77e3e1456a1789c14d736d4b1))
* [M02] Add liquidation invariant checks to risk config validation ([84af7cb](https://github.com/VenusProtocol/fixed-rate-vaults/commit/84af7cb2321dce0294332bf81c6443a359856243))
* [VLF-02] Allow final supplier to top off residual capacity below minSupplierDeposit. ([a4caa72](https://github.com/VenusProtocol/fixed-rate-vaults/commit/a4caa724480965f36b0c0e452a4002a80a028b2c))
* [VLF-04] Multi-step state catch-up after Fundraising to block late claimRaisedFunds. ([dbd79b0](https://github.com/VenusProtocol/fixed-rate-vaults/commit/dbd79b04a652dc1e2a157070dd311a5732552fe6))
* [VLF-04] Reject claimRaisedFunds outside [lockStartTime, lockEndTime) window. ([bd06150](https://github.com/VenusProtocol/fixed-rate-vaults/commit/bd06150b9a73cf1a1f3287d558b60db3a8d37bf8))
* [VLF-08] Bind approveTransfer to specific recipient. ([d132cdf](https://github.com/VenusProtocol/fixed-rate-vaults/commit/d132cdf98d08f82013f89c438bcb9e9ee1e1cfbf))
* [VLF-09] Probe resilient oracle for supply and collateral assets in createVault. ([5833cc1](https://github.com/VenusProtocol/fixed-rate-vaults/commit/5833cc187040c710c94a0eca6872cf1a6af2a133))
* [VLF-17] Mark renounceOwnership overrides as pure. ([19db29e](https://github.com/VenusProtocol/fixed-rate-vaults/commit/19db29ea6453e9cebd8f02510f597eb931536830))
* [VLF-19] Drop redundant unchecked block from loop counter increment. ([261cfc6](https://github.com/VenusProtocol/fixed-rate-vaults/commit/261cfc60986ec72c5366ddeeef93136c0b8a4293))
* [VLF-20] Use canonical helpers (_outstandingDebt, asset) instead of direct storage reads. ([a2249fd](https://github.com/VenusProtocol/fixed-rate-vaults/commit/a2249fd8faa7bba9b7d478adbfe5a8030dd32efc))
* add treasury to controller, guard sweep with isActive, clean interface ([3adeead](https://github.com/VenusProtocol/fixed-rate-vaults/commit/3adeeadb6ce0c1c42b808c5e73f0da8273aaec78))
* add ZeroAddress check, reset stale approval, and expose sweep via controller ([f6b1126](https://github.com/VenusProtocol/fixed-rate-vaults/commit/f6b11264876b0486695783269be6948ef09f5834))
* advance state before LT check, add pause guard to repayBadDebt, fix CEI in liquidation ([8d07257](https://github.com/VenusProtocol/fixed-rate-vaults/commit/8d072578f5ee50ae702d3b65ba8f9e96d59b92cd))
* ci ([6a0cf29](https://github.com/VenusProtocol/fixed-rate-vaults/commit/6a0cf291bf7015b1d8d302c435abc7a246d1611f))
* claimRaisedFunds drains early repayments, track collateral seized in liquidations ([1fe064e](https://github.com/VenusProtocol/fixed-rate-vaults/commit/1fe064eb7216e08f16dea9811e19da8c97386df5))
* correct repository URL for npm publishing ([1f0dba0](https://github.com/VenusProtocol/fixed-rate-vaults/commit/1f0dba078bb559779fa8cea8be49f087e882ad5f))
* emit old+new in all parameter events, fix natspec gaps, remove unused error ([b3169d0](https://github.com/VenusProtocol/fixed-rate-vaults/commit/b3169d03b13ac476c84244d819671050ffab6c0e))
* improve natspecs ([455cb44](https://github.com/VenusProtocol/fixed-rate-vaults/commit/455cb442a1266b55d73bdeb60658c3d39bc65f31))
* input validation, events, and interface compliance ([51ef523](https://github.com/VenusProtocol/fixed-rate-vaults/commit/51ef52312c3011557f209ef9029b2062d12fe045))
* limit solhint linting to src contracts ([2bf2fa7](https://github.com/VenusProtocol/fixed-rate-vaults/commit/2bf2fa78210f8ab735a6b45c7cf043bcb640e27a))
* move risk parameter validation to controller, consolidate boundary tests ([b051783](https://github.com/VenusProtocol/fixed-rate-vaults/commit/b051783f04239d2cd55ddfd7dd7a5f826abdbaf9))
* natspec corrections, vacuous assertion, underflow guard, sweep check ([d448a91](https://github.com/VenusProtocol/fixed-rate-vaults/commit/d448a91e22ec5e0208d13160cd740b0b379a1d76))
* oracle checks, collateral accounting, PSR resilience, init validation ([6b8574b](https://github.com/VenusProtocol/fixed-rate-vaults/commit/6b8574bbade7f74f2fe5675a7b0e5e796585098f))
* oracle scaling, collateral tracking, withdraw/redeem overrides ([f1da6e0](https://github.com/VenusProtocol/fixed-rate-vaults/commit/f1da6e05888cd61b2f1972d3271adedc44c1343b))
* psr IncomeType interface ([3b78f9b](https://github.com/VenusProtocol/fixed-rate-vaults/commit/3b78f9b9fabcab22100119ca6fdb7978f69776eb))
* remove upper bound on liquidation incentive, improve adapter interface natspec ([3b2fb20](https://github.com/VenusProtocol/fixed-rate-vaults/commit/3b2fb20cda1cc0451b7485f5ea2781101550c325))
* replace single-level pause with two-level partial/complete pause system ([2b3dc23](https://github.com/VenusProtocol/fixed-rate-vaults/commit/2b3dc2320d0409bcdf61707228ebaedb9076598f))
* review fixes — remove dead code, allow collateral withdrawal in Liquidated state, optimize gas ([65f67ee](https://github.com/VenusProtocol/fixed-rate-vaults/commit/65f67ee67bd5288c8961b9a3b7345bbbeddce2f7))
* simplify seize math by canceling MANTISSA_ONE round-trip ([b62cc19](https://github.com/VenusProtocol/fixed-rate-vaults/commit/b62cc195f5a62207771c1f210b9146d9badb0fd4))
* state checks, upper bounds, renounceOwnership, MANTISSA rename ([9bb4e74](https://github.com/VenusProtocol/fixed-rate-vaults/commit/9bb4e74386262719bf1bac41aa724956985a0734))
* totalAssets parity for pre-terminal states, add position token ownership acceptance ([98f2850](https://github.com/VenusProtocol/fixed-rate-vaults/commit/98f285034da8e95096f4993743278243fe9c7d32))
