# DualTranche Vault Hook

> **Volatility-Gated Tranched Liquidity with Idle Capital Lending**
---

## Overview

**DualTranche Vault Hook** solves two compounding problems that have plagued concentrated liquidity LPs since Uniswap v3: **idle out-of-range capital** and **bad-timing entries**.

It does this with a single coordinated system built as a Uniswap v4 hook:

- A **volatility gate** that prevents Junior LPs from entering at statistically bad times
- An **automatic capital router** that sends Senior LP capital to a lending vault the moment it stops earning swap fees

The result: every dollar in the pool is earning *something* at all times — either swap fees or lending yield — regardless of whether the price is in or out of range.

---

## Problem Statement

Concentrated liquidity AMMs have a fundamental idle capital problem. The moment price leaves an LP's range, their capital earns **zero** — no fees, no yield, nothing. On volatile pairs, LPs can spend 40–70% of their time out of range, completely idle, while still bearing full price exposure on one side of the position.

Simultaneously, LPs have no systematic protection from entering at the worst possible time — right before a large price move that instantly pushes them out of range and crystallizes impermanent loss.

These two problems compound:

- Bad entries → IL accumulates immediately → LP exits in frustration
- Out-of-range capital → idle TVL → LPs underperform simple holding

No existing hook addresses both problems in a unified, on-chain, automatic way.

---

## Solution

DualTranche introduces two LP tiers — **Senior** and **Junior** — that share the same pool but have different risk/reward profiles. A shared volatility signal coordinates the behavior of both tiers automatically.

| | Senior (StableLP) | Junior (ActiveLP) |
|---|---|---|
| **Entry** | Always open | Volatility-gated |
| **Fee share** | 30% of swap fees | 70% of swap fees |
| **Out-of-range** | Capital routed to ERC4626 vault | Capital sits idle |
| **Vault yield** | 90% of vault yield | 10% boost from vault yield |
| **IL exposure** | Smoothed via yield | Full exposure |
| **Target LP** | Passive, risk-averse | Active, yield-maximizing |

---

## Tranche Architecture

### Senior Tranche — StableLP

**Who it's for**: LPs who want predictable, low-risk yield comparable to a money-market account with AMM upside.

**What they get**:
- Always open for deposits — no volatility gate
- Guaranteed floor fee share when in-range (30% of all swap fees)
- When out of range: capital automatically routed to a whitelisted ERC4626 lending vault (Aave, Morpho)
- Earn lending APY on 100% of out-of-range capital — **zero idle time**
- When price returns to range: capital automatically recalled from vault and redeployed

**What they give up**:
- Capped fee share (30% max, not 100%)
- 1-block latency on capital recall during sudden large swaps

---

### Junior Tranche — ActiveLP

**Who it's for**: LPs who want maximum fee capture and accept higher volatility risk in exchange for better risk-adjusted entry timing.

**What they get**:
- 70% of swap fees when in-range
- Volatility-gated entry: only depositable when 24hr realized vol is below the pool threshold
- Statistically better entry prices — entering during calm periods means less immediate IL risk
- 10% yield boost funded by Senior vault yield during high-vol periods

**What they give up**:
- Cannot deposit during high-volatility windows
- Full IL exposure — not smoothed
- No automatic out-of-range yield (capital sits idle out of range)

---

## The Volatility Gate

The volatility gate is the architectural innovation that makes both tranches work coherently.

```
                    VolatilityOracle
                         │
          ┌──────────────▼──────────────┐
          │   getAnnualizedVol()        │
          │   24hr realized vol in bps  │
          └──────────────┬──────────────┘
                         │
           vol < threshold?
          ┌──────────────┴──────────────┐
         YES                           NO
          │                             │
   Junior gate OPEN            Junior gate CLOSED
   ├── Junior deposits OK       ├── Junior deposits REVERT
   └── emit JuniorGateOpened   └── emit JuniorGateClosed
```

The gate serves **two purposes simultaneously**:

1. **For Junior LPs** — Acts as a deposit filter. Prevents entering at statistically bad times (high vol = price is moving fast = high IL risk immediately on entry).

2. **For Senior LPs** — Acts as a capital routing signal. High vol means price is likely to leave the Senior range soon, meaning more time earning lending APY rather than swap fees.

**Oracle failure fallback**: If the oracle reverts or is unavailable, the gate defaults to **CLOSED** (conservative). Swaps and withdrawals are never blocked by oracle failure — only Junior deposits are affected.

---

## Capital Routing

Senior LP capital is automatically routed to and recalled from a whitelisted ERC4626 vault based on whether the current pool tick is within the Senior LP's registered range.

### Route to Vault (Out-of-Range)

```
afterSwap fires
    │
    └── _checkAndRouteCapital()
              │
              ├── currentTick outside seniorTickRange?
              │       AND capitalInVault = false?
              │
              └── YES → _routeCapitalToVault()
                          ├── token0.approve(vault, idleAmount)
                          ├── vault.deposit(idleAmount, hook)
                          ├── state.capitalInVault = true
                          ├── state.vaultShares0 = sharesReceived
                          └── emit CapitalRoutedToVault
```

### Recall from Vault (Back In-Range)

```
afterSwap fires
    │
    └── _checkAndRouteCapital()
              │
              ├── currentTick inside seniorTickRange?
              │       AND capitalInVault = true?
              │
              └── YES → _recallCapitalFromVault()
                          ├── vault.redeem(vaultShares, hook, hook)
                          ├── yieldEarned = redeemed - depositedAmount
                          ├── 90% → trancheAccounting.vaultYieldPool (Senior)
                          ├── 10% → trancheAccounting.juniorBoostPool (Junior)
                          ├── state.capitalInVault = false
                          └── emit CapitalRecalledFromVault
```

Capital recall also happens inside `beforeRemoveLiquidity` when a Senior LP withdraws and capital is still in the vault — ensuring withdrawals always succeed.

---

## Fee Distribution

Every swap triggers a fee split in `afterSwap`:

```
Swap generates totalFee
        │
        ├── 30% → seniorFeePool  (claimable by Senior LPs pro-rata)
        └── 70% → juniorFeePool  (claimable by Junior LPs pro-rata)
```

**Vault yield split** (when capital recalled):
```
yieldEarned from vault
        │
        ├── 90% → vaultYieldPool  (Senior LPs)
        └── 10% → juniorBoostPool (Junior LPs — compensation for IL risk)
```

**Claiming**:

```solidity
// Senior LP claims: fee share + vault yield, pro-rata to sLP balance
hook.claimSeniorYield(key);

// Junior LP claims: fee share + vault boost, pro-rata to jLP balance
hook.claimJuniorYield(key);
```

Accounting uses Synthetix-style reward-per-share with per-address debt tracking — yield accumulates correctly even when shares are transferred between addresses.

---

## System Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│                            Uniswap v4 Pool                                 │
│                                                                            │
│   ┌──────────────┐   beforeAddLiq    ┌─────────────────────────────────┐  │
│   │ Senior LP    │ ────────────────► │                                 │  │
│   │              │                   │      DualTranche Vault Hook     │  │
│   │ Junior LP    │ ────────────────► │                                 │  │
│   │  (vol-gated) │   afterAddLiq     │  afterSwap:                     │  │
│   └──────────────┘                   │    - split fees 30/70           │  │
│                                      │    - check range                │  │
│   ┌──────────────┐   afterSwap       │    - route/recall capital       │  │
│   │   Swapper    │ ────────────────► │                                 │  │
│   └──────────────┘                   │  beforeAddLiq:                  │  │
│                                      │    - vol gate for juniors       │  │
│                                      └──────────────┬──────────────────┘  │
└─────────────────────────────────────────────────────┼──────────────────────┘
                                                      │
              ┌───────────────────────────────────────┼────────────────────┐
              │                                       │                    │
              ▼                                       ▼                    ▼
  ┌──────────────────────┐             ┌──────────────────┐  ┌───────────────────┐
  │   SeniorShares       │             │  JuniorShares    │  │  CapitalVault     │
  │   (ERC20 / sLP-*)    │             │  (ERC20 / jLP-*) │  │  (ERC4626)        │
  │                      │             │                  │  │                   │
  │  - Always depositable│             │  - Vol-gated     │  │  - Aave v3 /      │
  │  - 30% fee share     │             │  - 70% fee share │  │    Morpho Blue    │
  │  - Vault yield       │             │  - Max exposure  │  │  - Earns APY on   │
  │  - Auto-routed idle  │             │  - Entry quality │  │    idle capital   │
  └──────────────────────┘             └──────────────────┘  └───────────────────┘
              │                                                        ▲
              ▼                                                        │
  ┌──────────────────────┐                              rebalance() / afterSwap
  │  VolatilityOracle    │
  │                      │
  │  - 24hr realized vol │
  │  - 1hr result cache  │
  │  - Gate signal       │
  └──────────────────────┘
```

### Hook Permissions

| Hook | Enabled | Purpose |
|---|---|---|
| `afterInitialize` | ✅ | Deploy SeniorShares + JuniorShares tokens |
| `beforeAddLiquidity` | ✅ | Volatility gate for Junior deposits |
| `afterAddLiquidity` | ✅ | Mint sLP / jLP shares to LP |
| `beforeRemoveLiquidity` | ✅ | Recall vault capital before Senior withdrawal |
| `afterRemoveLiquidity` | ✅ | Burn sLP / jLP shares |
| `afterSwap` | ✅ | Split fees 30/70; check range; route/recall capital |
| `beforeSwap` | ❌ | — |
| `beforeInitialize` | ❌ | — |

**Required hook address flags**: `0x1F40`

```
AFTER_INITIALIZE | BEFORE_ADD_LIQUIDITY | AFTER_ADD_LIQUIDITY
| BEFORE_REMOVE_LIQUIDITY | AFTER_REMOVE_LIQUIDITY | AFTER_SWAP
```

---

## Contract Structure

```
dual-tranche-vault-hook/
├── src/
│   ├── DualTrancheVaultHook.sol      # Main hook — 674 lines, all core logic
│   ├── SeniorShares.sol              # ERC20 sLP share token (hook-gated mint/burn)
│   ├── JuniorShares.sol              # ERC20 jLP share token (hook-gated mint/burn)
│   ├── interfaces/
│   │   └── IVolatilityOracle.sol     # Oracle interface; returns max uint256 on failure
│   └── oracles/
│       └── VolatilityOracle.sol      # 1hr cache; TWAP-based vol computation
│
├── test/
│   ├── DualTrancheTestBase.sol       # Abstract base: setUp, helpers, shared state
│   ├── Admin.t.sol                   # 15 tests — approveVault, initPool, updateRange
│   ├── ShareTokens.t.sol             # 21 tests — ERC20 metadata, access control, transfers
│   ├── VolGate.t.sol                 # 12 tests — gate open/closed, oracle failure, events
│   ├── CapitalRouting.t.sol          # 11 tests — vault deposit, recall, yield split
│   ├── FeeDistribution.t.sol         # 7 tests  — 30/70 split, pro-rata claims
│   ├── Integration.t.sol             # 8 tests  — full lifecycle scenarios
│   ├── BoundaryConditions.t.sol      # 38 tests — edge cases, direct-callback security
│   ├── FuzzTests.t.sol               # 23 tests — 256-run fuzz over randomised inputs
│   └── mocks/
│       ├── MockERC20.sol             # Mintable/burnable ERC20
│       ├── MockERC4626Vault.sol      # Full ERC4626 with simulateYield()
│       └── MockVolatilityOracle.sol  # Configurable vol + failure mode
│
└── script/
    └── Deploy.s.sol                  # DeployOracle / DeployHook / InitPool scripts
```

---

## Data Flow

### Senior LP Deposit (always open)

```
Senior LP → modifyLiquidity(+delta, hookData: abi.encode(true, lpAddress))
  │
  ├── beforeAddLiquidity: isSenior=true → skip gate, allow
  └── afterAddLiquidity: mint SeniorShares to lpAddress
```

### Junior LP Deposit (volatility gated)

```
Junior LP → modifyLiquidity(+delta, hookData: abi.encode(false, lpAddress))
  │
  └── beforeAddLiquidity: isSenior=false
            │
            ├── vol = 35% < 50% threshold → ALLOW → mint JuniorShares
            │
            └── vol = 80% > 50% threshold → REVERT JuniorGateClosed(8000, 5000)
```

### Swap (fee split + capital routing)

```
Swap → afterSwap fires
  │
  ├── totalFee = abs(inputDelta) * key.fee / 1_000_000
  ├── 30% → seniorFeePool
  ├── 70% → juniorFeePool
  │
  └── _checkAndRouteCapital()
            │
            ├── tick inside seniorRange + capitalInVault → RECALL
            │         ├── vault.redeem(vaultShares)
            │         ├── yield → 90% seniorYieldPool / 10% juniorBoostPool
            │         └── emit CapitalRecalledFromVault
            │
            └── tick outside seniorRange + !capitalInVault → ROUTE
                      ├── vault.deposit(idleAmount)
                      └── emit CapitalRoutedToVault
```

### Senior LP Withdrawal

```
Senior LP → modifyLiquidity(-delta, hookData: abi.encode(true, lpAddress))
  │
  ├── beforeRemoveLiquidity: capitalInVault=true → _recallCapitalFromVault()
  └── afterRemoveLiquidity: burn SeniorShares from lpAddress
```

### Yield Claim

```
Senior LP → claimSeniorYield(key)
  └── total = (seniorFeePool  * balance / totalSupply)
            + (vaultYieldPool * balance / totalSupply)

Junior LP → claimJuniorYield(key)
  └── total = (juniorFeePool   * balance / totalSupply)
            + (juniorBoostPool * balance / totalSupply)
```

---

## Security Model

| Risk | Mitigation |
|---|---|
| Capital routing during multi-block attack | TWAP-based range detection (not spot tick); 1-block lag is acceptable |
| Junior vol gate bypassed by rapid deposit | Gate runs in `beforeAddLiquidity` — atomically in same tx as deposit; no bypass possible |
| Vault exploit drains Senior capital | Vault whitelist (`approvedVaults` mapping); only owner can approve vaults |
| Senior recall fails during high gas | `beforeRemoveLiquidity` recall is mandatory; if vault reverts, withdrawal reverts too — funds stay safe |
| Fee accounting rounding errors | `uint256` accumulator with `1e18` precision; dust loss is acceptable |
| Junior shares minted despite gate bypass | Gate in `beforeAddLiquidity`, mint in `afterAddLiquidity` — same atomic transaction, gate always runs first |
| Micro-routing wastes gas | `MIN_ROUTING_AMOUNT = 1e6` guard prevents routing dust amounts |
| Oracle down blocks operations | Oracle failure only affects Junior deposits; swaps and withdrawals are never blocked |
| Direct callback attacks | All hook entry-points guarded by `onlyPoolManager` modifier |
| Unauthorized admin calls | `onlyOwner` modifier on `approveVault`, `updateSeniorRange`, `initPool` |

---

## Getting Started

### Prerequisites

```bash
node >= 18
foundry (forge, anvil, cast)
```

### Installation

```bash
git clone <repo>
cd DualTranche
forge install
forge build
```

### Dependencies

| Package | Purpose |
|---|---|
| `Uniswap/v4-core` | Pool manager, hook interfaces, types |
| `Uniswap/v4-periphery` | `ImmutableState`, `PoolModifyLiquidityTest` |
| `OpenZeppelin/openzeppelin-contracts` | ERC20, ERC4626, IERC20 |
| `foundry-rs/forge-std` | Testing utilities, `vm` cheatcodes |

### Remappings (foundry.toml)

```
v4-core/=lib/v4-core/src/
v4-periphery/=lib/v4-periphery/src/
openzeppelin/=lib/openzeppelin-contracts/contracts/
forge-std/=lib/forge-std/src/
```

---

## Running Tests

```bash
# Run all 135 tests
forge test

# Run with verbose output
forge test -vvv

# Run a specific test suite
forge test --match-contract VolGateTest -vvv
forge test --match-contract CapitalRoutingTest -vvv
forge test --match-contract FuzzTests -vvv

# Run a single test
forge test --match-test test_JuniorGate_BlocksDeposit_HighVol -vvv

# Run fuzz tests with more runs
forge test --match-contract FuzzTests --fuzz-runs 1000
```

### Test Suite Summary

| Suite | Tests | What it covers |
|---|---|---|
| `AdminTest` | 15 | `approveVault`, `initPool`, `updateSeniorRange`, hook flag address bits |
| `ShareTokensTest` | 21 | ERC20 metadata, `NotHook` access control, transfer, `transferFrom`, total supply |
| `VolGateTest` | 12 | Gate open/closed at exact threshold, oracle failure → gate closed, events |
| `CapitalRoutingTest` | 11 | Vault deposit on range exit, recall on return, 90/10 yield split |
| `FeeDistributionTest` | 7 | 30/70 fee split, pro-rata claim, double-claim returns zero |
| `IntegrationTest` | 8 | Full lifecycle: deposit → swap → out-of-range → vault → recall → claim |
| `BoundaryConditionsTest` | 38 | Threshold exactness, direct-callback security, MIN_ROUTING_AMOUNT guard |
| `FuzzTests` | 23 | 256-run randomised inputs: gate, shares, supply invariant, fee bounds, pro-rata yield |
| **Total** | **135** | |

---

## Deployment

### 1. Deploy the Volatility Oracle

```bash
forge script script/Deploy.s.sol:DeployOracle \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PK \
  --broadcast --verify
```

### 2. Deploy the Hook (with address mining)

The hook must be deployed at an address whose lower bits encode the required permission flags (`0x1F40`). The deploy script handles mining via `HookMiner`.

```bash
forge script script/Deploy.s.sol:DeployHook \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PK \
  --broadcast --verify
```

### 3. Approve Vault

```bash
cast send $HOOK_ADDRESS \
  "approveVault(address)" $AAVE_USDC_VAULT \
  --private-key $PK \
  --rpc-url $SEPOLIA_RPC
```

### 4. Initialize Pool

```bash
# initData: abi.encode(vaultAddress, juniorVolThreshold)
# juniorVolThreshold = 5000 bps = 50% annualized vol
forge script script/Deploy.s.sol:InitPool \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PK \
  --broadcast
```

### Environment Variables

```bash
SEPOLIA_RPC=https://...
PK=0x...
HOOK_ADDRESS=0x...
ORACLE_ADDRESS=0x...
AAVE_USDC_VAULT=0x...
ETHERSCAN_API_KEY=...
```

---

## Demo Narrative

> **"What if your LP position never had idle capital? Not a single token sitting unused, whether the price is in range or out of range. That's DualTranche Vault."**

### The Two Problems You Solve

**Problem 1 — Idle capital**: "Senior LPs never earn zero. When price leaves their range, their capital automatically moves to Aave and keeps compounding at lending APY. The same tx that moves the price routes the capital."

**Problem 2 — Bad entry timing**: "Junior LPs never enter at the wrong time. The volatility gate is a hard stop that only opens when 24hr realized vol is below the configured threshold — entering during calm periods means statistically less IL on day one."

### Demo Sequence

| Step | Action | What to show |
|---|---|---|
| 1 | Senior LP deposits | No gate — immediate confirmation, sLP tokens minted |
| 2 | Junior LP deposits (high vol) | Clean `JuniorGateClosed` revert with current vol and threshold |
| 3 | Junior LP deposits (low vol) | Succeeds — jLP tokens minted, gate event emitted |
| 4 | 20 swaps in-range | Fee pool grows; 30/70 split visible on-chain |
| 5 | Large swap exits Senior range | Capital auto-routed to vault in same tx |
| 6 | Time skip | Vault balance grows — Senior earns lending APY during this window |
| 7 | Swap returns price to range | Capital recalled, vault yield split 90/10 between Senior/Junior |
| 8 | Both LPs claim | Senior: fee share + vault yield; Junior: fee share + boost |

**Closing**: "Two tranche types. One volatility signal. Zero idle capital. DualTranche turns Uniswap v4 into a yield account for passive LPs and a high-conviction venue for active ones."

---

## Key Design Decisions

### `hookData` carries LP address explicitly

In Uniswap v4, the `sender` parameter in hook callbacks is the *router* (`msg.sender` of `modifyLiquidity`), not the actual LP. DualTranche encodes the LP address explicitly in `hookData`:

```solidity
bytes memory hookData = abi.encode(bool isSenior, address lp);
```

Shares are minted/burned to `lp`, not `sender`.

### Reward-per-share accounting

Fee pools use Synthetix-style reward-per-share with per-address debt. This means yield accrues correctly even when shares are transferred between wallets mid-epoch — the recipient starts accruing from the point they receive shares.

### Oracle failure defaults gate to CLOSED

`_safeGetVol()` wraps the oracle call in a try/catch. On failure, it returns `type(uint256).max`, which is always `>= juniorVolThreshold`, blocking all Junior deposits until the oracle recovers. Swaps and Senior deposits are unaffected.

### Hook deployed via `vm.etch` in tests

Tests deploy the hook at the flag address using Foundry's `vm.etch`, which copies bytecode (including baked-in immutables) to an address that satisfies the flag bit constraint — without needing an actual salt miner in tests:

```solidity
DualTrancheVaultHook impl = new DualTrancheVaultHook(manager, oracle);
vm.etch(address(FLAGS), address(impl).code);
hook = DualTrancheVaultHook(address(FLAGS));
```

---

## License

MIT — see [LICENSE](LICENSE)

---

*Built for UHI9 Hookathon | Uniswap Hook Incubator Cohort 9 | May 25, 2026*
