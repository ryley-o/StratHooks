// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AdditionalPayeeReceiver} from "../src/AdditionalPayeeReceiver.sol";

/**
 * @title DeployAdditionalPayeeReceiverScript
 * @notice Deployment script for AdditionalPayeeReceiver contract
 * @dev To deploy:
 *      forge script script/DeployAdditionalPayeeReceiver.s.sol:DeployAdditionalPayeeReceiverScript --rpc-url <your_rpc_url> --broadcast
 *
 * Environment variables required:
 * - PRIVATE_KEY: The deployer private key
 * - OWNER_ADDRESS: The owner address (who can update allowedSender)
 * - ALLOWED_SENDER: The minter address (can be zero initially)
 * - CORE_CONTRACT_ADDRESS: The core contract address
 * - PROJECT_ID: The project ID
 * - STRAT_HOOKS_ADDRESS: The StratHooks proxy address
 */
contract DeployAdditionalPayeeReceiverScript is Script {
    function run() external {
        // Read deployment private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Read constructor parameters from environment
        address owner = vm.envAddress("OWNER_ADDRESS");
        address allowedSender = vm.envAddress("ALLOWED_SENDER");
        address coreContract = vm.envAddress("CORE_CONTRACT_ADDRESS");
        uint256 projectId = vm.envUint("PROJECT_ID");
        address stratHooks = vm.envAddress("STRAT_HOOKS_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy AdditionalPayeeReceiver
        AdditionalPayeeReceiver receiver = new AdditionalPayeeReceiver(
            owner,
            allowedSender,
            coreContract,
            projectId,
            stratHooks
        );

        console.log("AdditionalPayeeReceiver deployed at:", address(receiver));

        vm.stopBroadcast();

        // Log deployment details
        console.log("=== Deployment Complete ===");
        console.log("AdditionalPayeeReceiver:", address(receiver));
        console.log("Owner:", owner);
        console.log("Allowed Sender:", allowedSender);
        console.log("Core Contract:", coreContract);
        console.log("Project ID:", projectId);
        console.log("StratHooks:", stratHooks);

        // Remind about next steps
        console.log("");
        console.log("=== NEXT STEPS ===");
        console.log("1. Call setAdditionalPayeeReceiver on StratHooks with address:", address(receiver));
        console.log("2. When minter is deployed, call setAllowedSender on AdditionalPayeeReceiver");
    }
}
