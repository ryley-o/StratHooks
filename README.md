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
│   ├── openzeppelin-contracts/ # OpenZeppelin v5.0.0
│   ├── solady/                 # Solady utilities (SSTORE2)
│   └── forge-std/              # Foundry standard library
└── foundry.toml                # Foundry configuration
```

## Setup

This project uses:
- **Solidity**: 0.8.22
- **OpenZeppelin**: v5.0.0
- **Art Blocks Contracts**: Local copies from main branch (not a submodule)
- **Solady**: For SSTORE2 utilities

### Why Local Copies?

The Art Blocks contracts are copied locally rather than used as a submodule because:
1. The PMP hooks are only available on the main branch, not in releases
2. We need to modify import paths to use Solady's SSTORE2
3. This gives us full control without modifying external dependencies

### Installation

```bash
# Clone the repository
git clone <your-repo-url>
cd StratHooks

# Install dependencies (already installed)
forge install

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

## Dependencies

The project uses remappings for external dependencies:

```toml
remappings = [
    "@openzeppelin-5.0/=lib/openzeppelin-contracts/",
    "forge-std/=lib/forge-std/src/",
    "solady/=lib/solady/src/"
]
```

Art Blocks contracts are stored locally in `src/abstract/`, `src/interfaces/`, and `src/libs/` directories.

## License

LGPL-3.0-only

## References

- [Art Blocks Contracts](https://github.com/ArtBlocks/artblocks-contracts)
- [LiftHooks Example](https://github.com/ArtBlocks/artblocks-contracts/blob/main/packages/contracts/contracts/web3call/combined-hooks/LiftHooks.sol)
- [Foundry Book](https://book.getfoundry.sh/)
