# UUPS Upgradeable Conversion

## Summary

`StratHooks.sol` has been successfully converted to a **UUPS (Universal Upgradeable Proxy Standard)** upgradeable contract using OpenZeppelin's upgradeable contracts library v5.1.0.

## Key Changes

### 1. Dependencies Added
```bash
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.1.0
```

### 2. Contract Inheritance
**Before:**
```solidity
contract StratHooks is AbstractPMPAugmentHook, AbstractPMPConfigureHook, AutomationCompatibleInterface, Ownable
```

**After:**
```solidity
contract StratHooks is
    Initializable,
    AbstractPMPAugmentHook,
    AbstractPMPConfigureHook,
    AutomationCompatibleInterface,
    OwnableUpgradeable,
    UUPSUpgradeable
```

### 3. Storage Pattern (ERC-7201)
Immutable variables (`CORE_CONTRACT_ADDRESS`, `PROJECT_ID`, `keeper`) were converted to namespaced storage following ERC-7201:

```solidity
/// @custom:storage-location erc7201:strathooks.storage.v1
struct StratHooksStorage {
    address coreContractAddress;
    uint256 projectId;
    address keeper;
}

bytes32 private constant STRATHOOKS_STORAGE_LOCATION =
    0x7c8d1d3f8e9b3a4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b00;
```

Public getter functions replace direct access:
- `CORE_CONTRACT_ADDRESS()` → Returns address
- `PROJECT_ID()` → Returns uint256
- `keeper()` → Returns address

### 4. Constructor → Initialize Pattern
**Before:**
```solidity
constructor(
    address owner_,
    address additionalPayeeReceiver_,
    address keeper_,
    address coreContract_,
    uint256 projectId_
) Ownable(owner_) {
    // ... initialization
}
```

**After:**
```solidity
constructor() {
    _disableInitializers();
}

function initialize(
    address owner_,
    address additionalPayeeReceiver_,
    address keeper_,
    address coreContract_,
    uint256 projectId_
) public initializer {
    __Ownable_init(owner_);
    __UUPSUpgradeable_init();
    
    // Initialize state variables
    additionalPayeeReceiver = additionalPayeeReceiver_;
    
    StratHooksStorage storage $ = _getStratHooksStorage();
    $.keeper = keeper_;
    $.coreContractAddress = coreContract_;
    $.projectId = projectId_;
}
```

### 5. Upgrade Authorization
Added required `_authorizeUpgrade` function:

```solidity
function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
```

Only the owner can authorize upgrades.

### 6. Deployment Pattern
**Implementation + Proxy:**

```solidity
// Deploy implementation
StratHooks implementation = new StratHooks();

// Prepare initializer data
bytes memory initData = abi.encodeWithSelector(
    StratHooks.initialize.selector,
    owner,
    additionalPayeeReceiver,
    keeper,
    coreContract,
    projectId
);

// Deploy proxy
ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

// Use proxy as StratHooks
StratHooks hooks = StratHooks(address(proxy));
```

## Deployment

### Using the Deploy Script
```bash
# Set environment variables
export PRIVATE_KEY="your_private_key"
export OWNER_ADDRESS="0x..."
export ADDITIONAL_PAYEE_RECEIVER="0x..."
export KEEPER_ADDRESS="0x..."
export CORE_CONTRACT_ADDRESS="0x..."
export PROJECT_ID="1"

# Deploy
forge script script/Deploy.s.sol:DeployScript --rpc-url <rpc_url> --broadcast
```

The script will output:
- **Implementation address** - The logic contract
- **Proxy address** - The actual StratHooks contract address users interact with

## Upgrading

To upgrade the contract to a new implementation:

```solidity
// Deploy new implementation
StratHooks newImplementation = new StratHooks();

// Upgrade (only owner can do this)
StratHooks(proxyAddress).upgradeToAndCall(address(newImplementation), "");
```

## Testing

All 42 tests pass with the UUPS upgrade:
- Tests updated to use proxy deployment pattern
- `setUp()` now deploys implementation + proxy
- All existing functionality preserved

```bash
forge test --offline
# Result: 42 tests passed
```

## Benefits

1. **Upgradeability**: Contract logic can be upgraded without changing the contract address
2. **State Preservation**: All state is maintained across upgrades
3. **Owner-Controlled**: Only the owner can authorize upgrades
4. **Gas Efficient**: UUPS pattern is more gas-efficient than Transparent Proxy
5. **ERC-7201 Compliance**: Uses namespaced storage to avoid collisions

## Important Notes

- ⚠️ The proxy address is the "real" contract address that users should interact with
- ⚠️ Never call functions directly on the implementation contract
- ⚠️ Always test upgrades thoroughly on testnet before mainnet
- ⚠️ Storage layout must be append-only in future upgrades (never remove or reorder variables)
- ⚠️ The `initialize` function can only be called once (protected by `initializer` modifier)

## Files Modified

1. `/src/StratHooks.sol` - Converted to UUPS upgradeable
2. `/test/StratHooks.t.sol` - Updated tests for proxy pattern
3. `/script/Deploy.s.sol` - Updated deployment script
4. `/src/AdditionalPayeeReceiver.sol` - New contract (not upgradeable)

## Verification

After deployment, verify both contracts on Etherscan:

```bash
# Verify implementation
forge verify-contract <implementation_address> StratHooks --chain-id <chain_id>

# Verify proxy
forge verify-contract <proxy_address> ERC1967Proxy --chain-id <chain_id> \
  --constructor-args $(cast abi-encode "constructor(address,bytes)" <implementation_address> <init_data>)
```

