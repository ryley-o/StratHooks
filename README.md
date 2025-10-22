# StratHooks

A Foundry-based implementation of Art Blocks PostMintParameter hooks for custom token parameter handling.

## Overview

StratHooks implements both `AbstractPMPAugmentHook` and `AbstractPMPConfigureHook` from the Art Blocks contracts to provide custom PostMintParameter (PMP) functionality. This allows for:

- **Configure Hooks**: Validate parameters when users configure their tokens
- **Augment Hooks**: Inject or modify parameters when tokens are read

## Project Structure

```
├── src/
│   ├── StratHooks.sol          # Main hook implementation
│   ├── abstract/               # Abstract base contracts
│   │   ├── AbstractPMPAugmentHook.sol
│   │   └── AbstractPMPConfigureHook.sol
│   ├── interfaces/             # Art Blocks PMP interfaces
│   │   ├── IWeb3Call.sol
│   │   ├── IPMPV0.sol
│   │   ├── IPMPAugmentHook.sol
│   │   └── IPMPConfigureHook.sol
│   └── libs/                   # Libraries
│       └── ImmutableStringArray.sol
├── test/
│   └── StratHooks.t.sol        # Test suite
├── script/
│   └── Deploy.s.sol            # Deployment script
├── lib/
│   ├── openzeppelin-contracts/     # OpenZeppelin v5.0.0
│   ├── solady/                     # Solady utilities (SSTORE2)
│   ├── guarded-eth-token-swapper/  # ETH<->Token swapper with MEV protection
│   └── forge-std/                  # Foundry standard library
└── foundry.toml                    # Foundry configuration
```

## Setup

### Dependencies

This project uses:
- **Solidity**: 0.8.22
- **OpenZeppelin v5.0.0**: Installed as submodule in `lib/openzeppelin-contracts`
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

## Usage

### Building

```bash
forge build
```

### Testing

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vv

# Run specific test
forge test --match-test test_OnTokenPMPConfigure
```

### Deployment

```bash
# Deploy to a network
forge script script/Deploy.s.sol --rpc-url <your_rpc_url> --broadcast
```

## Contract Details

### StratHooks.sol

The main contract implements two key functions:

#### `onTokenPMPConfigure`
Called when a user configures PostMintParameters for their token. Use this to:
- Validate parameter values
- Check ownership or permissions
- Enforce custom business logic

Revert to reject the configuration.

#### `onTokenPMPReadAugmentation`
Called when token parameters are read. Use this to:
- Inject additional parameters
- Modify existing parameters
- Filter out parameters

Returns the augmented parameter array.

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
