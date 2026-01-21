# Thor Migration Project (Foundry Deployment Repo)

This folder is the Foundry workspace for the Thor Migration project, including 5 core contracts and a production deployment script.

## Contracts

- `src/metro.sol`: `MetroTokenOFT` (OFT + ERC20Permit, mintable by `xMETRO`)
- `src/xMETRO.sol`: Core contract (locks, vesting, rewards, autocompound)
- `src/SwapAdapter.sol`: USDC -> METRO swap adapter (optional)
- `src/RewardDistributor.sol`: Reward injector (optional; operator calls to deposit rewards into `xMETRO`)
- `src/ThorMigrationEscrow.sol`: Migration escrow (custodies THOR/yTHOR and credits `xMETRO` on the same chain)

## Layout

- `src/`: contract sources (only these 5 matter for production deployment)
- `script/Deploy.s.sol`: single-chain deployment script (deploy + wire `xMETRO.migrationEscrow`)
- `deployments/addresses.json`: deployment output (written by the script)

## 1) Deploy (Install Foundry + dependencies)

```bash
curl -L https://foundry.paradigm.xyz | bash foundryup

git clone <REPO_URL>
cd ThorMigrationProject

forge install \
  foundry-rs/forge-std@v1.12.0 \
  OpenZeppelin/openzeppelin-contracts@v5.5.0 \
  LayerZero-Labs/LayerZero-v2@ab9b083410b9359285a5756807e1b6145d4711a7 \
  GNSPS/solidity-bytes-utils@v0.8.1

# Optional (only if you run devtools-based tests):
# forge install LayerZero-Labs/devtools@16daaee36fe802d11aa99b89c29bb74447354483

# Fast compile (deploy profile ignores `test/`, quiet output)
FOUNDRY_PROFILE=deploy forge build -q && echo "Compile success"
```


## 2) Configure `.env`
Create your local `.env` from the template, then edit it:

```bash
cp .env.example .env
```

These **business parameters** must be reviewed/filled by the project team:
- `DEPLOYER_PRIVATE_KEY`
- `METRO_NAME`
- `METRO_SYMBOL`
- `LZ_ENDPOINT`
- `USDC`
- `THOR`
- `YTHOR`
- `MIGRATION_START_TIME`
- `CAP_10M`
- `CAP_3M`
- `CAP_YTHOR`
- `RATIO_10M`
- `RATIO_3M`
- `RATIO_YTHOR`
- `DEADLINE_10M`
- `DEADLINE_3M`
- `DEADLINE_YTHOR`
- `OWNER`
- `ROUTER_V2`
- `ROUTER_V3`
- `REWARD_DISTRIBUTOR_OPERATOR`
- `AUTO_COMPOUND_OPERATOR`
- `CONTRIBUTORS`

## 3) Deploy Commands
```bash
# Deploy everything on a single chain (e.g. Ethereum mainnet)
FOUNDRY_PROFILE=deploy forge script script/Deploy.s.sol:Deploy --rpc-url https://ethereum-rpc.publicnode.com --broadcast -q && echo "deploy success"
```

Deployment addresses are written to `deployments/addresses.json`.
