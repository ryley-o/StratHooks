// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.22;

import {Test} from "forge-std/Test.sol";
import {StratHooks} from "../src/StratHooks.sol";
import {IWeb3Call} from "../src/interfaces/IWeb3Call.sol";
import {IPMPV0} from "../src/interfaces/IPMPV0.sol";
import {IPMPAugmentHook} from "../src/interfaces/IPMPAugmentHook.sol";
import {IPMPConfigureHook} from "../src/interfaces/IPMPConfigureHook.sol";

contract StratHooksTest is Test {
    StratHooks public hooks;
    
    address constant MOCK_CORE_CONTRACT = address(0x1);
    uint256 constant MOCK_TOKEN_ID = 1;

    function setUp() public {
        hooks = new StratHooks();
    }

    function test_SupportsInterfaces() public view {
        // Test that the contract supports the expected interfaces
        assertTrue(hooks.supportsInterface(type(IPMPAugmentHook).interfaceId));
        assertTrue(hooks.supportsInterface(type(IPMPConfigureHook).interfaceId));
    }

    function test_OnTokenPMPConfigure() public view {
        // Test basic configure hook functionality
        IPMPV0.PMPInput memory input = IPMPV0.PMPInput({
            key: "test-key",
            configuredParamType: IPMPV0.ParamType.Uint256Range,
            configuredValue: bytes32(uint256(42)),
            configuringArtistString: false,
            configuredValueString: ""
        });

        // Should not revert with default implementation
        hooks.onTokenPMPConfigure(MOCK_CORE_CONTRACT, MOCK_TOKEN_ID, input);
    }

    function test_OnTokenPMPReadAugmentation() public view {
        // Test basic augmentation hook functionality
        IWeb3Call.TokenParam[] memory params = new IWeb3Call.TokenParam[](1);
        params[0] = IWeb3Call.TokenParam({
            key: "test-key",
            value: "test-value"
        });

        IWeb3Call.TokenParam[] memory augmented = hooks.onTokenPMPReadAugmentation(
            MOCK_CORE_CONTRACT,
            MOCK_TOKEN_ID,
            params
        );

        // With default implementation, should return same params
        assertEq(augmented.length, params.length);
        assertEq(augmented[0].key, params[0].key);
        assertEq(augmented[0].value, params[0].value);
    }
}

