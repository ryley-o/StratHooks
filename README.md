# StratHooks

A Foundry-based implementation of Art Blocks PostMintParameter hooks for custom token parameter handling.

## Deployments

### Mainnet

| Contract | Address |
|----------|---------|
| StratHooks Proxy (UUPS) | `0x9a3f4307b1d12aeA5E2633e6e10Fb3cf9Ac81F9a` |
| StratHooksV2 Implementation | `0x828665d0f1b7b264083a6dbe40123d5506249a80` |
| AdditionalPayeeReceiver | `0x27f798fCdD4414bf9545ACDdcE413D50cD4F379F` |

**Implementation History:**
- V1: `0x82a0ae1e6791e2a4d02ab7147c867f921fb6aa21` (initial deployment)
- V2: `0x828665d0f1b7b264083a6dbe40123d5506249a80` (current - bug fixes)

## Overview

StratHooks implements both `AbstractPMPAugmentHook` and `AbstractPMPConfigureHook` from the Art Blocks contracts to provide custom PostMintParameter (PMP) functionality. This allows for:

- **Configure Hooks**: Validate parameters when users configure their tokens
- **Augment Hooks**: Inject or modify parameters when tokens are read

## V2 Upgrade

StratHooksV2 is an upgraded implementation that fixes critical bugs in the Chainlink Automation integration:

### Bug Fixes

| Issue | V1 Behavior | V2 Fix |
|-------|-------------|--------|
| Upkeep on uninitialized tokens | `performUpkeep` allowed when `createdAt=0` | `require(t.createdAt != 0, "Token not initialized")` |
| Terminal condition | `if (currentRound == 12) continue` | `if (currentRound >= 12) continue` |
| Double receive | No check | `require(tokenMetadata[tokenId].createdAt == 0, "Token already initialized")` |

### Migration

The V2 upgrade includes a one-time migration (`initializeV2RepairToken0`) that repairs token 0's corrupted price history by keeping only the last entry (the correct post-receiveFunds baseline price).

### Upgrade Process

See [script/UpgradeToV2.s.sol](script/UpgradeToV2.s.sol) for the upgrade scripts. Two options available:

1. **Two-step upgrade** (recommended): Deploy implementation with any wallet, then owner calls `upgradeToAndCall` via Etherscan
2. **One-step upgrade**: Owner deploys and upgrades in single transaction

## Project Structure

```
├── src/
│   ├── StratHooks.sol          # Main hook implementation (V1)
│   ├── StratHooksV2.sol        # Upgraded implementation with bug fixes
│   ├── AdditionalPayeeReceiver.sol  # Receives mint funds and forwards to StratHooks
│   ├── abstract/               # Abstract base contracts
│   │   ├── AbstractPMPAugmentHook.sol
│   │   └── AbstractPMPConfigureHook.sol
│   ├── interfaces/             # Art Blocks PMP interfaces
│   │   ├── IWeb3Call.sol
│   │   ├── IPMPV0.sol
│   │   ├── IPMPAugmentHook.sol
│   │   ├── IPMPConfigureHook.sol
│   │   ├── IGuardedEthTokenSwapper.sol
│   │   └── ISlidingScaleMinter.sol
│   └── libs/                   # Libraries
│       └── ImmutableStringArray.sol
├── test/
│   ├── StratHooks.t.sol        # V1 test suite
│   ├── StratHooksV2.t.sol      # V2 upgrade tests
│   ├── AdditionalPayeeReceiver.t.sol
│   └── MainnetForkMint.t.sol   # Mainnet fork integration tests
├── script/
│   ├── Deploy.s.sol            # Initial deployment script
│   ├── DeployAdditionalPayeeReceiver.s.sol
│   └── UpgradeToV2.s.sol       # V2 upgrade scripts
├── lib/
│   ├── openzeppelin-contracts/     # OpenZeppelin v5.0.0
│   ├── openzeppelin-contracts-upgradeable/  # Upgradeable contracts
│   ├── chainlink-brownie-contracts/  # Chainlink Automation
│   ├── solady/                     # Solady utilities (SSTORE2)
│   ├── guarded-eth-token-swapper/  # ETH<->Token swapper with MEV protection
│   └── forge-std/                  # Foundry standard library
└── foundry.toml                    # Foundry configuration
```

## Setup

### Dependencies

This project uses:

- **Solidity**: 0.8.24
- **OpenZeppelin v5.0.0**: Installed as submodule in `lib/openzeppelin-contracts`
- **Chainlink Brownie Contracts v1.2.0**: Installed as submodule in `lib/chainlink-brownie-contracts` (Automation interfaces)
- **Solady**: Installed as submodule in `lib/solady` (provides SSTORE2)
- **forge-std**: Installed as submodule in `lib/forge-std`
- **GuardedEthTokenSwapper**: Installed as submodule in `lib/guarded-eth-token-swapper` ([View on GitHub](https://github.com/ryley-o/GuardedEthTokenSwapper))
- **Art Blocks Contracts**: **Local copies** in `src/abstract/`, `src/interfaces/`, and `src/libs/` (NOT a submodule)

### GuardedEthTokenSwapper

The [GuardedEthTokenSwapper](https://github.com/ryley-o/GuardedEthTokenSwapper) is a production-ready contract deployed on Ethereum mainnet that provides:

- **MEV Protection**: Uses Chainlink oracles to prevent sandwich attacks
- **ETH → ERC20 Swaps**: Optimized for ETH pairs with Uniswap V3
- **14 Supported Tokens**: WBTC, LINK, UNI, AAVE, and more
- **Deployed at**: `0x96E6a25565E998C6EcB98a59CC87F7Fc5Ed4D7b0`
- **Interface Available**: `IGuardedEthTokenSwapper.sol` for easy integration

This contract can be integrated into your StratHooks to enable secure token swaps as part of the post-mint parameter configuration flow.

**Usage Example:**

```solidity
import {IGuardedEthTokenSwapper} from "guarded-eth-token-swapper/IGuardedEthTokenSwapper.sol";

address constant GUARDED_SWAPPER = 0x96E6a25565E998C6EcB98a59CC87F7Fc5Ed4D7b0;
IGuardedEthTokenSwapper swapper = IGuardedEthTokenSwapper(GUARDED_SWAPPER);
```

### Chainlink Automation

StratHooks implements the [Chainlink AutomationCompatibleInterface](https://docs.chain.link/chainlink-automation) for automated upkeep of token states:

- **Automated Execution**: Chainlink nodes automatically monitor and execute upkeep when needed
- **Idempotent Design**: Uses `tokenId` + `round` for guaranteed idempotency
- **Gas Efficient**: Off-chain checks via `checkUpkeep`, on-chain execution via `performUpkeep`
- **Extensible**: Override `_shouldPerformUpkeep()` and `_performTokenUpkeep()` for custom logic

**Key Features:**

- **Round-based Execution**: Each token maintains a `round` counter that increments after each upkeep
- **Duplicate Prevention**: Tracks executed rounds to prevent duplicate execution
- **Stale Protection**: Validates that upkeep data matches current round before execution
- **Per-Token Tracking**: Maintains independent state for each token

**Implementation Pattern:**

```solidity
// Override to define when upkeep is needed
function _shouldPerformUpkeep(uint256 tokenId) internal view override returns (bool) {
    // Your custom logic (e.g., time-based, event-based, state-based)
    return someCondition;
}

// Override to define what happens during upkeep
function _performTokenUpkeep(uint256 tokenId, uint256 round) internal override {
    // Your custom action (e.g., swap tokens, update parameters)
}
```

See the [Chainlink Automation documentation](https://docs.chain.link/chainlink-automation) for more information on registering your upkeep.

### Why Local Art Blocks Contracts?

The Art Blocks PMP hook contracts are copied locally rather than used as a submodule because:

1. The PMP hooks are only available on the main branch, not in tagged releases
2. We need to modify import paths to use Solady's SSTORE2 instead of their bundled version
3. This gives us full control without modifying external git submodules
4. Keeps the dependency tree clean and version-controlled within this repo

### Installation

```bash
# Clone the repository
git clone <your-repo-url>
cd StratHooks

# Install submodule dependencies (if not already present)
git submodule update --init --recursive

# Build
forge build

# Run tests
forge test
```

## Environment / .env

You do **not** need a `.env` file to build or run the standard test suite.

Use a `.env` file (or export variables) only if you:

- **Run mainnet fork tests:** set `MAINNET_RPC_URL` (e.g. from Alchemy, Infura, or another RPC provider).
- **Deploy or run deployment scripts:** set the variables required by the script (e.g. `script/Deploy.s.sol` uses `PRIVATE_KEY`, `OWNER_ADDRESS`, `ADDITIONAL_PAYEE_RECEIVER`, `KEEPER_ADDRESS`, `CORE_CONTRACT_ADDRESS`, `PROJECT_ID`, `SLIDING_SCALE_MINTER_ADDRESS`). See each script’s `vm.env*` calls for the full list.

Example `.env` for fork tests only:

```bash
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
```

## Usage

### Building

```bash
forge build
```

### Testing

```bash
# Run all tests (excludes mainnet fork tests; no .env required)
forge test --no-match-contract MainnetForkMintTest

# Run with verbosity
forge test -vvv --no-match-contract MainnetForkMintTest

# Run mainnet fork integration tests (requires MAINNET_RPC_URL, e.g. from .env)
forge test --match-contract MainnetForkMintTest -vvvv --fork-url $MAINNET_RPC_URL

# Run specific test
forge test --match-test test_OnTokenPMPConfigure
```

### Deployment

```bash
# Initial deployment (new proxy + implementation)
forge script script/Deploy.s.sol --rpc-url <your_rpc_url> --broadcast
```

### Upgrading to V2

**Option 1: Two-step upgrade (recommended for security)**

```bash
# Step 1: Deploy new implementation (any wallet can do this)
export PRIVATE_KEY=<deployer_private_key>
export STRATHOOKS_PROXY=0x9a3f4307b1d12aea5e2633e6e10fb3cf9ac81f9a
export ETHERSCAN_API_KEY=<your_etherscan_api_key>

forge script script/UpgradeToV2.s.sol:DeployV2ImplementationScript \
  --rpc-url $MAINNET_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv

# Step 2: Owner calls upgradeToAndCall via Etherscan using the output from Step 1
# Go to: https://etherscan.io/address/0x9a3f4307b1d12aea5e2633e6e10fb3cf9ac81f9a#writeProxyContract
# Call upgradeToAndCall with:
#   newImplementation: <address from script output>
#   data: <initializeV2RepairToken0 calldata from script output>
```

**Option 2: One-step upgrade (requires owner key)**

```bash
export PRIVATE_KEY=<owner_private_key>
export STRATHOOKS_PROXY=0x9a3f4307b1d12aea5e2633e6e10fb3cf9ac81f9a

forge script script/UpgradeToV2.s.sol:UpgradeToV2Script \
  --rpc-url $MAINNET_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

## Contract Details

### StratHooks.sol

The main contract implements multiple interfaces and provides extensible hooks:

#### Art Blocks PMP Hooks

**`onTokenPMPConfigure`**
Called when a user configures PostMintParameters for their token. Use this to:

- Validate parameter values
- Check ownership or permissions
- Enforce custom business logic

Revert to reject the configuration.

**`onTokenPMPReadAugmentation`**
Called when token parameters are read. Use this to:

- Inject additional parameters
- Modify existing parameters
- Filter out parameters

Returns the augmented parameter array.

#### Chainlink Automation Interface

**`checkUpkeep(bytes calldata checkData)`**

- Called off-chain by Chainlink Automation nodes
- Input: ABI-encoded `uint256 tokenId`
- Returns: `(bool upkeepNeeded, bytes memory performData)`
- The `performData` encodes `(uint256 tokenId, uint256 round)` for idempotency

**`performUpkeep(bytes calldata performData)`**

- Called on-chain when `checkUpkeep` returns `true`
- Input: ABI-encoded `(uint256 tokenId, uint256 round)`
- Ensures idempotency through round tracking
- Prevents stale and duplicate executions

**Protected Helper Functions** (override these in your implementation):

- `_shouldPerformUpkeep(uint256 tokenId)`: Define upkeep conditions
- `_performTokenUpkeep(uint256 tokenId, uint256 round)`: Define upkeep actions

## Customization

1. Add your state variables in the contract
2. Implement validation logic in `onTokenPMPConfigure`
3. Implement augmentation logic in `onTokenPMPReadAugmentation`
4. Add helper functions as needed

See the inline comments in `StratHooks.sol` for guidance.

## Import Remappings

The project uses Foundry remappings for external submodule dependencies only:

```toml
remappings = [
    "@openzeppelin-5.0/=lib/openzeppelin-contracts/",        # OpenZeppelin contracts
    "@chainlink/=lib/chainlink-brownie-contracts/contracts/src/",  # Chainlink Automation
    "forge-std/=lib/forge-std/src/",                         # Foundry test utilities
    "solady/=lib/solady/src/",                               # Solady (SSTORE2)
    "guarded-eth-token-swapper/=lib/guarded-eth-token-swapper/src/"  # MEV-protected token swapper
]
```

**Note:** Art Blocks contracts do NOT use remappings. They are imported directly as local files:

- `src/abstract/AbstractPMPAugmentHook.sol`
- `src/abstract/AbstractPMPConfigureHook.sol`
- `src/interfaces/*.sol`
- `src/libs/ImmutableStringArray.sol`

This approach avoids submodule complications and gives us full control over these files.

## License

LGPL-3.0-only

## References

- [Art Blocks Contracts](https://github.com/ArtBlocks/artblocks-contracts)
- [LiftHooks Example](https://github.com/ArtBlocks/artblocks-contracts/blob/main/packages/contracts/contracts/web3call/combined-hooks/LiftHooks.sol)
- [Foundry Book](https://book.getfoundry.sh/)
