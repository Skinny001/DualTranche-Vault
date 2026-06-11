# DualTranche Vault Hook — Deployment Runbook

> Step-by-step guide for deploying DualTranche to **Unichain Sepolia** (chain ID 1301).
> For architecture details see [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Prerequisites

### 1. Tooling

```bash
# Foundry (forge, cast, anvil)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Verify versions
forge --version   # ≥ forge 0.3.0
cast --version
```

### 2. Wallet with testnet ETH

You need a funded EOA on Unichain Sepolia.

- Faucet: https://faucet.unichain.org (drips 0.01 ETH/day)
- Block explorer: https://sepolia.uniscan.xyz

```bash
# Check balance
cast balance <YOUR_ADDRESS> --rpc-url https://sepolia.unichain.org
```

Recommended minimum: **0.05 ETH** to cover all deployment gas.

### 3. Environment setup

```bash
cp .env.example .env
```

Open `.env` and fill in at minimum:

```bash
PRIVATE_KEY=0x<your-private-key>
UNICHAIN_SEPOLIA_RPC=https://sepolia.unichain.org
```

Load the env in your terminal:

```bash
source .env
```

### 4. Build verification

```bash
forge build --sizes
forge test   # All 135 tests should pass
```

---

## Network Reference

| Parameter | Value |
|---|---|
| Chain ID | `1301` |
| RPC | `https://sepolia.unichain.org` |
| Block explorer | `https://sepolia.uniscan.xyz` |
| PoolManager | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| PositionManager | `0xf969aee60879c54baaed9f3ed26147db216fd664` |
| StateView | `0xc199f1072a74d4e905aba1a84d9a45e2546b6222` |
| PoolSwapTest | `0x9140a78c1a137c7ff1c151ec8231272af78a99a4` |

---

## Deployment Steps

### Step 1 — Deploy Mock Tokens

> Deploys two ERC20 test tokens and mints 1,000,000 of each to your wallet.

```bash
forge script script/Deploy.s.sol:DeployTokens \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast \
  -vvv
```

**Expected output**:
```
Token0 deployed at: 0x...
Token1 deployed at: 0x...
Minted 1,000,000 of each to: 0x<your-address>
```

Set the addresses in your `.env`:
```bash
# In .env — ensure token0 address < token1 address (Uniswap requires this)
TOKEN0=0x...
TOKEN1=0x...
source .env
```

> **Token ordering**: Uniswap v4 requires `currency0 < currency1` numerically. The
> `DeployTokens` script already sorts them and logs them in the correct order.

---

### Step 2 — Deploy Mock Vault

> Deploys a `MockERC4626Vault` backed by `TOKEN0` for testnet capital routing.

```bash
forge script script/Deploy.s.sol:DeployVault \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast \
  -vvv
```

**Expected output**:
```
MockERC4626Vault deployed at: 0x...
  underlying asset (token0): 0x...
```

Set in `.env`:
```bash
VAULT=0x...
source .env
```

> For production: replace this with a real Aave v3 aToken vault or Morpho Blue market
> address. Any ERC4626-compliant contract backed by TOKEN0 works.

---

### Step 3 — Deploy VolatilityOracle

> Deploys the on-chain volatility oracle. Uses Unichain Sepolia PoolManager by default.

```bash
forge script script/Deploy.s.sol:DeployOracle \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast \
  -vvv
```

**Expected output**:
```
VolatilityOracle deployed at: 0x...
  pool manager: 0x00B036B58a818B1BC34d502D3fE730Db729e62AC
```

Set in `.env`:
```bash
ORACLE=0x...
source .env
```

---

### Step 4 — Deploy DualTrancheVaultHook (CREATE2 address mining)

> This is the most complex step. The hook must be deployed at an address whose
> lower 14 bits encode the required permission flags (`0x1F40`). The script
> uses `HookMiner` to find a CREATE2 salt that produces such an address.

```bash
forge script script/Deploy.s.sol:DeployHook \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast \
  -vvv
```

**Expected output**:
```
Mining hook address for deployer: 0x<your-address>
Required flags: 0x1F40
Salt found: 0x0000000000000000000000000000000000000000000000000000000000001234
Expected hook address: 0x...1F40  (last 4 hex digits encode the flags)
DualTrancheVaultHook deployed at: 0x...
  Flags match: true
  Vault approved: 0x<vault>
```

Set in `.env`:
```bash
HOOK=0x...
source .env
```

> **Address mining note**: HookMiner scans up to 160,444 salt candidates. On
> modern hardware this takes <1 second. The salt is embedded in the broadcast
> transaction and reproducible.

> **Validation**: The script calls `Hooks.validateHookPermissions()` on-chain
> after deployment. If this reverts, the address bits are wrong — this should
> never happen if HookMiner ran correctly.

---

### Step 5 — Initialize Pool

> Calls `PoolManager.initialize` to create the Uniswap v4 pool and then
> `hook.initPool` to deploy the `SeniorShares` / `JuniorShares` tokens and
> write the initial `PoolState`.

Default parameters (override in `.env` if needed):

| Parameter | Default | Description |
|---|---|---|
| `JUNIOR_VOL_THRESHOLD` | `5000` | Junior gate closes at ≥ 50% annualized vol |
| `POOL_FEE` | `3000` | 0.3% swap fee |
| `TICK_SPACING` | `60` | Standard for 0.3% tier |
| `TICK_LOWER` | `-887220` | Full range (Senior tracks everything) |
| `TICK_UPPER` | `887220` | Full range |

```bash
forge script script/Deploy.s.sol:InitPool \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast \
  -vvv
```

**Expected output**:
```
Pool initialized:
  currency0:             0x...
  currency1:             0x...
  fee (ppm):             3000
  hook:                  0x...
  juniorVolThreshold:    5000 bps
  seniorTickLower:       -887220
  seniorTickUpper:       887220
  sqrtPriceX96:          79228162514264337593543950336
```

---

### Step 6 — Verify Deployment

Confirm all contracts are live and state is correct:

```bash
# Check hook owner
cast call $HOOK "owner()" --rpc-url $UNICHAIN_SEPOLIA_RPC

# Check vault is approved
cast call $HOOK "approvedVaults(address)(bool)" $VAULT --rpc-url $UNICHAIN_SEPOLIA_RPC

# Check pool state (requires PoolId encoding)
POOL_ID=$(cast keccak "$(cast abi-encode '(address,address,uint24,int24,address)' $TOKEN0 $TOKEN1 3000 60 $HOOK)")
cast call $HOOK "getPoolState(bytes32)((bool,uint256,uint256,uint256,int24,int24,uint256,bool,address))" \
  $POOL_ID --rpc-url $UNICHAIN_SEPOLIA_RPC

# Verify hook address flags
HOOK_INT=$(cast to-dec $HOOK)
echo "Flag bits: $(python3 -c "print(hex($HOOK_INT & 0x3FFF))")"
# Expected: 0x1f40
```

---

### Step 7 — Add Seed Liquidity (manual, optional)

Adding liquidity requires the Uniswap v4 `PositionManager` and `Permit2` approvals. This is done via the frontend or directly via cast:

**Option A — Use the Uniswap v4 interface**

Visit https://app.uniswap.org (or testnet equivalent) and connect to Unichain Sepolia.

**Option B — Cast (manual)**

```bash
# 1. Approve tokens to Permit2 (0x000000000022D473030F116dDEE9F6B43aC78BA3)
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3

cast send $TOKEN0 "approve(address,uint256)" $PERMIT2 $(cast max-uint) \
  --rpc-url $UNICHAIN_SEPOLIA_RPC --private-key $PRIVATE_KEY

cast send $TOKEN1 "approve(address,uint256)" $PERMIT2 $(cast max-uint) \
  --rpc-url $UNICHAIN_SEPOLIA_RPC --private-key $PRIVATE_KEY

# 2. Approve PositionManager on Permit2
POSM=0xf969aee60879c54baaed9f3ed26147db216fd664

cast send $PERMIT2 \
  "approve(address,address,uint160,uint48)" \
  $TOKEN0 $POSM $(cast max-uint 160) $(cast to-dec $(date -d "+1 year" +%s)) \
  --rpc-url $UNICHAIN_SEPOLIA_RPC --private-key $PRIVATE_KEY

cast send $PERMIT2 \
  "approve(address,address,uint160,uint48)" \
  $TOKEN1 $POSM $(cast max-uint 160) $(cast to-dec $(date -d "+1 year" +%s)) \
  --rpc-url $UNICHAIN_SEPOLIA_RPC --private-key $PRIVATE_KEY

# 3. Mint a Senior LP position via PositionManager
# (Encode actions = MINT_POSITION + SETTLE_PAIR, params accordingly)
# See: https://docs.uniswap.org/contracts/v4/guides/hooks/hook-deployment
```

> Seed liquidity is not required for the hook to function. The pool will accept
> swaps once at least one LP position exists.

---

## Verification

Optionally verify source code on Uniscan:

```bash
# Verify VolatilityOracle
forge verify-contract $ORACLE src/oracles/VolatilityOracle.sol:VolatilityOracle \
  --chain 1301 \
  --constructor-args $(cast abi-encode "constructor(address)" $POOL_MANAGER) \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --verifier-url https://api-sepolia.uniscan.xyz/api

# Verify DualTrancheVaultHook
forge verify-contract $HOOK src/DualTrancheVaultHook.sol:DualTrancheVaultHook \
  --chain 1301 \
  --constructor-args $(cast abi-encode "constructor(address,address)" $POOL_MANAGER $ORACLE) \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --verifier-url https://api-sepolia.uniscan.xyz/api
```

---

## Deployed Addresses

> Fill this section in after deployment.

| Contract | Address | Tx hash |
|---|---|---|
| Token0 (TKNA) | | |
| Token1 (TKNB) | | |
| MockERC4626Vault | | |
| VolatilityOracle | | |
| DualTrancheVaultHook | | |
| SeniorShares (sLP) | | |
| JuniorShares (jLP) | | |

---

## Troubleshooting

### `HookMiner: could not find salt`

The miner scanned 160,444 salts and found none matching the required flags. This should not happen. Check that `FLAGS` is exactly `0x1F40` and that the constructor args being passed to HookMiner match those used in the `new DualTrancheVaultHook{salt:}()` call.

### `DeployHook: address mismatch`

The address that `new Hook{salt:}()` produced does not match what HookMiner predicted. This means the `creationCode` or constructor args differ between the `HookMiner.find` call and the actual deploy. Ensure both use `abi.encode(IPoolManager(poolManager), VolatilityOracle(oracle))`.

### `VaultNotApproved`

`hook.initPool` reverts with `VaultNotApproved` if the vault address was not whitelisted before calling `initPool`. The `DeployHook` script calls `hook.approveVault(vault)` automatically. If you redeployed the vault without redeploying the hook, call:

```bash
cast send $HOOK "approveVault(address)" $VAULT \
  --rpc-url $UNICHAIN_SEPOLIA_RPC --private-key $PRIVATE_KEY
```

### `VaultAlreadySet`

`initPool` has already been called for this pool key. Each pool key can only be initialized once. If you need a fresh pool, deploy new tokens (new addresses → new pool key) and repeat from Step 1.

### Gas estimation fails

Foundry's gas estimation for `DeployHook` can sometimes fail because the salt mining loop runs as a view call inside the script. Add `--gas-limit 30000000` to the forge script command if you see gas estimation errors.

### RPC issues

Unichain Sepolia's public RPC occasionally rate-limits. Use a private endpoint from Alchemy or Infura if you see `TooManyRequests` errors:

```bash
# Alchemy Unichain Sepolia
UNICHAIN_SEPOLIA_RPC=https://unichain-sepolia.g.alchemy.com/v2/<KEY>
```

---

## Re-deployment

If you need to redeploy (e.g. after a contract change):

1. Delete old entries from `.env`
2. Restart from Step 1 (deploy new tokens → new addresses → new pool key)
3. You do NOT need to redeploy the PoolManager (it is shared infrastructure)
4. Each hook deployment is independent — multiple hooks can coexist on the same PoolManager

---

## Security Checklist

Before deploying to mainnet:

- [ ] Replace `MockERC4626Vault` with an audited production vault (Aave, Morpho)
- [ ] Replace `VolatilityOracle._computeVolFromTWAP` stub with real TWAP implementation
- [ ] Audit the 90/10 vault yield split and ensure it matches your tokenomics
- [ ] Set `juniorVolThreshold` based on empirical vol data for your specific token pair
- [ ] Ensure the deployer key is a multisig or timelock before calling `approveVault`
- [ ] Add a `revokeVault` function and test the emergency recall path
- [ ] Fuzz the `_estimateFee` function against actual swap events from mainnet
- [ ] Gas profile all hook callbacks under worst-case conditions (full range, max liquidity)
