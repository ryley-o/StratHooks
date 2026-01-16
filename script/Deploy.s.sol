// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {StratHooks} from "../src/StratHooks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployScript
 * @notice Deployment script for StratHooks contract (UUPS upgradeable)
 * @dev To deploy:
 *      forge script script/Deploy.s.sol:DeployScript --rpc-url <your_rpc_url> --broadcast
 *
 * Environment variables required:
 * - PRIVATE_KEY: The deployer private key
 * - OWNER_ADDRESS: The owner address
 * - ADDITIONAL_PAYEE_RECEIVER: The additional payee receiver address
 * - KEEPER_ADDRESS: The keeper address
 * - CORE_CONTRACT_ADDRESS: The core contract address
 * - PROJECT_ID: The project ID
 * - SLIDING_SCALE_MINTER_ADDRESS: The sliding scale minter address (for purchase price queries)
 */
contract DeployScript is Script {
    function run() external {
        // Read deployment private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Read constructor parameters from environment
        address owner = vm.envAddress("OWNER_ADDRESS");
        address additionalPayeeReceiver = vm.envAddress("ADDITIONAL_PAYEE_RECEIVER");
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        address coreContract = vm.envAddress("CORE_CONTRACT_ADDRESS");
        uint256 projectId = vm.envUint("PROJECT_ID");
        address slidingScaleMinterAddress = vm.envAddress("SLIDING_SCALE_MINTER_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation
        StratHooks implementation = new StratHooks();
        console.log("Implementation deployed at:", address(implementation));

        // Prepare initializer data
        bytes memory initData = abi.encodeWithSelector(
            StratHooks.initialize.selector,
            owner,
            additionalPayeeReceiver,
            keeper,
            coreContract,
            projectId,
            slidingScaleMinterAddress
        );

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log("Proxy deployed at:", address(proxy));

        // Cast to StratHooks for convenience
        StratHooks hooks = StratHooks(address(proxy));

        vm.stopBroadcast();

        // Log deployment details
        console.log("=== Deployment Complete ===");
        console.log("Implementation:", address(implementation));
        console.log("Proxy (StratHooks):", address(hooks));
        console.log("Owner:", owner);
        console.log("Additional Payee Receiver:", additionalPayeeReceiver);
        console.log("Keeper:", keeper);
        console.log("Core Contract:", coreContract);
        console.log("Project ID:", projectId);
        console.log("Sliding Scale Minter:", slidingScaleMinterAddress);
    }
}

