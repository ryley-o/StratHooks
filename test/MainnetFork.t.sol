// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {StratHooksV2} from "../src/StratHooksV2.sol";
import {StratHooks} from "../src/StratHooks.sol";
import {IPMPV0} from "../src/interfaces/IPMPV0.sol";
import {IGuardedEthTokenSwapper} from "../src/interfaces/IGuardedEthTokenSwapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

// Fork tests for mainnet integration. NOT run in CI - requires a mainnet fork.
// Run: forge test --match-contract MainnetForkTest -vvvv --fork-url $MAINNET_RPC_URL

// Purchase selector for MinterSlidingScaleV0 at 0x8c4ceA530b2Ff89d312F15A8DB38f04cDB5371d8 (from Etherscan)
bytes4 constant PURCHASE_SELECTOR = 0xae77c237;

// Minimal interface for Art Blocks shared minter (getPriceInfo)
interface ISharedMinter {
    function getPriceInfo(uint256 projectId, address coreContract)
        external
        view
        returns (bool isConfigured, uint256 tokenPriceInWei, string memory currencySymbol, address currencyAddress);
}

// Minimal interface for Art Blocks core contract (non-ERC721 functions)
interface IGenArt721CoreV3 {
    function projectStateData(uint256 projectId)
        external
        view
        returns (
            uint256 invocations,
            uint256 maxInvocations,
            bool active,
            bool paused,
            uint256 completedTimestamp,
            bool locked
        );

    function projectIdToArtistAddress(uint256 projectId) external view returns (address);
}

contract MainnetForkTest is Test {
    // ============================================
    // Deployed Mainnet Addresses
    // ============================================

    address constant STRAT_HOOKS_PROXY = 0x9a3f4307b1d12aeA5E2633e6e10Fb3cf9Ac81F9a;
    address constant CORE_CONTRACT = 0xaa00B2b2dB36B8F8004A9AA96F0012005D92B300;
    address constant MINTER_CONTRACT = 0x8c4ceA530b2Ff89d312F15A8DB38f04cDB5371d8;
    address constant ARTIST_WALLET = 0x2574c77a694700b7baB562fefeB9Ce93DB5A097A;
    address constant PMPV0_ADDRESS = 0x00000000A78E278b2d2e2935FaeBe19ee9F1FF14;
    address constant ADDITIONAL_PAYEE_RECEIVER = 0x27f798fCdD4414bf9545ACDdcE413D50cD4F379F;

    uint256 constant PROJECT_ID = 0;

    // Contracts (cast to interfaces)
    StratHooksV2 hooks;
    IGenArt721CoreV3 core;
    ISharedMinter minter;

    function setUp() public {
        hooks = StratHooksV2(STRAT_HOOKS_PROXY);
        core = IGenArt721CoreV3(CORE_CONTRACT);
        minter = ISharedMinter(MINTER_CONTRACT);
    }

    // ============================================
    // Test 1: Execute Mint 1 (TEMPORARY)
    // ============================================

    /// @notice TEMPORARY fork test to execute mint #1 from the artist wallet.
    /// @dev Run: forge test --match-test test_ExecuteMint1 -vvvv --fork-url $MAINNET_RPC_URL
    function test_ExecuteMint1() public {
        if (block.chainid != 1) {
            console.log("Skipping mainnet fork test - not on mainnet fork");
            return;
        }

        console.log("=== EXECUTE MINT 1 ===");
        console.log("");

        // --- Verify prerequisites ---
        (uint256 invocations, uint256 maxInvocations, bool active, bool paused,,) = core.projectStateData(PROJECT_ID);
        console.log("Current invocations:", invocations);
        console.log("Max invocations:", maxInvocations);
        console.log("Active:", active);
        console.log("Paused:", paused);

        require(active, "Project not active");
        // Note: project may be paused, but the artist can still mint while paused
        require(invocations == 1, "Expected exactly 1 invocation (mint 0 already done)");
        require(invocations < maxInvocations, "Project at max invocations");

        // Verify StratHooks state
        uint256 latestTokenBefore = hooks.latestReceivedTokenId();
        console.log("latestReceivedTokenId before:", latestTokenBefore);
        assertEq(latestTokenBefore, 0, "Only token 0 should exist");
        console.log("");

        // --- Query the current mint price from the sliding scale minter ---
        (, uint256 mintPrice,,) = minter.getPriceInfo(PROJECT_ID, CORE_CONTRACT);
        console.log("Current mint price (wei):", mintPrice);

        // --- Execute mint ---
        // Fund artist wallet with enough for mint + gas
        vm.deal(ARTIST_WALLET, mintPrice + 0.01 ether);

        vm.startPrank(ARTIST_WALLET);

        (bool success, bytes memory returnData) = address(MINTER_CONTRACT).call{value: mintPrice}(
            abi.encodeWithSelector(PURCHASE_SELECTOR, PROJECT_ID, CORE_CONTRACT)
        );

        require(success, "Mint transaction failed");
        uint256 mintedTokenId = abi.decode(returnData, (uint256));

        vm.stopPrank();

        // --- Verify mint result ---
        console.log("=== MINT RESULT ===");
        console.log("Minted token ID:", mintedTokenId);

        uint256 expectedTokenId = PROJECT_ID * 1_000_000 + 1;
        assertEq(mintedTokenId, expectedTokenId, "Minted token ID should be 1");

        // Verify StratHooks received funds
        uint256 latestTokenAfter = hooks.latestReceivedTokenId();
        assertEq(latestTokenAfter, expectedTokenId, "StratHooks should have received funds for token 1");
        console.log("latestReceivedTokenId after:", latestTokenAfter);

        // Verify token metadata was created
        (
            StratHooks.TokenType tokenType,
            uint256 tokenBalance,
            uint128 createdAt,
            uint32 intervalLengthSeconds,
            bool isWithdrawn,
        ) = hooks.tokenMetadata(mintedTokenId);

        console.log("");
        console.log("=== TOKEN 1 METADATA ===");
        console.log("Token type:", uint256(tokenType));
        console.log("Token symbol:", _getTokenSymbol(tokenType));
        console.log("Token balance:", tokenBalance);
        console.log("Created at:", uint256(createdAt));
        console.log("Interval length (seconds):", uint256(intervalLengthSeconds));
        console.log("Is withdrawn:", isWithdrawn);

        assertGt(tokenBalance, 0, "Token balance should be > 0");
        assertEq(uint256(createdAt), block.timestamp, "Created at should be current block timestamp");
        assertGt(intervalLengthSeconds, 0, "Interval length should be > 0");
        assertFalse(isWithdrawn, "Token should not be withdrawn");

        // Verify token owner
        address tokenOwner = IERC721(CORE_CONTRACT).ownerOf(mintedTokenId);
        assertEq(tokenOwner, ARTIST_WALLET, "Token owner should be artist wallet");
        console.log("Token owner:", tokenOwner);

        // Verify invocations incremented
        (uint256 invocationsAfter,,,,,) = core.projectStateData(PROJECT_ID);
        assertEq(invocationsAfter, 2, "Invocations should be 2 after mint");

        console.log("");
        console.log("=== MINT 1 COMPLETE ===");
    }

    // ============================================
    // Test 2: Follow Token 0 Through Time
    // ============================================

    /// @notice Fork test that simulates token 0's full lifecycle:
    ///         all keeper check-in rounds followed by ERC20 withdrawal via PMPV0.
    /// @dev Run: forge test --match-test test_FollowToken0ThroughTime -vvvv --fork-url $MAINNET_RPC_URL
    function test_FollowToken0ThroughTime() public {
        if (block.chainid != 1) {
            console.log("Skipping mainnet fork test - not on mainnet fork");
            return;
        }

        console.log("=== FOLLOW TOKEN 0 THROUGH TIME ===");
        console.log("");

        uint256 token0Id = PROJECT_ID * 1_000_000; // token 0

        // Step 1: Read token 0 metadata & verify state
        _logAndVerifyToken0State(token0Id);

        // Step 2+3: Simulate all keeper rounds, then verify completion
        (StratHooks.TokenType tokenType, uint256 tokenBalance, uint128 createdAt, uint32 intervalLengthSeconds,,) =
            hooks.tokenMetadata(token0Id);
        _simulateKeeperRoundsAndVerifyCompletion(token0Id, tokenType, createdAt, intervalLengthSeconds);

        // Step 4: Test withdrawal via PMPV0
        _testWithdrawalViaPMPV0(token0Id, tokenType, tokenBalance);

        console.log("");
        console.log("=== TOKEN 0 FULL LIFECYCLE COMPLETE ===");
    }

    /// @dev Step 1: Log token 0 initial state and verify prerequisites
    function _logAndVerifyToken0State(uint256 token0Id) internal view {
        (
            StratHooks.TokenType tokenType,
            uint256 tokenBalance,
            uint128 createdAt,
            uint32 intervalLengthSeconds,
            bool isWithdrawn,
        ) = hooks.tokenMetadata(token0Id);

        console.log("--- TOKEN 0 INITIAL STATE ---");
        console.log("Token type:", uint256(tokenType), _getTokenSymbol(tokenType));
        console.log("Token balance:", tokenBalance);
        console.log("Created at:", uint256(createdAt));
        console.log("Interval length (seconds):", uint256(intervalLengthSeconds));
        console.log("Total lifecycle (seconds):", uint256(intervalLengthSeconds) * 11);
        console.log("Is withdrawn:", isWithdrawn);
        console.log("");

        require(createdAt != 0, "Token 0 not initialized");
        require(!isWithdrawn, "Token 0 already withdrawn");

        console.log("Keeper address:", hooks.keeper());

        // Verify StratHooks proxy holds the ERC20 tokens from the original swap
        address tokenAddress = _getTokenAddress(tokenType);
        uint256 hooksERC20Balance = IERC20(tokenAddress).balanceOf(STRAT_HOOKS_PROXY);
        console.log("StratHooks ERC20 balance for", _getTokenSymbol(tokenType), ":", hooksERC20Balance);
        require(hooksERC20Balance >= tokenBalance, "StratHooks should hold at least token 0's balance");
        console.log("");
    }

    /// @dev Step 2+3: Simulate keeper calls for all remaining rounds and verify completion
    function _simulateKeeperRoundsAndVerifyCompletion(
        uint256 token0Id,
        StratHooks.TokenType tokenType,
        uint128 createdAt,
        uint32 intervalLengthSeconds
    ) internal {
        // After V2 repair, token 0 has priceHistory.length = 1 (round 0).
        // We need 11 more keeper calls (rounds 1-11) to reach 12 total entries.
        // If some rounds were already completed on mainnet, those are skipped.
        console.log("--- SIMULATING KEEPER ROUNDS ---");

        // Snapshot the current oracle price while it's still fresh (before time-warping).
        // Then mock getTokenPrice on the swapper so performUpkeep doesn't revert with a
        // stale-price error when we warp far into the future.
        IGuardedEthTokenSwapper swapper = hooks.guardedEthTokenSwapper();
        address tokenAddress = _getTokenAddress(tokenType);
        (uint256 currentPrice, uint8 priceDecimals) = swapper.getTokenPrice(tokenAddress);
        console.log("Snapshotted oracle price:", currentPrice);
        console.log("Oracle price decimals:", uint256(priceDecimals));

        vm.mockCall(
            address(swapper),
            abi.encodeWithSelector(IGuardedEthTokenSwapper.getTokenPrice.selector),
            abi.encode(currentPrice, priceDecimals)
        );

        address keeperAddress = hooks.keeper();
        uint256 roundsPerformed = 0;

        for (uint256 round = 1; round < 12; round++) {
            // Warp to 1 second past when this round becomes eligible
            uint256 roundTime = uint256(createdAt) + uint256(intervalLengthSeconds) * round + 1;
            vm.warp(roundTime);

            // Check if upkeep is needed
            (bool upkeepNeeded, bytes memory performData) = hooks.checkUpkeep("");

            if (!upkeepNeeded) {
                // Token 0 already completed this round (done on mainnet), skip
                console.log("Round", round, "- skipped (already completed)");
                continue;
            }

            (uint256 returnedTokenId, uint256 returnedRound) = abi.decode(performData, (uint256, uint256));

            if (returnedTokenId != token0Id) {
                // checkUpkeep returned a different token; token 0 is already past this round
                console.log("Round", round, "- skipped (token 0 not returned by checkUpkeep)");
                continue;
            }

            console.log("Round", returnedRound, "- performing upkeep at timestamp", roundTime);

            // Verify checkUpkeep returned the expected round
            assertEq(returnedRound, round, "checkUpkeep round should match expected round");

            // Perform upkeep as the keeper
            vm.prank(keeperAddress);
            hooks.performUpkeep(performData);

            roundsPerformed++;
        }

        console.log("");
        console.log("Total keeper rounds performed:", roundsPerformed);

        // Verify token is complete
        console.log("");
        console.log("--- VERIFYING COMPLETION ---");

        // Warp well past all intervals to confirm no more upkeep is needed
        vm.warp(uint256(createdAt) + uint256(intervalLengthSeconds) * 20);

        (bool finalUpkeepNeeded,) = hooks.checkUpkeep("");
        assertFalse(finalUpkeepNeeded, "No upkeep should be needed - token 0 is complete (12 entries)");
        console.log("checkUpkeep returns false: token 0 lifecycle complete (12 price history entries)");
    }

    /// @dev Step 4: Test withdrawal via PMPV0 and verify ERC20 transfer
    function _testWithdrawalViaPMPV0(
        uint256 token0Id,
        StratHooks.TokenType tokenType,
        uint256 tokenBalance
    ) internal {
        console.log("");
        console.log("--- TESTING WITHDRAWAL VIA PMPV0 ---");

        address tokenAddress = _getTokenAddress(tokenType);
        address tokenOwner = IERC721(CORE_CONTRACT).ownerOf(token0Id);
        console.log("Token 0 owner:", tokenOwner);

        // Record ERC20 balances before withdrawal
        uint256 ownerBalanceBefore = IERC20(tokenAddress).balanceOf(tokenOwner);
        uint256 hooksBalanceBefore = IERC20(tokenAddress).balanceOf(STRAT_HOOKS_PROXY);
        console.log("Owner ERC20 balance before:", ownerBalanceBefore);
        console.log("StratHooks ERC20 balance before:", hooksBalanceBefore);

        // Create the PMP input to set IsWithdrawn = true
        IPMPV0.PMPInput[] memory inputs = _buildWithdrawalInput();

        // Call configureTokenParams on PMPV0 as the token owner
        // PMPV0 validates ownership, stores the value, then calls onTokenPMPConfigure on StratHooks
        // which triggers the ERC20 transfer to the token owner
        vm.prank(tokenOwner);
        IPMPV0(PMPV0_ADDRESS).configureTokenParams(CORE_CONTRACT, token0Id, inputs);

        // Verify withdrawal state on StratHooks
        (,,,, bool isWithdrawnAfter, uint128 withdrawnAtAfter) = hooks.tokenMetadata(token0Id);
        assertTrue(isWithdrawnAfter, "Token 0 should be marked as withdrawn");
        assertGt(withdrawnAtAfter, 0, "withdrawnAt timestamp should be set");
        console.log("");
        console.log("isWithdrawn:", isWithdrawnAfter);
        console.log("withdrawnAt:", uint256(withdrawnAtAfter));

        // Verify ERC20 tokens were transferred to the token owner
        uint256 ownerBalanceAfter = IERC20(tokenAddress).balanceOf(tokenOwner);
        uint256 hooksBalanceAfter = IERC20(tokenAddress).balanceOf(STRAT_HOOKS_PROXY);
        uint256 tokensReceived = ownerBalanceAfter - ownerBalanceBefore;

        assertEq(tokensReceived, tokenBalance, "Owner should receive the full token balance");
        assertEq(
            hooksBalanceBefore - hooksBalanceAfter, tokenBalance, "StratHooks balance should decrease by token balance"
        );

        console.log("Owner ERC20 balance after:", ownerBalanceAfter);
        console.log("Tokens received:", tokensReceived);
        console.log("StratHooks ERC20 balance after:", hooksBalanceAfter);

        // Verify double-withdrawal is prevented
        vm.prank(tokenOwner);
        vm.expectRevert("Token already withdrawn");
        IPMPV0(PMPV0_ADDRESS).configureTokenParams(CORE_CONTRACT, token0Id, inputs);
        console.log("Double-withdrawal correctly reverted");
    }

    /// @dev Build the PMPInput array for an IsWithdrawn = true withdrawal
    function _buildWithdrawalInput() internal pure returns (IPMPV0.PMPInput[] memory inputs) {
        inputs = new IPMPV0.PMPInput[](1);
        inputs[0] = IPMPV0.PMPInput({
            key: "IsWithdrawn",
            configuredParamType: IPMPV0.ParamType.Bool,
            configuredValue: bytes32(uint256(1)), // true
            configuringArtistString: false,
            configuredValueString: ""
        });
    }

    // ============================================
    // Helper Functions
    // ============================================

    /// @notice Get the mainnet ERC20 token address for a given token type
    function _getTokenAddress(StratHooks.TokenType tokenType) internal pure returns (address) {
        if (tokenType == StratHooks.TokenType.ONEINCH) return 0x111111111117dC0aa78b770fA6A738034120C302;
        if (tokenType == StratHooks.TokenType.AAVE) return 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
        if (tokenType == StratHooks.TokenType.APE) return 0x4d224452801ACEd8B2F0aebE155379bb5D594381;
        if (tokenType == StratHooks.TokenType.BAT) return 0x0D8775F648430679A709E98d2b0Cb6250d2887EF;
        if (tokenType == StratHooks.TokenType.COMP) return 0xc00e94Cb662C3520282E6f5717214004A7f26888;
        if (tokenType == StratHooks.TokenType.CRV) return 0xD533a949740bb3306d119CC777fa900bA034cd52;
        if (tokenType == StratHooks.TokenType.USDT) return 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        if (tokenType == StratHooks.TokenType.LDO) return 0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32;
        if (tokenType == StratHooks.TokenType.LINK) return 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        if (tokenType == StratHooks.TokenType.MKR) return 0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2;
        if (tokenType == StratHooks.TokenType.SHIB) return 0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE;
        if (tokenType == StratHooks.TokenType.UNI) return 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
        if (tokenType == StratHooks.TokenType.WBTC) return 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        if (tokenType == StratHooks.TokenType.ZRX) return 0xE41d2489571d322189246DaFA5ebDe1F4699F498;
        revert("Invalid token type");
    }

    /// @notice Get the token symbol string for a given token type
    function _getTokenSymbol(StratHooks.TokenType tokenType) internal pure returns (string memory) {
        if (tokenType == StratHooks.TokenType.ONEINCH) return "1INCH";
        if (tokenType == StratHooks.TokenType.AAVE) return "AAVE";
        if (tokenType == StratHooks.TokenType.APE) return "APE";
        if (tokenType == StratHooks.TokenType.BAT) return "BAT";
        if (tokenType == StratHooks.TokenType.COMP) return "COMP";
        if (tokenType == StratHooks.TokenType.CRV) return "CRV";
        if (tokenType == StratHooks.TokenType.USDT) return "USDT";
        if (tokenType == StratHooks.TokenType.LDO) return "LDO";
        if (tokenType == StratHooks.TokenType.LINK) return "LINK";
        if (tokenType == StratHooks.TokenType.MKR) return "MKR";
        if (tokenType == StratHooks.TokenType.SHIB) return "SHIB";
        if (tokenType == StratHooks.TokenType.UNI) return "UNI";
        if (tokenType == StratHooks.TokenType.WBTC) return "WBTC";
        if (tokenType == StratHooks.TokenType.ZRX) return "ZRX";
        revert("Invalid token type");
    }
}
