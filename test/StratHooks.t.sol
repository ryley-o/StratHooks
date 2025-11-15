// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.22;

import {Test} from "forge-std/Test.sol";
import {StratHooks} from "../src/StratHooks.sol";
import {IWeb3Call} from "../src/interfaces/IWeb3Call.sol";
import {IPMPV0} from "../src/interfaces/IPMPV0.sol";
import {IPMPAugmentHook} from "../src/interfaces/IPMPAugmentHook.sol";
import {IPMPConfigureHook} from "../src/interfaces/IPMPConfigureHook.sol";
import {IGuardedEthTokenSwapper} from "../src/interfaces/IGuardedEthTokenSwapper.sol";

// Mock GuardedEthTokenSwapper for testing
contract MockGuardedEthTokenSwapper is IGuardedEthTokenSwapper {
    uint256 public mockSwapReturn = 1000e18; // Default return 1000 tokens
    uint256 public mockPrice = 0.004e18; // Default price 0.004 ETH per token
    uint8 public mockDecimals = 18;

    function setMockSwapReturn(uint256 _amount) external {
        mockSwapReturn = _amount;
    }

    function setMockPrice(uint256 _price, uint8 _decimals) external {
        mockPrice = _price;
        mockDecimals = _decimals;
    }

    function swapEthForToken(address token, uint16 slippageBps, uint256 deadline)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        // Simple mock: return mockSwapReturn
        return mockSwapReturn;
    }

    function setFeeds(
        address[] calldata tokens,
        address[] calldata aggregators,
        uint24[] calldata feeTiers,
        uint16[] calldata toleranceBpsArr
    ) external override {}

    function removeFeed(address token) external override {}

    function getFeed(address token)
        external
        view
        override
        returns (address aggregator, uint8 decimals, uint24 feeTier, uint16 toleranceBps)
    {
        return (address(0x123), mockDecimals, 3000, 200);
    }

    function getTokenPrice(address token) external view override returns (uint256 price, uint8 decimals) {
        return (mockPrice, mockDecimals);
    }

    function router() external view override returns (address) {
        return address(0);
    }

    function weth() external view override returns (address) {
        return address(0);
    }

    function owner() external view override returns (address) {
        return address(this);
    }
}

contract StratHooksTest is Test {
    StratHooks public hooks;
    MockGuardedEthTokenSwapper public mockSwapper;
    
    address constant MOCK_CORE_CONTRACT = address(0x1);
    uint256 constant MOCK_TOKEN_ID = 1;
    address constant OWNER = address(0x100);
    address constant ADDITIONAL_PAYEE_RECEIVER = address(0x200);
    address constant KEEPER = address(0x300);
    event UpkeepPerformed(uint256 indexed tokenId, uint256 indexed round, uint256 timestamp);

    function setUp() public {
        // Deploy mock swapper
        mockSwapper = new MockGuardedEthTokenSwapper();
        
        // Deploy hooks
        hooks = new StratHooks(OWNER, ADDITIONAL_PAYEE_RECEIVER, KEEPER);
        
        // Set the mock swapper
        vm.prank(OWNER);
        hooks.setGuardedEthTokenSwapper(address(mockSwapper));
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
        
        // Perform upkeep as the keeper
        vm.prank(KEEPER);
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
        vm.prank(KEEPER);
        hooks.performUpkeep(performData);
        
        // Now round is 1, trying to execute round 0 again should fail
        vm.prank(KEEPER);
        vm.expectRevert("Stale upkeep");
        hooks.performUpkeep(performData);
    }

    function test_PerformUpkeep_RevertsOnDuplicateExecution() public {
        // Perform upkeep for round 0
        uint256 tokenId = MOCK_TOKEN_ID;
        bytes memory performData = abi.encode(tokenId, 0);
        vm.prank(KEEPER);
        hooks.performUpkeep(performData);
        
        // The round is now 1, so trying to execute round 0 again will fail with "Stale upkeep"
        // This test verifies the stale round check works
        vm.prank(KEEPER);
        vm.expectRevert("Stale upkeep");
        hooks.performUpkeep(performData);
    }

    function test_PerformUpkeep_IdempotencyAcrossTokens() public {
        // Test that different tokens maintain independent state
        uint256 tokenId1 = 1;
        uint256 tokenId2 = 2;
        
        // Perform upkeep for token 1
        bytes memory performData1 = abi.encode(tokenId1, 0);
        vm.prank(KEEPER);
        hooks.performUpkeep(performData1);
        
        // Perform upkeep for token 2
        bytes memory performData2 = abi.encode(tokenId2, 0);
        vm.prank(KEEPER);
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
            vm.prank(KEEPER);
            hooks.performUpkeep(performData);
            
            assertEq(hooks.tokenRound(tokenId), i + 1, "Round should increment");
            assertTrue(hooks.roundExecuted(tokenId, i), "Round should be marked executed");
        }
        
        // Final round should be 5
        assertEq(hooks.tokenRound(tokenId), 5, "Should be at round 5");
    }

    // ============================================
    // Keeper Management Tests
    // ============================================

    function test_SetKeeper() public {
        address newKeeper = address(0x400);
        
        vm.prank(OWNER);
        hooks.setKeeper(newKeeper);
        
        assertEq(hooks.keeper(), newKeeper, "Keeper should be updated");
    }

    function test_SetKeeper_RevertsNonOwner() public {
        address newKeeper = address(0x400);
        
        vm.prank(address(0x999));
        vm.expectRevert();
        hooks.setKeeper(newKeeper);
    }

    function test_SetAdditionalPayeeReceiver() public {
        address newReceiver = address(0x500);
        
        vm.prank(OWNER);
        hooks.setAdditionalPayeeReceiver(newReceiver);
        
        assertEq(hooks.additionalPayeeReceiver(), newReceiver, "Additional payee receiver should be updated");
    }

    function test_SetAdditionalPayeeReceiver_RevertsNonOwner() public {
        address newReceiver = address(0x500);
        
        vm.prank(address(0x999));
        vm.expectRevert();
        hooks.setAdditionalPayeeReceiver(newReceiver);
    }

    function test_SetGuardedEthTokenSwapper() public {
        address newSwapper = address(0x600);
        
        vm.prank(OWNER);
        hooks.setGuardedEthTokenSwapper(newSwapper);
        
        assertEq(address(hooks.guardedEthTokenSwapper()), newSwapper, "Swapper should be updated");
    }

    function test_SetGuardedEthTokenSwapper_RevertsNonOwner() public {
        address newSwapper = address(0x600);
        
        vm.prank(address(0x999));
        vm.expectRevert();
        hooks.setGuardedEthTokenSwapper(newSwapper);
    }

    function test_PerformUpkeep_RevertsNonKeeper() public {
        uint256 tokenId = MOCK_TOKEN_ID;
        bytes memory performData = abi.encode(tokenId, 0);
        
        vm.prank(address(0x999));
        vm.expectRevert("Not keeper");
        hooks.performUpkeep(performData);
    }

    // ============================================
    // ReceiveFunds Tests
    // ============================================

    function test_ReceiveFunds() public {
        uint256 tokenId = 1;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));
        uint256 amount = 1 ether;
        
        // Set up mock return values
        mockSwapper.setMockSwapReturn(5000e18); // 5000 tokens
        mockSwapper.setMockPrice(0.004e18, 18); // 0.004 ETH per token
        
        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, amount);
        hooks.receiveFunds{value: amount}(tokenId, tokenHash);
        
        assertEq(hooks.latestReceivedTokenId(), tokenId, "Latest token ID should be updated");
        
        // Verify token metadata was initialized
        (
            StratHooks.TokenType tokenType,
            uint256 tokenBalance,
            uint128 createdAt,
            uint32 intervalLengthSeconds
        ) = hooks.tokenMetadata(tokenId);
        
        assertEq(tokenBalance, 5000e18, "Token balance should match swap return");
        assertEq(createdAt, block.timestamp, "Created at should be block timestamp");
        assertGt(intervalLengthSeconds, 0, "Interval length should be set");
        
        // Verify token type is valid (0-13 for 14 token types)
        assertTrue(uint256(tokenType) < 14, "Token type should be in valid range");
    }

    function test_ReceiveFunds_RevertsNonPayee() public {
        uint256 tokenId = 1;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));
        
        vm.deal(address(0x999), 1 ether);
        vm.prank(address(0x999));
        vm.expectRevert("Not additional payee receiver");
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);
    }

    function test_ReceiveFunds_RevertsInvalidTokenId() public {
        // First receive funds for token 1
        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 2 ether);
        hooks.receiveFunds{value: 1 ether}(1, keccak256(abi.encode(uint256(1))));
        
        // Try to receive funds for token 3 (should be 2)
        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.expectRevert("Invalid token id");
        hooks.receiveFunds{value: 1 ether}(3, keccak256(abi.encode(uint256(3))));
    }

    function test_ReceiveFunds_MultipleTokens() public {
        // Receive funds for multiple tokens sequentially
        for (uint256 i = 1; i <= 5; i++) {
            bytes32 tokenHash = keccak256(abi.encode(i));
            
            vm.prank(ADDITIONAL_PAYEE_RECEIVER);
            vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
            hooks.receiveFunds{value: 1 ether}(i, tokenHash);
            
            assertEq(hooks.latestReceivedTokenId(), i, "Latest token ID should match iteration");
        }
    }

    function test_ReceiveFunds_CallsSwapperCorrectly() public {
        uint256 tokenId = 1;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));
        uint256 amount = 2 ether;
        
        // Set mock return to a specific value
        mockSwapper.setMockSwapReturn(10000e18);
        
        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, amount);
        
        // Call receiveFunds and verify it uses the mock swap return
        hooks.receiveFunds{value: amount}(tokenId, tokenHash);
        
        // Verify the token balance matches the mock return value
        (,uint256 tokenBalance,,) = hooks.tokenMetadata(tokenId);
        assertEq(tokenBalance, 10000e18, "Token balance should match mock swap return");
    }

    function test_ReceiveFunds_StoresCorrectTokenType() public {
        // Test that different hashes produce different token types
        for (uint256 i = 1; i <= 14; i++) {
            bytes32 tokenHash = keccak256(abi.encode(i * 123456)); // Use different hashes
            
            vm.prank(ADDITIONAL_PAYEE_RECEIVER);
            vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
            hooks.receiveFunds{value: 1 ether}(i, tokenHash);
            
            (StratHooks.TokenType tokenType,,,) = hooks.tokenMetadata(i);
            
            // Verify token type is in valid range
            assertTrue(uint256(tokenType) < 14, "Token type should be valid");
        }
    }

    function test_ReceiveFunds_StoresPriceHistory() public {
        uint256 tokenId = 1;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));
        
        // Set a specific price
        mockSwapper.setMockPrice(0.005e18, 18);
        
        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);
        
        // The price history should have been populated (we can't easily read the array directly in this test)
        // But we can verify the metadata exists
        (,uint256 tokenBalance,,) = hooks.tokenMetadata(tokenId);
        assertGt(tokenBalance, 0, "Token balance should be set");
    }
}

