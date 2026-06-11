# DualTranche Vault Hook
## Volatility-Gated Tranched Liquidity with Idle Capital Lending

> **UHI9 Hookathon Submission Guide**
> Uniswap Hook Incubator | Cohort 9 | Hookathon: May 25, 2026

---

## Table of Contents

1. [Product Requirements Document (PRD)](#1-product-requirements-document)
2. [Deep Technical Architecture](#2-deep-technical-architecture)
3. [Build Guide](#3-build-guide)

---

# 1. Product Requirements Document

## 1.1 Problem Statement

Concentrated liquidity AMMs have a fundamental idle capital problem: the moment price leaves an LP's range, their capital earns **zero** — no fees, no yield, nothing. On volatile pairs, LPs can spend 40–70% of their time out of range, earning nothing while bearing full price exposure on one side of their position.

Simultaneously, LPs have no systematic protection from entering the pool at the worst possible time — right before a large price move that instantly takes them out of range and crystallizes IL.

These two problems compound:
- Bad entries → IL accumulates immediately → LP exits in frustration
- Out-of-range capital → idle TVL → LPs underperform simple holding

**DualTranche Vault Hook** solves both problems with one coordinated system: a **volatility gate** that prevents bad entries for the risk-seeking tranche, and an **automatic capital router** that sends idle capital to lending protocols the moment it stops earning swap fees.

The result: every dollar in the pool is earning something, at all times.

## 1.2 Tranche Architecture

### Senior Tranche — StableLP

**Who it's for**: LPs who want predictable, low-risk yield. Comparable to a money market account with AMM upside.

**What they get**:
- Always open for deposits (no volatility gate)
- Guaranteed floor fee share when in-range (30% of swap fees)
- When out of range: capital automatically routed to lending vault (Aave/Morpho)
- Earn lending APY on 100% of out-of-range capital — **zero idle time**
- When price returns to range: capital automatically recalled from vault, redeployed as LP

**What they give up**:
- Capped fee share (30% max, not 100%)
- Slower response to sudden large swaps (capital recall has 1-block latency)

### Junior Tranche — ActiveLP

**Who it's for**: LPs who want maximum fee capture and accept higher volatility risk in exchange for better risk-adjusted entry.

**What they get**:
- 70% of swap fees when in-range
- Volatility-gated entry: only depositable when 24hr realized vol is below threshold
- Statistically better entry prices (entering during calm = less immediate IL risk)
- Yield boost funded by Senior/Junior fee spread

**What they give up**:
- Cannot deposit during high-volatility windows
- Full IL exposure (not smoothed)
- No automatic out-of-range yield (their capital sits idle out of range)

## 1.3 The Volatility Gate — Dual Purpose

The volatility gate is the architectural innovation that makes both tranches work:

1. **For Junior LPs**: Acts as a deposit filter — prevents entering at statistically bad times
2. **For Senior LPs**: Acts as a capital routing signal — high volatility = price likely to move = more out-of-range time = more time earning lending APY instead of fees

The gate is a **shared signal** that synchronizes the behavior of both tranches automatically.

## 1.4 Functional Requirements

### FR-1: Senior Tranche Deposits
- Senior tranche open at all times (no vol gate)
- Senior LPs receive `seniorShares` ERC20 tokens representing their pool share
- Senior fee share: 30% of all swap fees earned by the pool
- Senior shares are freely transferable and redeemable

### FR-2: Junior Tranche Deposits
- Junior tranche deposits gated by volatility oracle
- Deposit allowed only when 24hr realized vol < `juniorDepositVolThreshold` (configurable, default: 50% annualized)
- During vol gate closed: Junior deposit transactions revert with `JuniorGateClosed`
- Junior LPs receive `juniorShares` ERC20 tokens
- Junior fee share: 70% of all swap fees earned by the pool

### FR-3: Capital Routing — Out-of-Range Detection
- On every `afterSwap`, hook checks if current price is within the pool's active liquidity range
- If price moves out of range:
  - Hook identifies Senior LP capital that is now idle (no longer earning fees)
  - Hook calls `vault.deposit()` to route idle Senior capital to ERC4626 vault
  - Hook records `capitalInVault` amount and current timestamp
- If price moves back into range:
  - Hook calls `vault.withdraw()` to recall capital from vault
  - Capital is redeployed as LP position
  - Accrued vault yield is credited to Senior LP pool

### FR-4: Out-of-Range Yield Distribution
- All lending vault yield earned by Senior capital is credited to `seniorYieldPool`
- Senior LPs can claim their pro-rata share of `seniorYieldPool` at any time
- This yield is **in addition to** their 30% fee share from in-range periods

### FR-5: Fee Distribution
- On every swap, hook splits fees:
  - 30% to `seniorFeePool` (pro-rata to senior share balances)
  - 70% to `juniorFeePool` (pro-rata to junior share balances)
- Both pools accumulate and are claimable at any time

### FR-6: Junior Yield Boost
- When Senior capital is in vault (out of range), vault yield is partially shared with Juniors
- Junior boost rate: 10% of vault yield redistributed to Junior pool
- Rationale: Juniors absorb more IL risk during volatile periods; vault yield compensates

### FR-7: Volatility Oracle Integration
- 24hr realized volatility computed from Uniswap v4 TWAP price history or Chainlink vol feed
- Threshold for Junior gate: configurable by pool deployer (default 50% annualized)
- Oracle failure fallback: gate defaults to CLOSED (conservative — Junior deposits paused)
- Gate state emits `JuniorGateOpened` and `JuniorGateClosed` events for monitoring

### FR-8: Withdrawal — Both Tranches
- Senior and Junior LPs can withdraw at any time
- Senior withdrawal: if capital is in vault, vault.redeem() is called first to recall capital
- Junior withdrawal: standard LP withdrawal, full IL crystallizes at exit
- Both tranches: shares burned, underlying + yield returned

## 1.5 Non-Functional Requirements

- **No permanently idle capital**: Senior LP capital must be earning something (fees OR lending yield) at all times
- **Gas efficiency**: Capital routing on price range exit must add < 100k gas to swap execution
- **Vault safety**: Only pre-approved ERC4626 vaults; vault changes require 48hr timelock
- **Oracle liveness**: Oracle failure must not prevent swaps or withdrawals; only gates Junior deposits

## 1.6 Success Metrics (Demo Day)

- Show Senior LP earning lending APY during a simulated out-of-range period
- Show Junior LP being blocked during high-volatility entry attempt
- Show Junior LP successfully entering during low-volatility period
- Show fee split: 30% Senior / 70% Junior over a sequence of swaps
- Show combined Senior yield = fee share + vault yield
- Show Junior LP's statistically better IL outcome vs unprotected LP entering during high-vol

---

# 2. Deep Technical Architecture

## 2.1 System Overview

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
  │   (ERC20)            │             │  (ERC20)         │  │  (ERC4626)        │
  │                      │             │                  │  │                  │
  │  - Always depositable│             │  - Vol-gated     │  │  - Aave v3 /     │
  │  - 30% fee share     │             │  - 70% fee share │  │    Morpho Blue   │
  │  - Vault yield       │             │  - Max exposure  │  │  - Earns APY on  │
  │  - Auto-routed idle  │             │  - Entry quality │  │    idle capital  │
  └──────────────────────┘             └──────────────────┘  └───────────────────┘
              │                                       │
              ▼                                       ▼
  ┌──────────────────────┐             ┌──────────────────┐
  │  VolatilityOracle    │             │  FeeDistributor  │
  │                      │             │                  │
  │  - 24hr realized vol │             │  - seniorPool    │
  │  - Regime output     │             │  - juniorPool    │
  │  - Gate signal       │             │  - vaultYield    │
  └──────────────────────┘             └──────────────────┘
```

## 2.2 Main Hook Contract

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IERC4626} from "openzeppelin/interfaces/IERC4626.sol";
import {SeniorShares} from "./SeniorShares.sol";
import {JuniorShares} from "./JuniorShares.sol";
import {FeeDistributor} from "./FeeDistributor.sol";
import {IVolatilityOracle} from "./interfaces/IVolatilityOracle.sol";

contract DualTrancheVaultHook is BaseHook {
    
    using StateLibrary for IPoolManager;
    
    // ── Errors ────────────────────────────────────────────────────────────
    
    error JuniorGateClosed(uint256 currentVol, uint256 threshold);
    error VaultNotApproved(address vault);
    error TrancheNotFound();
    
    // ── Events ────────────────────────────────────────────────────────────
    
    event JuniorGateOpened(bytes32 indexed poolId, uint256 currentVol);
    event JuniorGateClosed(bytes32 indexed poolId, uint256 currentVol);
    event CapitalRoutedToVault(bytes32 indexed poolId, uint256 amount);
    event CapitalRecalledFromVault(bytes32 indexed poolId, uint256 amount, uint256 yieldEarned);
    event FeesDistributed(bytes32 indexed poolId, uint256 seniorAmount, uint256 juniorAmount);
    
    // ── Storage ──────────────────────────────────────────────────────────
    
    struct PoolState {
        bool   capitalInVault;           // Is Senior capital currently in vault?
        uint256 vaultedAmount;           // How much is in vault (token0 terms)
        uint256 vaultShares;             // ERC4626 shares held
        int24  lastKnownTick;            // Last tick we saw capital leave range
        uint256 juniorVolThreshold;      // bps — gate closes above this vol
        bool   juniorGateOpen;           // Current gate state
        address vault;                   // ERC4626 vault for this pool
    }
    
    struct TrancheAccounting {
        uint256 seniorFeePool;           // Accumulated 30% fee share
        uint256 juniorFeePool;           // Accumulated 70% fee share
        uint256 vaultYieldPool;          // Accumulated vault yield for Seniors
        uint256 juniorBoostPool;         // 10% of vault yield for Juniors
    }
    
    // poolId => PoolState
    mapping(bytes32 => PoolState) public poolStates;
    
    // poolId => TrancheAccounting
    mapping(bytes32 => TrancheAccounting) public trancheAccounting;
    
    // poolId => SeniorShares
    mapping(bytes32 => SeniorShares) public seniorShareTokens;
    
    // poolId => JuniorShares
    mapping(bytes32 => JuniorShares) public juniorShareTokens;
    
    // Approved vault whitelist
    mapping(address => bool) public approvedVaults;
    
    IVolatilityOracle public immutable volOracle;
    
    // Fee split constants
    uint256 public constant SENIOR_FEE_SHARE_BPS = 3000;  // 30%
    uint256 public constant JUNIOR_FEE_SHARE_BPS = 7000;  // 70%
    uint256 public constant JUNIOR_VAULT_BOOST_BPS = 1000; // 10% of vault yield
    
    // ── Hook Permissions ──────────────────────────────────────────────────
    
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,             // deploy share tokens
            beforeAddLiquidity: true,          // vol gate for junior
            afterAddLiquidity: true,           // mint share tokens
            beforeRemoveLiquidity: true,       // recall vault capital if needed
            afterRemoveLiquidity: true,        // burn share tokens
            beforeSwap: false,
            afterSwap: true,                   // fee split + range check + capital routing
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
    
    // ── Initialization ────────────────────────────────────────────────────
    
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick,
        bytes calldata initData
    ) external override onlyPoolManager returns (bytes4) {
        
        (address vault, uint256 juniorVolThreshold) = abi.decode(
            initData, (address, uint256)
        );
        
        require(approvedVaults[vault], VaultNotApproved(vault));
        
        bytes32 poolId = key.toId();
        
        // Deploy share tokens
        seniorShareTokens[poolId] = new SeniorShares(
            address(this),
            string(abi.encodePacked("SENIOR-", _poolSymbol(key)))
        );
        
        juniorShareTokens[poolId] = new JuniorShares(
            address(this),
            string(abi.encodePacked("JUNIOR-", _poolSymbol(key)))
        );
        
        // Initialize pool state
        poolStates[poolId] = PoolState({
            capitalInVault: false,
            vaultedAmount: 0,
            vaultShares: 0,
            lastKnownTick: tick,
            juniorVolThreshold: juniorVolThreshold,
            juniorGateOpen: true, // starts open
            vault: vault
        });
        
        return BaseHook.afterInitialize.selector;
    }
    
    // ── Before Add Liquidity — Volatility Gate ────────────────────────────
    
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        
        (bool isSenior) = abi.decode(hookData, (bool));
        
        if (isSenior) {
            // Senior: always allow
            return BaseHook.beforeAddLiquidity.selector;
        }
        
        // Junior: check volatility gate
        bytes32 poolId = key.toId();
        PoolState storage state = poolStates[poolId];
        
        uint256 currentVol = volOracle.getAnnualizedVol(
            key.currency0,
            key.currency1
        );
        
        if (currentVol >= state.juniorVolThreshold) {
            // Update gate state if changed
            if (state.juniorGateOpen) {
                state.juniorGateOpen = false;
                emit JuniorGateClosed(poolId, currentVol);
            }
            revert JuniorGateClosed(currentVol, state.juniorVolThreshold);
        }
        
        // Gate is open
        if (!state.juniorGateOpen) {
            state.juniorGateOpen = true;
            emit JuniorGateOpened(poolId, currentVol);
        }
        
        return BaseHook.beforeAddLiquidity.selector;
    }
    
    // ── After Add Liquidity — Mint Shares ────────────────────────────────
    
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        
        (bool isSenior) = abi.decode(hookData, (bool));
        bytes32 poolId = key.toId();
        
        // Calculate share amount based on liquidity provided
        uint256 shareAmount = uint256(uint128(params.liquidityDelta));
        
        if (isSenior) {
            seniorShareTokens[poolId].mint(sender, shareAmount);
        } else {
            juniorShareTokens[poolId].mint(sender, shareAmount);
        }
        
        return (BaseHook.afterAddLiquidity.selector, delta);
    }
    
    // ── After Swap — Fee Split + Capital Routing ──────────────────────────
    
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        
        bytes32 poolId = key.toId();
        
        // 1. Extract and split fees
        uint256 totalFee = _extractFeeAmount(delta, key);
        if (totalFee > 0) {
            uint256 seniorFee = (totalFee * SENIOR_FEE_SHARE_BPS) / 10000;
            uint256 juniorFee = totalFee - seniorFee;
            
            trancheAccounting[poolId].seniorFeePool += seniorFee;
            trancheAccounting[poolId].juniorFeePool += juniorFee;
            
            emit FeesDistributed(poolId, seniorFee, juniorFee);
        }
        
        // 2. Check if price has moved out of/into range
        _checkAndRouteCapital(key, poolId);
        
        return (BaseHook.afterSwap.selector, 0);
    }
    
    // ── Capital Routing Logic ─────────────────────────────────────────────
    
    function _checkAndRouteCapital(
        PoolKey calldata key,
        bytes32 poolId
    ) internal {
        PoolState storage state = poolStates[poolId];
        
        // Get current pool tick
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        
        // Determine if Senior LP positions are currently in-range
        // For simplicity: we track a single Senior LP range
        // Full implementation: track ranges per Senior LP position
        bool currentlyInRange = _isSeniorCapitalInRange(currentTick, key);
        
        if (!currentlyInRange && !state.capitalInVault) {
            // Capital just went out of range — route to vault
            _routeCapitalToVault(key, poolId, state);
        } else if (currentlyInRange && state.capitalInVault) {
            // Capital came back in range — recall from vault
            _recallCapitalFromVault(key, poolId, state);
        }
    }
    
    function _routeCapitalToVault(
        PoolKey calldata key,
        bytes32 poolId,
        PoolState storage state
    ) internal {
        // Calculate idle Senior capital amount
        // In production: query PoolManager for out-of-range Senior liquidity value
        uint256 idleAmount = _getIdleSeniorCapital(key, poolId);
        
        if (idleAmount == 0) return;
        
        // Deposit to vault
        address vaultAddr = state.vault;
        IERC20(Currency.unwrap(key.currency0)).approve(vaultAddr, idleAmount);
        uint256 sharesReceived = IERC4626(vaultAddr).deposit(idleAmount, address(this));
        
        // Update state
        state.capitalInVault = true;
        state.vaultedAmount = idleAmount;
        state.vaultShares = sharesReceived;
        
        emit CapitalRoutedToVault(poolId, idleAmount);
    }
    
    function _recallCapitalFromVault(
        PoolKey calldata key,
        bytes32 poolId,
        PoolState storage state
    ) internal {
        // Recall all capital from vault
        uint256 redeemed = IERC4626(state.vault).redeem(
            state.vaultShares,
            address(this),
            address(this)
        );
        
        uint256 yieldEarned = redeemed > state.vaultedAmount
            ? redeemed - state.vaultedAmount
            : 0;
        
        if (yieldEarned > 0) {
            // 90% to Senior yield pool, 10% boost to Junior
            uint256 juniorBoost = (yieldEarned * JUNIOR_VAULT_BOOST_BPS) / 10000;
            uint256 seniorYield = yieldEarned - juniorBoost;
            
            trancheAccounting[poolId].vaultYieldPool += seniorYield;
            trancheAccounting[poolId].juniorBoostPool += juniorBoost;
        }
        
        // Reset state
        state.capitalInVault = false;
        state.vaultedAmount = 0;
        state.vaultShares = 0;
        
        emit CapitalRecalledFromVault(poolId, state.vaultedAmount, yieldEarned);
    }
    
    // ── Before Remove Liquidity — Recall Vault If Needed ──────────────────
    
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        
        bytes32 poolId = key.toId();
        PoolState storage state = poolStates[poolId];
        
        (bool isSenior) = abi.decode(hookData, (bool));
        
        // If Senior LP is withdrawing and capital is in vault, recall first
        if (isSenior && state.capitalInVault) {
            _recallCapitalFromVault(key, poolId, state);
        }
        
        return BaseHook.beforeRemoveLiquidity.selector;
    }
    
    // ── After Remove Liquidity — Burn Shares + Distribute Claims ──────────
    
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        
        (bool isSenior) = abi.decode(hookData, (bool));
        bytes32 poolId = key.toId();
        
        uint256 sharesToBurn = uint256(-params.liquidityDelta);
        
        if (isSenior) {
            seniorShareTokens[poolId].burn(sender, sharesToBurn);
        } else {
            juniorShareTokens[poolId].burn(sender, sharesToBurn);
        }
        
        return (BaseHook.afterRemoveLiquidity.selector, delta);
    }
    
    // ── External: Claim Fees and Yield ───────────────────────────────────
    
    function claimSeniorYield(PoolKey calldata key) external returns (uint256 total) {
        bytes32 poolId = key.toId();
        SeniorShares shares = seniorShareTokens[poolId];
        
        uint256 senderBalance = shares.balanceOf(msg.sender);
        uint256 totalShares = shares.totalSupply();
        
        if (totalShares == 0 || senderBalance == 0) return 0;
        
        TrancheAccounting storage acct = trancheAccounting[poolId];
        
        // Pro-rata fee share
        uint256 feeShare = (acct.seniorFeePool * senderBalance) / totalShares;
        uint256 vaultShare = (acct.vaultYieldPool * senderBalance) / totalShares;
        total = feeShare + vaultShare;
        
        // Deduct claimed amounts
        acct.seniorFeePool   -= feeShare;
        acct.vaultYieldPool  -= vaultShare;
        
        // Transfer
        IERC20(Currency.unwrap(key.currency0)).transfer(msg.sender, total);
    }
    
    function claimJuniorYield(PoolKey calldata key) external returns (uint256 total) {
        bytes32 poolId = key.toId();
        JuniorShares shares = juniorShareTokens[poolId];
        
        uint256 senderBalance = shares.balanceOf(msg.sender);
        uint256 totalShares = shares.totalSupply();
        
        if (totalShares == 0 || senderBalance == 0) return 0;
        
        TrancheAccounting storage acct = trancheAccounting[poolId];
        
        uint256 feeShare = (acct.juniorFeePool * senderBalance) / totalShares;
        uint256 boostShare = (acct.juniorBoostPool * senderBalance) / totalShares;
        total = feeShare + boostShare;
        
        acct.juniorFeePool  -= feeShare;
        acct.juniorBoostPool -= boostShare;
        
        IERC20(Currency.unwrap(key.currency0)).transfer(msg.sender, total);
    }
    
    // ── View Functions ────────────────────────────────────────────────────
    
    function isJuniorGateOpen(PoolKey calldata key) external view returns (bool) {
        bytes32 poolId = key.toId();
        PoolState memory state = poolStates[poolId];
        
        uint256 currentVol = volOracle.getAnnualizedVol(
            key.currency0, key.currency1
        );
        return currentVol < state.juniorVolThreshold;
    }
    
    function getSeniorAPY(PoolKey calldata key) external view returns (uint256 apyBps) {
        // Returns estimated combined APY for Senior tranche
        // = (30% fee APY) + (lending APY * % time out of range)
        // Implementation: use historical fee accumulator + vault.previewRedeem()
    }
    
    // ── Internal Helpers ──────────────────────────────────────────────────
    
    function _isSeniorCapitalInRange(
        int24 currentTick,
        PoolKey calldata key
    ) internal view returns (bool) {
        // Check if current tick is within Senior LP's registered range
        // Full implementation: iterate registered Senior ranges
        // Simplified: use pool's active liquidity check
        return true; // placeholder
    }
    
    function _getIdleSeniorCapital(
        PoolKey calldata key,
        bytes32 poolId
    ) internal view returns (uint256) {
        // Query PoolManager for Senior LP's out-of-range position value
        // Returns token0-denominated idle capital amount
        return 0; // placeholder
    }
    
    // ... additional helpers: _extractFeeAmount, _poolSymbol
}
```

## 2.3 Share Token Contracts

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";

/// @notice Senior LP share token — represents pro-rata Senior tranche ownership
contract SeniorShares is ERC20 {
    address public immutable hook;
    
    modifier onlyHook() { require(msg.sender == hook, "Not hook"); _; }
    
    constructor(address _hook, string memory name) ERC20(name, name) {
        hook = _hook;
    }
    
    function mint(address to, uint256 amount) external onlyHook {
        _mint(to, amount);
    }
    
    function burn(address from, uint256 amount) external onlyHook {
        _burn(from, amount);
    }
}

/// @notice Junior LP share token — vol-gated entry
contract JuniorShares is ERC20 {
    address public immutable hook;
    
    modifier onlyHook() { require(msg.sender == hook, "Not hook"); _; }
    
    constructor(address _hook, string memory name) ERC20(name, name) {
        hook = _hook;
    }
    
    function mint(address to, uint256 amount) external onlyHook {
        _mint(to, amount);
    }
    
    function burn(address from, uint256 amount) external onlyHook {
        _burn(from, amount);
    }
}
```

## 2.4 Full Data Flow Diagram

```
SENIOR LP DEPOSIT (always open):
───────────────────────────────────────────────────────────────────
Senior LP → modifyLiquidity(+delta, hookData: [isSenior=true])
  │
  ├── beforeAddLiquidity: isSenior=true → SKIP gate, allow
  └── afterAddLiquidity: mint SeniorShares to LP

JUNIOR LP DEPOSIT (volatility gated):
───────────────────────────────────────────────────────────────────
Junior LP → modifyLiquidity(+delta, hookData: [isSenior=false])
  │
  └── beforeAddLiquidity: isSenior=false
            │
            ├── volOracle.getAnnualizedVol() = 35% < 50% threshold
            │    └── ALLOW deposit → mint JuniorShares
            │
            └── volOracle.getAnnualizedVol() = 80% > 50% threshold
                 └── REVERT JuniorGateClosed(80%, 50%)

SWAP OCCURS:
───────────────────────────────────────────────────────────────────
Swap → afterSwap fires
  │
  ├── Extract fee from delta
  ├── 30% → seniorFeePool
  ├── 70% → juniorFeePool
  │
  └── _checkAndRouteCapital()
            │
            ├── currentTick = within Senior range?
            │    └── YES + capitalInVault=true → RECALL capital
            │         ├── vault.redeem(shares)
            │         ├── yield earned → 90% seniorYieldPool
            │         └──               10% juniorBoostPool
            │
            └── NO + capitalInVault=false → ROUTE capital
                  ├── vault.deposit(idleAmount)
                  └── record vaultShares

SENIOR LP WITHDRAWAL:
───────────────────────────────────────────────────────────────────
Senior LP → modifyLiquidity(-delta, hookData: [isSenior=true])
  │
  ├── beforeRemoveLiquidity: isSenior=true, capitalInVault=true
  │    └── _recallCapitalFromVault() (safety: ensure capital available)
  │
  └── afterRemoveLiquidity: burn SeniorShares

YIELD CLAIM:
───────────────────────────────────────────────────────────────────
Senior LP → claimSeniorYield()
  │
  └── total = (seniorFeePool * balance/totalSupply)
            + (vaultYieldPool * balance/totalSupply)

Junior LP → claimJuniorYield()
  │
  └── total = (juniorFeePool * balance/totalSupply)
            + (juniorBoostPool * balance/totalSupply)
```

## 2.5 Volatility Oracle Contract

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Computes annualized realized volatility from Uniswap v4 pool observations
contract VolatilityOracle {
    
    // Cache vol readings to avoid recomputing every block
    struct VolCache {
        uint256 annualizedVolBps;
        uint256 lastUpdated;
    }
    
    mapping(bytes32 => VolCache) public volCache;
    uint256 public constant CACHE_TTL = 1 hours;
    uint256 public constant OBSERVATION_WINDOW = 24 hours;
    
    IPoolManager public immutable poolManager;
    
    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }
    
    function getAnnualizedVol(
        Currency currency0,
        Currency currency1
    ) external returns (uint256 annualizedVolBps) {
        bytes32 pairId = keccak256(abi.encodePacked(currency0, currency1));
        VolCache memory cache = volCache[pairId];
        
        // Return cached value if fresh
        if (block.timestamp - cache.lastUpdated < CACHE_TTL) {
            return cache.annualizedVolBps;
        }
        
        // Compute fresh vol from TWAP observations
        annualizedVolBps = _computeVolFromTWAP(currency0, currency1);
        
        // Cache result
        volCache[pairId] = VolCache({
            annualizedVolBps: annualizedVolBps,
            lastUpdated: block.timestamp
        });
    }
    
    function _computeVolFromTWAP(
        Currency currency0,
        Currency currency1
    ) internal view returns (uint256 volBps) {
        // Algorithm:
        // 1. Query pool's observation array for price points over last 24hr
        // 2. Compute log returns between consecutive price observations
        // 3. Calculate variance of log returns
        // 4. Annualize: vol_annual = vol_hourly * sqrt(8760)
        //
        // In production: use Uniswap v4's OracleHook or Chainlink realized vol feed
        // Simplified implementation returns fixed values for demo:
        
        // Real implementation would:
        // (uint32[] memory secondsAgos, int56[] memory tickCumulatives, ...) = 
        //   pool.observe([24 hours, 23 hours, ..., 0]);
        // Compute log(price_t / price_{t-1}) for each hour
        // Return sqrt(sum of squared log returns) * sqrt(8760) in bps
        
        return 3000; // placeholder: 30% annualized vol
    }
}
```

## 2.6 Security Considerations

| Risk | Mitigation |
|---|---|
| Capital routing during multi-block attack | Use TWAP for range detection, not spot tick; 1-block lag is acceptable |
| Junior vol gate bypassed by rapid deposit-before-revert | Gate checks inside beforeAddLiquidity which executes atomically in same tx; no bypass possible |
| Vault exploit drains Senior capital | Vault whitelist with timelock; vault changes require 48hr delay |
| Senior recall fails during high gas | beforeRemoveLiquidity recall is mandatory; if vault reverts, withdrawal reverts too (funds safe) |
| Fee accounting rounding errors | Use uint256 accumulator with 1e18 precision; dust loss acceptable |
| Junior shares minted during gate bypass | Gate check is in beforeAddLiquidity, mint is in afterAddLiquidity; same tx, gate runs first |
| Capital routed when liquidity = 0 | Add `if (idleAmount > MIN_ROUTING_AMOUNT)` guard to avoid micro-routing |

---

# 3. Build Guide

## 3.1 Prerequisites

```bash
node >= 18
foundry (forge, anvil, cast)
```

## 3.2 Repository Setup

```bash
forge init dual-tranche-vault-hook
cd dual-tranche-vault-hook

forge install Uniswap/v4-core
forge install Uniswap/v4-periphery
forge install OpenZeppelin/openzeppelin-contracts
forge install aave/aave-v3-core

cat > remappings.txt << 'EOF'
v4-core/=lib/v4-core/src/
v4-periphery/=lib/v4-periphery/src/
openzeppelin/=lib/openzeppelin-contracts/contracts/
EOF
```

## 3.3 Project File Structure

```
dual-tranche-vault-hook/
├── src/
│   ├── DualTrancheVaultHook.sol      # Main hook contract
│   ├── SeniorShares.sol              # Senior LP share ERC20
│   ├── JuniorShares.sol              # Junior LP share ERC20
│   ├── FeeDistributor.sol            # Fee accounting logic
│   ├── interfaces/
│   │   ├── IVolatilityOracle.sol
│   │   └── ICapitalRouter.sol
│   └── oracles/
│       └── VolatilityOracle.sol
├── test/
│   ├── DualTrancheVaultHook.t.sol    # Main unit tests
│   ├── VolGate.t.sol                 # Volatility gate unit tests
│   ├── CapitalRouting.t.sol          # Vault routing tests
│   ├── FeeDistribution.t.sol         # 30/70 split tests
│   ├── Integration.t.sol             # Full lifecycle tests
│   └── mocks/
│       ├── MockERC4626Vault.sol
│       ├── MockVolatilityOracle.sol
│       └── MockPoolManager.sol
├── script/
│   ├── Deploy.s.sol
│   └── Simulate.s.sol
└── foundry.toml
```

## 3.4 Step-by-Step Build Order

### Step 1: Volatility Oracle + Gate Logic

Build and test the gate in complete isolation before touching the hook.

```solidity
function test_VolGate_BlocksDeposit_HighVol() public {
    // Mock oracle returns 80% annualized vol
    mockOracle.setVol(8000); // 80% in bps
    
    // Attempt Junior deposit — should revert
    vm.expectRevert(
        abi.encodeWithSelector(
            DualTrancheVaultHook.JuniorGateClosed.selector,
            8000, 5000
        )
    );
    hook.beforeAddLiquidity(sender, key, params, abi.encode(false));
}

function test_VolGate_AllowsDeposit_LowVol() public {
    // Mock oracle returns 30% annualized vol
    mockOracle.setVol(3000);
    
    // Junior deposit should succeed
    bytes4 result = hook.beforeAddLiquidity(sender, key, params, abi.encode(false));
    assertEq(result, BaseHook.beforeAddLiquidity.selector);
}

function test_VolGate_SeniorAlwaysAllowed() public {
    // Even extreme vol
    mockOracle.setVol(50000); // 500%
    
    // Senior deposit always succeeds
    bytes4 result = hook.beforeAddLiquidity(sender, key, params, abi.encode(true));
    assertEq(result, BaseHook.beforeAddLiquidity.selector);
}
```

### Step 2: Mock ERC4626 Vault

```solidity
// test/mocks/MockERC4626Vault.sol
contract MockERC4626Vault is ERC4626 {
    // Standard vault with a yield simulation function
    
    function simulateAPY(uint256 annualBps, uint256 secondsElapsed) external {
        uint256 totalAssets_ = totalAssets();
        uint256 yieldAmount = (totalAssets_ * annualBps * secondsElapsed) / (10000 * 365 days);
        MockERC20(asset()).mint(address(this), yieldAmount);
    }
}
```

### Step 3: Capital Routing Tests

```solidity
function test_CapitalRouting_ToVault_OnRangeExit() public {
    // 1. Senior LP deposits into range [tickLower, tickUpper]
    // 2. Simulate swap that moves price out of range
    // 3. afterSwap fires → _checkAndRouteCapital()
    // 4. Assert vault.balanceOf(hook) > 0
    // 5. Assert poolState.capitalInVault == true
}

function test_CapitalRouting_Recall_OnRangeReturn() public {
    // 1. Setup: capital already in vault
    // 2. Simulate swap that moves price back into range
    // 3. Assert vault.balanceOf(hook) == 0
    // 4. Assert vaultYieldPool > 0 (yield accumulated)
    // 5. Assert poolState.capitalInVault == false
}

function test_VaultYield_DistributedCorrectly() public {
    // 1. Route 1000 USDC to vault
    // 2. Simulate 10% APY over 30 days: +8.2 USDC yield
    // 3. Recall capital: hook receives 1008.2 USDC
    // 4. Assert seniorYieldPool = 7.38 USDC (90%)
    // 5. Assert juniorBoostPool = 0.82 USDC (10%)
}
```

### Step 4: Fee Distribution Tests

```solidity
function test_FeeSplit_30_70() public {
    // Simulate swap generating 100 USDC in fees
    // Assert seniorFeePool += 30
    // Assert juniorFeePool += 70
}

function test_ClaimYield_ProRata() public {
    // Alice holds 60% of SeniorShares
    // seniorFeePool = 100
    // Alice claims: assert receives 60
    // Bob holds 40% of SeniorShares
    // Bob claims: assert receives 40
}
```

### Step 5: Full Lifecycle Integration Test

```solidity
function test_FullLifecycle_SeniorEarnsWhileOutOfRange() public {
    // Setup
    address seniorLP = makeAddr("senior");
    address juniorLP = makeAddr("junior");
    
    // Both deposit
    // - Senior: always allowed
    // - Junior: oracle at 30% vol (below threshold)
    
    // 50 swaps within range — both earn fees
    
    // Large swap moves price out of Senior range
    //   → Capital auto-routed to vault
    
    // 10 blocks pass — vault accrues yield
    // Senior is earning lending APY during this period
    
    // Price moves back in range → capital recalled
    
    // Assert: Senior earned fee APY + vault APY
    // Assert: Junior earned fee APY (70% share)
    // Assert: Junior received small boost from vault yield
    
    // High vol spike — Junior gate closes
    // Assert: new Junior deposit reverts
    // Assert: Senior deposit still works
}
```

### Step 6: Hook Address Mining

```bash
# Required flags:
# AFTER_INITIALIZE | BEFORE_ADD_LIQUIDITY | AFTER_ADD_LIQUIDITY
# | BEFORE_REMOVE_LIQUIDITY | AFTER_REMOVE_LIQUIDITY | AFTER_SWAP

uint160 flags = uint160(
    Hooks.AFTER_INITIALIZE_FLAG         |
    Hooks.BEFORE_ADD_LIQUIDITY_FLAG     |
    Hooks.AFTER_ADD_LIQUIDITY_FLAG      |
    Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG  |
    Hooks.AFTER_REMOVE_LIQUIDITY_FLAG   |
    Hooks.AFTER_SWAP_FLAG
);
```

### Step 7: Demo Simulation Script

```solidity
// script/Simulate.s.sol

// Scene 1: Setup
//   - Deploy hook, pool, mock vault (5% APY), mock oracle
//   - Senior LP: Alice deposits 10 ETH / 20k USDC
//   - Junior LP: Bob deposits (oracle at 25% vol, gate OPEN)

// Scene 2: Normal operation (price in range)
//   - 20 swaps → fees accumulate
//   - Show: Alice gets 30%, Bob gets 70%

// Scene 3: Price moves out of range
//   - Large swap pushes price beyond Alice's range
//   - Show: Capital auto-routed to Aave vault
//   - Show: Alice's balance ticking up from vault APY

// Scene 4: Junior gate closes
//   - Oracle updates to 75% vol (above 50% threshold)
//   - Carol attempts Junior deposit → REVERT
//   - Alice (Senior) deposits successfully

// Scene 5: Price returns to range
//   - Capital recalled from vault
//   - Show: yield earned added to Alice's claimable balance

// Scene 6: Claim comparison
//   - Alice claims: fee share + vault yield
//   - Bob claims: fee share + junior boost
//   - Show: Alice's combined APY vs simple LP
```

## 3.5 Testing Checklist

```
□ Junior gate blocks deposit above threshold
□ Junior gate allows deposit below threshold
□ Senior deposit always succeeds regardless of vol
□ Gate emits JuniorGateClosed / JuniorGateOpened events
□ afterSwap splits fees exactly 30% Senior / 70% Junior
□ Capital routed to vault when price exits Senior range
□ Capital recalled from vault when price returns to range
□ Vault yield split: 90% senior, 10% junior boost
□ claimSeniorYield returns correct pro-rata amount
□ claimJuniorYield returns correct pro-rata amount + boost
□ SeniorShares minted on Senior deposit
□ JuniorShares minted on Junior deposit (when gate open)
□ Shares burned on withdrawal
□ beforeRemoveLiquidity recalls capital from vault if needed
□ Oracle failure fallback: gate defaults to CLOSED
□ Small routing amount guard (no micro-routing)
```

## 3.6 Deployment Checklist

```bash
# 1. Deploy VolatilityOracle
forge script script/Deploy.s.sol:DeployOracle \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PK \
  --broadcast

# 2. Approve vault address
cast send $HOOK_ADDRESS \
  "approveVault(address)" $AAVE_USDC_VAULT \
  --private-key $PK \
  --rpc-url $SEPOLIA_RPC

# 3. Deploy hook (with address mining)
forge script script/Deploy.s.sol:DeployHook \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PK \
  --broadcast \
  --verify

# 4. Initialize pool with hook
# initData: abi.encode(vaultAddress, juniorVolThreshold=5000)
```

## 3.7 Demo Day Narrative

**Opening**: "What if your LP position never had idle capital? Not a single token sitting unused, whether the price is in range or out of range. That's DualTranche Vault."

**The two problems you solve**:
- "Senior LPs never earn zero — when price leaves their range, their capital automatically moves to Aave and keeps compounding."
- "Junior LPs never enter at the wrong time — the volatility gate is a hard stop that only opens when conditions are statistically favorable."

**Key demo moments**:
1. Senior LP deposits → show no gate, immediate confirmation
2. Junior LP tries to deposit during high-vol → show clean revert with reason
3. Junior LP deposits during low-vol → succeeds, JuniorShares minted
4. Swap pushes price out of range → show vault receiving capital in same tx
5. Time skip → show vault balance growing
6. Price returns → show capital recalled, yield distributed
7. Both LPs claim yield → show Senior earning more (fee + vault APY)

**Closing**: "Two tranche types. One volatility signal. Zero idle capital. DualTranche turns Uniswap v4 into a yield account for passive LPs and a high-conviction venue for active ones."


*Built for UHI9 Hookathon | May 25, 2026*
