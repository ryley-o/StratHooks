// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {StratHooksV2} from "../src/StratHooksV2.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title DeployV2ImplementationScript
 * @notice Deploys the StratHooksV2 implementation and outputs calldata for owner to upgrade
 * @dev This is a two-step upgrade process:
 *      Step 1: Anyone deploys the new implementation (this script)
 *      Step 2: Owner calls upgradeToAndCall on proxy via Etherscan/Metamask
 *
 * Environment variables required:
 * - PRIVATE_KEY: Any wallet's private key (just needs gas for deployment)
 * - STRATHOOKS_PROXY: The proxy contract address (0x9a3f4307b1d12aea5e2633e6e10fb3cf9ac81f9a)
 * - ETHERSCAN_API_KEY: Your Etherscan API key (for --verify)
 *
 * Deploy implementation only (with Etherscan verification):
 *   forge script script/UpgradeToV2.s.sol:DeployV2ImplementationScript \
 *     --rpc-url $MAINNET_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 *
 * Deploy without verification (if you prefer to verify manually later):
 *   forge script script/UpgradeToV2.s.sol:DeployV2ImplementationScript \
 *     --rpc-url $MAINNET_RPC_URL \
 *     --broadcast \
 *     -vvvv
 */
contract DeployV2ImplementationScript is Script {
    function run() external {
        // Read deployment private key from environment (any wallet, just needs gas)
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Read proxy address from environment (for reference in output)
        address proxyAddress = vm.envAddress("STRATHOOKS_PROXY");

        console.log("=== StratHooks V2 Implementation Deployment ===");
        console.log("Proxy address:", proxyAddress);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy new implementation
        StratHooksV2 newImplementation = new StratHooksV2();

        vm.stopBroadcast();

        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("New Implementation Address:", address(newImplementation));
        console.log("");

        // Generate the calldata for upgradeToAndCall
        bytes memory initData = abi.encodeCall(StratHooksV2.initializeV2RepairToken0, ());
        bytes memory upgradeCalldata =
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(newImplementation), initData));

        console.log("=== NEXT STEP: Owner must call upgradeToAndCall on proxy ===");
        console.log("");
        console.log("Option 1: Via Etherscan 'Write as Proxy'");
        console.log("------------------------------------------");
        console.log("1. Go to: https://etherscan.io/address/%s#writeProxyContract", proxyAddress);
        console.log("2. Connect wallet as owner");
        console.log("3. Find 'upgradeToAndCall' function");
        console.log("4. Enter parameters:");
        console.log("   newImplementation: %s", address(newImplementation));
        console.log("   data: %s", vm.toString(initData));
        console.log("");
        console.log("Option 2: Via raw transaction (Etherscan 'Write Contract')");
        console.log("-----------------------------------------------------------");
        console.log("1. Go to: https://etherscan.io/address/%s#writeContract", proxyAddress);
        console.log("2. Connect wallet as owner");
        console.log("3. Use 'Write' with raw calldata:");
        console.log("");
        console.log("   To: %s", proxyAddress);
        console.log("   Data: %s", vm.toString(upgradeCalldata));
        console.log("   Value: 0");
        console.log("");
        console.log("=== PARAMETERS BREAKDOWN ===");
        console.log("Function: upgradeToAndCall(address,bytes)");
        console.log("Selector: 0x4f1ef286");
        console.log("newImplementation: %s", address(newImplementation));
        console.log("data (initializeV2RepairToken0): %s", vm.toString(initData));
        console.log("");
        console.log("=== WHAT THE UPGRADE DOES ===");
        console.log("1. Upgrades proxy to new StratHooksV2 implementation");
        console.log("2. Calls initializeV2RepairToken0() which:");
        console.log("   - Repairs token 0's priceHistory to 1 entry (keeps last)");
        console.log("   - Emits TokenPriceHistoryRepaired event");
        console.log("3. Going forward:");
        console.log("   - performUpkeep requires token to be initialized");
        console.log("   - checkUpkeep skips uninitialized tokens");
        console.log("   - receiveFunds prevents double-receive");
    }
}

/**
 * @title UpgradeToV2Script
 * @notice Full upgrade script (deploys + upgrades in one tx) - requires owner key
 * @dev Use this if you have access to the owner's private key
 *
 * Environment variables required:
 * - PRIVATE_KEY: The owner's private key (must be proxy owner)
 * - STRATHOOKS_PROXY: The proxy contract address
 *
 * Dry-run:
 *   forge script script/UpgradeToV2.s.sol:UpgradeToV2Script \
 *     --rpc-url $MAINNET_RPC_URL \
 *     -vvvv
 *
 * Broadcast:
 *   forge script script/UpgradeToV2.s.sol:UpgradeToV2Script \
 *     --rpc-url $MAINNET_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract UpgradeToV2Script is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address proxyAddress = vm.envAddress("STRATHOOKS_PROXY");

        console.log("=== StratHooks V2 Full Upgrade ===");
        console.log("Proxy address:", proxyAddress);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy new implementation
        StratHooksV2 newImplementation = new StratHooksV2();
        console.log("New implementation deployed at:", address(newImplementation));

        // 2. Prepare the reinitializer call data
        bytes memory initData = abi.encodeCall(StratHooksV2.initializeV2RepairToken0, ());

        // 3. Upgrade proxy to new implementation and call the repair function
        UUPSUpgradeable proxy = UUPSUpgradeable(proxyAddress);
        proxy.upgradeToAndCall(address(newImplementation), initData);

        console.log("Upgrade complete!");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Upgrade Summary ===");
        console.log("Proxy:", proxyAddress);
        console.log("New Implementation:", address(newImplementation));
        console.log("Migration: initializeV2RepairToken0() executed");
    }
}

/**
 * @title GenerateUpgradeCalldataScript
 * @notice Generate upgrade calldata for a known implementation address
 * @dev Use this if implementation is already deployed and you just need the calldata
 *
 * Environment variables required:
 * - STRATHOOKS_PROXY: The proxy contract address
 * - NEW_IMPLEMENTATION: The already-deployed V2 implementation address
 *
 * Run:
 *   forge script script/UpgradeToV2.s.sol:GenerateUpgradeCalldataScript -vvvv
 */
contract GenerateUpgradeCalldataScript is Script {
    function run() external view {
        address proxyAddress = vm.envAddress("STRATHOOKS_PROXY");
        address newImplementation = vm.envAddress("NEW_IMPLEMENTATION");

        console.log("=== Upgrade Calldata Generator ===");
        console.log("");
        console.log("Proxy:", proxyAddress);
        console.log("New Implementation:", newImplementation);
        console.log("");

        // Generate calldata
        bytes memory initData = abi.encodeCall(StratHooksV2.initializeV2RepairToken0, ());
        bytes memory upgradeCalldata = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newImplementation, initData));

        console.log("=== For Etherscan 'Write as Proxy' -> upgradeToAndCall ===");
        console.log("newImplementation: %s", newImplementation);
        console.log("data: %s", vm.toString(initData));
        console.log("");
        console.log("=== For raw transaction ===");
        console.log("To: %s", proxyAddress);
        console.log("Data: %s", vm.toString(upgradeCalldata));
        console.log("Value: 0");
    }
}
