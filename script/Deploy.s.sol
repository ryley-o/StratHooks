// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {StratHooks} from "../src/StratHooks.sol";

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

        vm.startBroadcast(deployerPrivateKey);

        // Deploy StratHooks
        StratHooks hooks = new StratHooks(owner, additionalPayeeReceiver, keeper, coreContract, projectId);

        vm.stopBroadcast();

        // Log deployment address
        console.log("StratHooks deployed to:", address(hooks));
        console.log("Owner:", owner);
        console.log("Additional Payee Receiver:", additionalPayeeReceiver);
        console.log("Keeper:", keeper);
        console.log("Core Contract:", coreContract);
        console.log("Project ID:", projectId);
    }
}

