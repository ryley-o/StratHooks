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
    address constant OWNER = address(0x100);
    address constant ADDITIONAL_PAYEE_RECEIVER = address(0x200);

    event UpkeepPerformed(uint256 indexed tokenId, uint256 indexed round, uint256 timestamp);

    function setUp() public {
        hooks = new StratHooks(OWNER, ADDITIONAL_PAYEE_RECEIVER);
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

    // ============================================
    // Chainlink Automation Tests
    // ============================================

    function test_CheckUpkeep_DefaultReturnsFalse() public view {
        // With default implementation, checkUpkeep should return false
        bytes memory checkData = abi.encode(MOCK_TOKEN_ID);
        
        (bool upkeepNeeded, bytes memory performData) = hooks.checkUpkeep(checkData);
        
        assertFalse(upkeepNeeded, "Upkeep should not be needed by default");
        assertEq(performData.length, 0, "PerformData should be empty when upkeep not needed");
    }

    function test_CheckUpkeep_DecodesTokenId() public view {
        // Verify that checkUpkeep can decode the tokenId
        uint256 testTokenId = 12345;
        bytes memory checkData = abi.encode(testTokenId);
        
        // This should not revert
        hooks.checkUpkeep(checkData);
    }

    function test_PerformUpkeep_ExecutesAndEmitsEvent() public {
        // Setup: manually set up state as if checkUpkeep returned true
        uint256 tokenId = MOCK_TOKEN_ID;
        uint256 round = 0;
        
        bytes memory performData = abi.encode(tokenId, round);
        
        // Expect the UpkeepPerformed event
        vm.expectEmit(true, true, false, true);
        emit UpkeepPerformed(tokenId, round, block.timestamp);
        
        // Perform upkeep
        hooks.performUpkeep(performData);
        
        // Verify state changes
        assertEq(hooks.tokenRound(tokenId), 1, "Round should be incremented");
        assertEq(hooks.lastUpkeepTimestamp(tokenId), block.timestamp, "Timestamp should be updated");
        assertTrue(hooks.roundExecuted(tokenId, round), "Round should be marked as executed");
    }

    function test_PerformUpkeep_RevertsOnStaleRound() public {
        // First perform upkeep for round 0
        uint256 tokenId = MOCK_TOKEN_ID;
        bytes memory performData = abi.encode(tokenId, 0);
        hooks.performUpkeep(performData);
        
        // Now round is 1, trying to execute round 0 again should fail
        vm.expectRevert("Stale upkeep");
        hooks.performUpkeep(performData);
    }

    function test_PerformUpkeep_RevertsOnDuplicateExecution() public {
        // Perform upkeep for round 0
        uint256 tokenId = MOCK_TOKEN_ID;
        bytes memory performData = abi.encode(tokenId, 0);
        hooks.performUpkeep(performData);
        
        // Manually reset the round to 0 to simulate duplicate execution attempt
        // Note: This is just for testing; in practice the "Stale upkeep" would trigger first
        vm.store(
            address(hooks),
            keccak256(abi.encode(tokenId, uint256(0))), // tokenRound slot
            bytes32(uint256(0))
        );
        
        // Should revert because round 0 is already executed
        vm.expectRevert("Round already executed");
        hooks.performUpkeep(performData);
    }

    function test_PerformUpkeep_IdempotencyAcrossTokens() public {
        // Test that different tokens maintain independent state
        uint256 tokenId1 = 1;
        uint256 tokenId2 = 2;
        
        // Perform upkeep for token 1
        bytes memory performData1 = abi.encode(tokenId1, 0);
        hooks.performUpkeep(performData1);
        
        // Perform upkeep for token 2
        bytes memory performData2 = abi.encode(tokenId2, 0);
        hooks.performUpkeep(performData2);
        
        // Verify both tokens have independent state
        assertEq(hooks.tokenRound(tokenId1), 1, "Token 1 should be at round 1");
        assertEq(hooks.tokenRound(tokenId2), 1, "Token 2 should be at round 1");
        assertTrue(hooks.roundExecuted(tokenId1, 0), "Token 1 round 0 should be executed");
        assertTrue(hooks.roundExecuted(tokenId2, 0), "Token 2 round 0 should be executed");
    }

    function test_PerformUpkeep_MultipleRounds() public {
        uint256 tokenId = MOCK_TOKEN_ID;
        
        // Execute multiple rounds
        for (uint256 i = 0; i < 5; i++) {
            bytes memory performData = abi.encode(tokenId, i);
            hooks.performUpkeep(performData);
            
            assertEq(hooks.tokenRound(tokenId), i + 1, "Round should increment");
            assertTrue(hooks.roundExecuted(tokenId, i), "Round should be marked executed");
        }
        
        // Final round should be 5
        assertEq(hooks.tokenRound(tokenId), 5, "Should be at round 5");
    }
}

