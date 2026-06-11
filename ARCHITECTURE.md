# DualTranche Vault Hook — Architecture

> Deep-dive technical reference for contributors, auditors, and integrators.

---

## System Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Uniswap v4 Pool                             │
│                                                                     │
│  PoolManager                                                        │
│  ├── initialize(key, sqrtPrice)  ──────► afterInitialize            │
│  ├── modifyLiquidity(+delta)     ──────► beforeAddLiquidity         │
│  │                               ──────► afterAddLiquidity          │
│  ├── modifyLiquidity(-delta)     ──────► beforeRemoveLiquidity      │
│  │                               ──────► afterRemoveLiquidity       │
│  └── swap(params)                ──────► afterSwap                  │
│                                                                     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ IHooks callbacks
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                   DualTrancheVaultHook                              │
│                                                                     │
│  Storage:                                                           │
│  ├── poolStates[PoolId]          → PoolState                        │
│  ├── trancheAccounting[PoolId]   → TrancheAccounting                │
│  ├── seniorShareTokens[PoolId]   → SeniorShares (ERC20)             │
│  ├── juniorShareTokens[PoolId]   → JuniorShares (ERC20)             │
│  └── approvedVaults[address]     → bool                             │
│                                                                     │
│  External interfaces:                                               │
│  ├── IVolatilityOracle           → VolatilityOracle                 │
│  └── IERC4626                    → whitelisted lending vault        │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Hook Lifecycle

### Pool Initialization

```
Owner: poolManager.initialize(key, sqrtPrice)
         │
         └── hook.afterInitialize(...)
                 └── (no-op; share tokens deployed by initPool)

Owner: hook.initPool(key, vault, threshold, tickLower, tickUpper)
         ├── require approvedVaults[vault]
         ├── require seniorShareTokens[id] == address(0)   // idempotency guard
         ├── deploy SeniorShares("Senior-<sym>", "sLP-<sym>")
         ├── deploy JuniorShares("Junior-<sym>", "jLP-<sym>")
         └── write PoolState{vault, threshold, seniorRange, juniorGateOpen=true}
```

### Senior LP Deposit

```
LP: poolManager.modifyLiquidity(key, {+delta}, abi.encode(true, lpAddress))
      │
      ├── beforeAddLiquidity(sender, key, params, hookData)
      │       ├── decode(hookData) → (isSenior=true, lp)
      │       └── isSenior: skip gate → return selector
      │
      └── afterAddLiquidity(sender, key, params, delta, fees, hookData)
              ├── decode(hookData) → (isSenior=true, lp)
              ├── amount = uint256(delta.amount0() > 0 ? ... abs())
              ├── sToken.mint(lp, amount)
              └── _updateSeniorDebt(id, lp)    // reset reward debt to current RPS
```

### Junior LP Deposit (vol-gated)

```
LP: poolManager.modifyLiquidity(key, {+delta}, abi.encode(false, lpAddress))
      │
      ├── beforeAddLiquidity(sender, key, params, hookData)
      │       ├── decode(hookData) → (isSenior=false, lp)
      │       ├── vol = _safeGetVol(key)
      │       │       └── try oracle.getAnnualizedVol(...) catch → type(uint256).max
      │       ├── gateOpen = (vol < poolStates[id].juniorVolThreshold)
      │       ├── if !gateOpen: revert JuniorGateClosed(vol, threshold)
      │       └── emit gate state change if changed
      │
      └── afterAddLiquidity(...)
              ├── decode(hookData) → (isSenior=false, lp)
              ├── jToken.mint(lp, amount)
              └── _updateJuniorDebt(id, lp)
```

### Swap

```
Swapper: poolManager.swap(key, params, hookData)
           │
           └── afterSwap(sender, key, params, delta, hookData)
                   ├── fee = _estimateFee(params, delta, key.fee)
                   ├── seniorFeePool += fee * SENIOR_FEE_SHARE_BPS / BPS    // 30%
                   ├── juniorFeePool += fee * JUNIOR_FEE_SHARE_BPS / BPS    // 70%
                   ├── _updateSeniorRPS(id)   // seniorRewardPerShare += fee30 * PRECISION / totalSeniorSupply
                   ├── _updateJuniorRPS(id)
                   └── _checkAndRouteCapital(key)
                           ├── currentTick = poolManager.getSlot0(id).tick
                           ├── inRange = (tickLower <= currentTick < tickUpper)
                           │
                           ├── [out of range + not in vault] → _routeCapitalToVault()
                           │       ├── idle = token0.balanceOf(hook)
                           │       ├── if idle < MIN_ROUTING_AMOUNT: return
                           │       ├── token0.approve(vault, idle)
                           │       ├── shares = vault.deposit(idle, hook)
                           │       ├── state.capitalInVault = true
                           │       ├── state.vaultShares0 = shares
                           │       ├── state.depositedAmount0 = idle
                           │       └── emit CapitalRoutedToVault
                           │
                           └── [in range + in vault] → _recallCapitalFromVault()
                                   ├── redeemed = vault.redeem(shares, hook, hook)
                                   ├── yield = redeemed - depositedAmount0
                                   ├── vaultYieldPool  += yield * 90 / 100
                                   ├── juniorBoostPool += yield * 10 / 100
                                   ├── _updateSeniorRPS, _updateJuniorRPS (yield contribution)
                                   ├── state.capitalInVault = false
                                   └── emit CapitalRecalledFromVault
```

### Withdrawal

```
LP: poolManager.modifyLiquidity(key, {-delta}, abi.encode(isSenior, lpAddress))
      │
      ├── beforeRemoveLiquidity(sender, key, params, hookData)
      │       ├── decode(hookData) → (isSenior, lp)
      │       └── if isSenior && capitalInVault:
      │               _recallCapitalFromVault()   // MANDATORY recall before burn
      │
      └── afterRemoveLiquidity(sender, key, params, delta, fees, hookData)
              ├── decode(hookData) → (isSenior, lp)
              ├── isSenior: sToken.burn(lp, amount)
              └── !isSenior: jToken.burn(lp, amount)
```

---

## Contract Inventory

| File | Purpose | Lines |
|---|---|---|
| [src/DualTrancheVaultHook.sol](src/DualTrancheVaultHook.sol) | Main hook — all logic | ~680 |
| [src/SeniorShares.sol](src/SeniorShares.sol) | Senior ERC20 tranche token | 29 |
| [src/JuniorShares.sol](src/JuniorShares.sol) | Junior ERC20 tranche token | 29 |
| [src/interfaces/IVolatilityOracle.sol](src/interfaces/IVolatilityOracle.sol) | Oracle interface | 12 |
| [src/oracles/VolatilityOracle.sol](src/oracles/VolatilityOracle.sol) | 1hr cached vol oracle | 64 |
| [test/DualTrancheTestBase.sol](test/DualTrancheTestBase.sol) | Abstract test scaffold | ~210 |
| [test/mocks/MockERC20.sol](test/mocks/MockERC20.sol) | Mintable/burnable ERC20 | ~30 |
| [test/mocks/MockERC4626Vault.sol](test/mocks/MockERC4626Vault.sol) | ERC4626 with yield sim | ~50 |
| [test/mocks/MockVolatilityOracle.sol](test/mocks/MockVolatilityOracle.sol) | Configurable oracle | ~25 |
| [script/Deploy.s.sol](script/Deploy.s.sol) | 5-step deploy scripts | ~200 |

---

## Storage Layout

### `PoolState` (per pool)

```solidity
struct PoolState {
    bool     capitalInVault;      // true when Senior capital is deployed in vault
    uint256  vaultShares0;        // ERC4626 shares held (token0-denominated vault)
    uint256  depositedAmount0;    // principal deposited; used to compute yieldEarned
    uint256  depositedAmount1;    // reserved (currently unused)
    int24    seniorTickLower;     // lower tick of Senior LP range
    int24    seniorTickUpper;     // upper tick of Senior LP range
    uint256  juniorVolThreshold;  // gate closes when vol (bps) >= this
    bool     juniorGateOpen;      // cached gate state (updated on each deposit)
    address  vault;               // whitelisted ERC4626 vault address
}
```

### `TrancheAccounting` (per pool)

```solidity
struct TrancheAccounting {
    uint256  seniorFeePool;           // cumulative 30% fee share (token0 units)
    uint256  juniorFeePool;           // cumulative 70% fee share
    uint256  vaultYieldPool;          // 90% of vault yield → Seniors
    uint256  juniorBoostPool;         // 10% of vault yield → Juniors
    uint256  seniorRewardPerShare;    // RPS index scaled by 1e18
    uint256  juniorRewardPerShare;    // RPS index scaled by 1e18
    mapping(address => uint256) seniorDebt;   // per-LP debt checkpoint
    mapping(address => uint256) juniorDebt;
}
```

### Top-level mappings

```solidity
mapping(PoolId => PoolState)          public poolStates;
mapping(PoolId => TrancheAccounting)  public trancheAccounting;   // contains nested mappings
mapping(PoolId => SeniorShares)       public seniorShareTokens;
mapping(PoolId => JuniorShares)       public juniorShareTokens;
mapping(address => bool)              public approvedVaults;

address public immutable owner;
IVolatilityOracle public immutable volOracle;
```

---

## Accounting Model

DualTranche uses **Synthetix-style reward-per-share (RPS)** accounting. This is O(1) per claim and correct across any distribution of entry/exit times.

### Accumulation

Each time the fee pool grows by `Δfee`, the global index advances:

```
seniorRewardPerShare += (Δfee × PRECISION) / seniorTotalSupply
```

`PRECISION = 1e18`. This index is a monotonically increasing counter that represents "how many reward tokens every share has earned, ever, since genesis."

### Per-LP debt checkpoint

When an LP mints or transfers shares, their **debt** is set to:

```
debt[lp] = RPS × balance[lp] / PRECISION
```

This records "how much of the accumulated RPS has this LP already been credited for."

### Pending yield formula

```
pending[lp] = (balance[lp] × RPS / PRECISION) - debt[lp]
```

Because `debt` is set at the point of minting/transfer, the LP only sees yield that accrued **after** they obtained their shares — regardless of when other LPs entered or exited.

### Claim

```solidity
function claimSeniorYield(PoolKey calldata key) external {
    uint256 pending = pendingSeniorYield(key, msg.sender);
    accounting.seniorDebt[msg.sender] =
        sToken.balanceOf(msg.sender) * accounting.seniorRewardPerShare / PRECISION;
    token0.transfer(msg.sender, pending);
}
```

Claiming resets the debt to the current RPS × balance, so the next `pending` query starts from zero.

### Why RPS works for transfers

When shares are transferred from A → B:
- A's debt stays at the pre-transfer value → `pendingA = 0` (they claimed nothing but their balance went to zero)
- B's debt is updated at mint/transfer time → B only earns yield from the moment they receive shares

This is correct: A earned whatever yield existed up to the transfer point; B earns from that point onward.

> **Note**: The current implementation does not auto-settle pending yield on transfer (unlike some staking contracts). An LP who transfers shares without first claiming loses any pending yield to that point. This is a known trade-off — adding settle-on-transfer would require the ERC20 to call back into the hook, introducing reentrancy risk.

---

## Volatility Gate Internals

### Oracle call path

```solidity
function _safeGetVol(PoolKey calldata key) internal returns (uint256) {
    try volOracle.getAnnualizedVol(key.currency0, key.currency1)
        returns (uint256 vol) {
        return vol;
    } catch {
        return type(uint256).max; // conservative: any vol >= any threshold → gate closed
    }
}
```

### Gate evaluation

```
gateOpen = (_safeGetVol(key) < poolStates[id].juniorVolThreshold)
```

The gate is evaluated fresh on every `beforeAddLiquidity` call — there is no cached gate state used for entry decisions. The `juniorGateOpen` field in `PoolState` is only updated for event emission purposes.

### Oracle caching

`VolatilityOracle` caches results for `CACHE_TTL = 1 hours` per currency pair. Within a 1-hour window, all gate checks return the same vol reading. This is intentional — computing vol on every deposit would make the hook prohibitively expensive.

### TWAP placeholder

The current oracle returns `DEFAULT_VOL_BPS = 3000` (30%) as a stub. A production implementation replaces `_computeVolFromTWAP` with:

1. `poolManager.observe([86400, 82800, ..., 3600, 0])` — 24 tick cumulative samples at hourly intervals
2. Hourly log-returns: `r_i = (tickCumulative_i - tickCumulative_{i-1}) / 3600 × ln(1.0001)`
3. `variance = E[r²] - E[r]²`
4. `annualizedVol = sqrt(variance × 8760)` expressed in bps

This is a standard realized-volatility estimator (close-to-close, hourly sampling).

---

## Capital Routing Internals

### Trigger condition

Capital routing is checked in `afterSwap` via `_checkAndRouteCapital`. The trigger is based on the **post-swap tick**:

```
currentTick = poolManager.getSlot0(poolId).tick
inRange     = (seniorTickLower <= currentTick) && (currentTick < seniorTickUpper)
```

- `inRange = false` and `!capitalInVault` → route to vault
- `inRange = true` and `capitalInVault` → recall from vault

### `_routeCapitalToVault`

```solidity
function _routeCapitalToVault(PoolId id, PoolState storage state, IERC20 token0) internal {
    uint256 idle = token0.balanceOf(address(this));
    if (idle < MIN_ROUTING_AMOUNT) revert NoCapitalToRoute();

    token0.approve(address(state.vault), idle);
    uint256 shares = IERC4626(state.vault).deposit(idle, address(this));

    state.capitalInVault    = true;
    state.vaultShares0      = shares;
    state.depositedAmount0  = idle;

    emit CapitalRoutedToVault(id, idle, 0);
}
```

`MIN_ROUTING_AMOUNT = 1e6` prevents routing dust amounts (6-decimal USDC granularity).

### `_recallCapitalFromVault`

```solidity
function _recallCapitalFromVault(PoolId id, PoolState storage state, TrancheAccounting storage accounting) internal {
    uint256 redeemed = IERC4626(state.vault).redeem(
        state.vaultShares0,
        address(this),   // receiver
        address(this)    // owner of shares
    );

    uint256 yield = redeemed > state.depositedAmount0 ? redeemed - state.depositedAmount0 : 0;

    accounting.vaultYieldPool  += yield * 90 / 100;
    accounting.juniorBoostPool += yield * 10 / 100;

    // Update RPS indices with new yield
    _updateSeniorRPS(id, yield * 90 / 100);
    _updateJuniorRPS(id, yield * 10 / 100);

    state.capitalInVault   = false;
    state.vaultShares0     = 0;
    state.depositedAmount0 = 0;

    emit CapitalRecalledFromVault(id, redeemed, 0, yield);
}
```

### Forced recall on withdrawal

`beforeRemoveLiquidity` forces a recall if `capitalInVault = true` and the LP is Senior. This ensures Senior LPs can always withdraw their principal — the hook never traps capital in the vault:

```solidity
function beforeRemoveLiquidity(...) external onlyPoolManager returns (bytes4) {
    (bool isSenior,) = abi.decode(hookData, (bool, address));
    PoolId id = key.toId();
    if (isSenior && poolStates[id].capitalInVault) {
        _recallCapitalFromVault(id, poolStates[id], trancheAccounting[id]);
    }
    return IHooks.beforeRemoveLiquidity.selector;
}
```

---

## Fee Estimation

Uniswap v4 does not expose the exact LP fee earned per swap directly in the `afterSwap` callback. DualTranche estimates it from the swap parameters:

```solidity
function _estimateFee(
    IPoolManager.SwapParams calldata params,
    BalanceDelta delta,
    uint24 feePpm
) internal pure returns (uint256) {
    int128 inputAmount;
    if (params.zeroForOne) {
        inputAmount = delta.amount0();   // negative (LP receives token0)
    } else {
        inputAmount = delta.amount1();   // negative (LP receives token1)
    }
    uint256 absInput = inputAmount < 0 ? uint256(-int256(inputAmount)) : uint256(int256(inputAmount));
    return absInput * feePpm / 1_000_000;
}
```

**Limitations of this approach**:
- `absInput` is the post-fee amount; the true fee is `input × fee / (1 - fee)`. This slightly underestimates fees at high fee tiers (e.g. 1% tier: error is ~1%).
- Fees are denominated in the input currency. If the swap is `token1 → token0`, the fee estimate is in `token1`, but the fee pool tracks `token0`. A production system should apply a price conversion.
- For 0.3% fee, the error is ~0.3% of the fee amount — negligible for most LP strategies.

---

## Share Token Design

`SeniorShares` and `JuniorShares` are minimal ERC20 wrappers with a single constraint: only the hook can mint or burn.

```solidity
contract SeniorShares is ERC20 {
    address public immutable hook;

    error NotHook();
    modifier onlyHook() { if (msg.sender != hook) revert NotHook(); _; }

    function mint(address to, uint256 amount) external onlyHook { _mint(to, amount); }
    function burn(address from, uint256 amount) external onlyHook { _burn(from, amount); }
}
```

Shares are otherwise fully transferable ERC20 tokens. This means:
- LPs can trade their position on secondary markets
- Reward accounting follows shares via `seniorDebt`/`juniorDebt`
- The hook name and symbol encode the pool: `sLP-<token0hex>-<token1hex>`

### hookData encoding

Uniswap v4 hook callbacks receive `sender` = the address that called `modifyLiquidity` on the PoolManager (i.e. the router). The actual LP is encoded in `hookData`:

```solidity
// LP passes when calling modifyLiquidity:
bytes memory hookData = abi.encode(bool isSenior, address lp);
```

The hook decodes `lp` to determine where to mint/burn shares. Using `sender` would mint shares to the router, not the LP.

---

## Hook Address Constraint

Uniswap v4 identifies which hook callbacks are enabled by inspecting specific bits of the hook's **deployment address**. The 14 least significant bits of the address are a bitmap of enabled hooks.

DualTranche requires these flags (`0x1F40`):

| Flag | Bit | Value |
|---|---|---|
| `AFTER_INITIALIZE_FLAG` | 13 | `0x2000` |
| `BEFORE_ADD_LIQUIDITY_FLAG` | 11 | `0x0800` |
| `AFTER_ADD_LIQUIDITY_FLAG` | 10 | `0x0400` |
| `BEFORE_REMOVE_LIQUIDITY_FLAG` | 9 | `0x0200` |
| `AFTER_REMOVE_LIQUIDITY_FLAG` | 8 | `0x0100` |
| `AFTER_SWAP_FLAG` | 6 | `0x0040` |
| **Total** | | `0x1F40` |

```
Binary: 0001 1111 0100 0000
         ↑↑↑↑ ↑↑↑↑
         |||| ||||
         |||| |||└── AFTER_DONATE (0)
         |||| ||└─── BEFORE_DONATE (0)
         |||| |└──── AFTER_SWAP (1)          ✓
         |||| └───── BEFORE_SWAP (0)
         |||└──────── AFTER_REMOVE_LIQ (1)   ✓
         ||└───────── BEFORE_REMOVE_LIQ (1)  ✓
         |└────────── AFTER_ADD_LIQ (1)      ✓
         └─────────── BEFORE_ADD_LIQ (1)     ✓
         (bit 13)     AFTER_INITIALIZE (1)   ✓
```

**Mining**: `HookMiner.find(deployer, FLAGS, creationCode, constructorArgs)` iterates over CREATE2 salts until it finds one that produces an address whose lower 14 bits equal `FLAGS`. The salt is then used in `new DualTrancheVaultHook{salt: salt}(...)`.

**In tests**: `vm.etch(address(FLAGS), address(impl).code)` copies bytecode directly to the flag address, avoiding the need for a mining loop. Immutables baked into the constructor are preserved.

---

## External Dependencies

| Dependency | Interface | Usage |
|---|---|---|
| Uniswap v4 `PoolManager` | `IPoolManager` | Swap and liquidity callbacks; `getSlot0` for tick reads |
| Uniswap v4 `ImmutableState` | `ImmutableState` (v4-periphery) | `poolManager` storage + `onlyPoolManager` modifier |
| OpenZeppelin `ERC20` | `IERC20` | Tranche share tokens |
| OpenZeppelin `ERC4626` | `IERC4626` | Capital routing to lending vaults |
| `IVolatilityOracle` (custom) | — | Annualized vol in bps, with 1hr cache |

### v4-periphery `ImmutableState`

The hook inherits `ImmutableState` from `v4-periphery` which provides:
- `IPoolManager public immutable poolManager` storage slot
- `modifier onlyPoolManager()` that reverts with `NotPoolManager` if `msg.sender != address(poolManager)`

All six hook callbacks are guarded by this modifier.

---

## Known Limitations

| Limitation | Impact | Mitigation / Future Work |
|---|---|---|
| Fee denominated in input currency | Fees on `token1→token0` swaps are tracked in `token1` units, not `token0` | Add tick-based price conversion |
| No settle-on-transfer for pending yield | LP who transfers shares loses pending yield | Add yield settlement in `ERC20._beforeTokenTransfer` hook |
| TWAP oracle is a stub | Returns constant 3000 bps; gate never closes in production | Implement `_computeVolFromTWAP` with 24h observation window |
| Capital routing in `afterSwap` | If a large swap instantly exhausts liquidity and moves price, the capital may not be routed until the next swap | Add routing trigger in `rebalance()` external function |
| No multi-range Senior support | One Senior range per pool; if a pool needs multiple price ranges, one hook deployment is needed per range | Extend `PoolState` to support an array of Senior ranges |
| Vault credit risk | Senior capital can be lost if the vault is hacked | Vault whitelist + emergency recall function |

---

## Invariants

These invariants should hold at all times (verified by the test suite):

1. **Supply conservation**: `seniorTotalSupply` only changes via `mint` and `burn` in hook callbacks
2. **Debt never exceeds earned**: `seniorDebt[lp] <= balance[lp] × RPS / PRECISION`
3. **RPS monotonicity**: `seniorRewardPerShare` is non-decreasing
4. **Fee pool monotonicity**: `seniorFeePool + juniorFeePool` is non-decreasing
5. **Capital exclusivity**: `capitalInVault = true` iff `vaultShares0 > 0`
6. **Vault whitelist**: `poolStates[id].vault` is always an approved vault address
7. **Gate default-closed**: When oracle fails, `_safeGetVol` returns `type(uint256).max`, closing the gate
8. **Hook permission bits**: `uint160(address(hook)) & FLAGS == FLAGS` at all times
