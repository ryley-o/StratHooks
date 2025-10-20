// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {StratHooks} from "../src/StratHooks.sol";

contract DeployScript is Script {
    function run() external {
        // Read deployment private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy StratHooks
        StratHooks hooks = new StratHooks();
        
        vm.stopBroadcast();
        
        // Log deployment address
        console.log("StratHooks deployed to:", address(hooks));
    }
}

