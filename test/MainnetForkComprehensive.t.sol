// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {StratHooksV2} from "../src/StratHooksV2.sol";
import {StratHooks} from "../src/StratHooks.sol";
import {IPMPV0} from "../src/interfaces/IPMPV0.sol";
import {IGuardedEthTokenSwapper} from "../src/interfaces/IGuardedEthTokenSwapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

// Comprehensive fork test: mints until all 13 non-BAT token types are covered,
// then runs price checkins and withdrawals on one representative per type.
// Run: forge test --match-contract MainnetForkComprehensiveTest -vvvv --fork-url $MAINNET_RPC_URL

// Purchase selector for MinterSlidingScaleV0
bytes4 constant PURCHASE_SELECTOR = 0xae77c237;

uint256 constant NUM_TOKEN_TYPES = 14; // enum has 14 entries (0-13)
uint256 constant NUM_VALID_TYPES = 13; // 14 minus BAT
uint256 constant BAT_TYPE_INDEX = 3; // StratHooks.TokenType.BAT

// Minimal interface for Art Blocks shared minter (getPriceInfo)
interface ISharedMinter {
    function getPriceInfo(uint256 projectId, address coreContract)
        external
        view
        returns (bool isConfigured, uint256 tokenPriceInWei, string memory currencySymbol, address currencyAddress);
}

// Minimal interface for Art Blocks core contract
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

contract MainnetForkComprehensiveTest is Test {
    // ============================================
    // Deployed Mainnet Addresses
    // ============================================

    address constant STRAT_HOOKS_PROXY = 0x9a3f4307b1d12aeA5E2633e6e10Fb3cf9Ac81F9a;
    address constant CORE_CONTRACT = 0xaa00B2b2dB36B8F8004A9AA96F0012005D92B300;
    address constant MINTER_CONTRACT = 0x8c4ceA530b2Ff89d312F15A8DB38f04cDB5371d8;
    address constant ARTIST_WALLET = 0x2574c77a694700b7baB562fefeB9Ce93DB5A097A;
    address constant PMPV0_ADDRESS = 0x00000000A78E278b2d2e2935FaeBe19ee9F1FF14;

    uint256 constant PROJECT_ID = 0;
    uint256 constant MAX_MINTS_SAFETY = 100; // safety cap for the minting loop

    // Contracts
    StratHooksV2 hooks;
    IGenArt721CoreV3 core;
    ISharedMinter minter;

    function setUp() public {
        hooks = StratHooksV2(STRAT_HOOKS_PROXY);
        core = IGenArt721CoreV3(CORE_CONTRACT);
        minter = ISharedMinter(MINTER_CONTRACT);
    }

    // ============================================
    // Comprehensive End-to-End Test
    // ============================================

    /// @notice Mints until all 13 non-BAT token types are covered, then runs
    ///         price checkins and withdrawals on one representative per type.
    /// @dev Run: forge test --match-test test_FullCoverage_PriceCheckins_Withdrawals -vvvv --fork-url $MAINNET_RPC_URL
    function test_FullCoverage_PriceCheckins_Withdrawals() public {
        if (block.chainid != 1) {
            console.log("Skipping mainnet fork test - not on mainnet fork");
            return;
        }

        console.log("============================================================");
        console.log("  COMPREHENSIVE FORK TEST: FULL TYPE COVERAGE");
        console.log("============================================================");
        console.log("");

        // ====== PHASE 1: MINT UNTIL ALL 13 TYPES COVERED ======
        console.log("====== PHASE 1: MINT UNTIL ALL 13 TOKEN TYPES COVERED ======");
        console.log("");

        uint256[] memory selectedTokenIds = _mintUntilAllTypesCovered();

        // ====== PHASE 2: VERIFY SELECTED TOKEN METADATA ======
        console.log("");
        console.log("====== PHASE 2: VERIFY 13 REPRESENTATIVE TOKENS ======");
        console.log("");

        _verifySelectedTokenMetadata(selectedTokenIds);

        // ====== PHASE 3: PRICE CHECKINS ON 13 REPRESENTATIVES ======
        console.log("");
        console.log("====== PHASE 3: EXECUTE ALL 12 PRICE CHECKINS PER TYPE ======");
        console.log("");

        _executePriceCheckinsForSelected(selectedTokenIds);

        // ====== PHASE 4: WITHDRAW 13 REPRESENTATIVES ======
        console.log("");
        console.log("====== PHASE 4: WITHDRAW ALL 13 REPRESENTATIVE TOKENS ======");
        console.log("");

        _executeWithdrawalsForSelected(selectedTokenIds);

        console.log("");
        console.log("============================================================");
        console.log("  ALL PHASES COMPLETE - FULL TYPE COVERAGE TEST PASSED");
        console.log("============================================================");
    }

    // ============================================
    // Phase 1: Mint Until All 13 Types Covered
    // ============================================

    /// @dev Mint via the real purchase flow until at least one token of each
    ///      of the 13 non-BAT types exists. Returns an array of 13 representative
    ///      token IDs (one per type, ordered by enum value, skipping BAT).
    function _mintUntilAllTypesCovered() internal returns (uint256[] memory selectedTokenIds) {
        // Tracking arrays (indexed by TokenType enum value 0-13)
        bool[NUM_TOKEN_TYPES] memory typesSeen;
        uint256[NUM_TOKEN_TYPES] memory firstTokenOfType;
        uint256 uniqueTypes = 0;

        // --- Scan tokens that already exist on mainnet ---
        (uint256 invocations, , bool active, , , ) = core.projectStateData(PROJECT_ID);
        require(active, "Project not active");
        console.log("Existing invocations on mainnet:", invocations);

        for (uint256 i = 0; i < invocations; i++) {
            uint256 tokenId = PROJECT_ID * 1_000_000 + i;
            (StratHooks.TokenType tokenType, , , , , ) = hooks.tokenMetadata(tokenId);
            uint256 typeIdx = uint256(tokenType);
            if (!typesSeen[typeIdx] && typeIdx != BAT_TYPE_INDEX) {
                typesSeen[typeIdx] = true;
                firstTokenOfType[typeIdx] = tokenId;
                uniqueTypes++;
                console.log(
                    string.concat("  Existing token ", vm.toString(tokenId), " -> ", _getTokenSymbol(tokenType))
                );
            }
        }
        console.log("Unique types from existing tokens:", uniqueTypes);
        console.log("");

        // --- Mint new tokens until all 13 non-BAT types are covered ---
        uint256 mintCount = 0;
        while (uniqueTypes < NUM_VALID_TYPES) {
            require(mintCount < MAX_MINTS_SAFETY, "Safety cap reached - could not cover all 13 types");

            // Query current price (sliding scale)
            (, uint256 mintPrice, , ) = minter.getPriceInfo(PROJECT_ID, CORE_CONTRACT);

            // Fund artist wallet and execute mint
            vm.deal(ARTIST_WALLET, mintPrice + 0.1 ether);
            vm.startPrank(ARTIST_WALLET);
            (bool success, bytes memory returnData) = address(MINTER_CONTRACT).call{value: mintPrice}(
                abi.encodeWithSelector(PURCHASE_SELECTOR, PROJECT_ID, CORE_CONTRACT)
            );
            require(success, "Mint transaction failed");
            uint256 mintedTokenId = abi.decode(returnData, (uint256));
            vm.stopPrank();
            mintCount++;

            // Track type coverage
            (StratHooks.TokenType tokenType, uint256 tokenBalance, , , , ) = hooks.tokenMetadata(mintedTokenId);
            uint256 typeIdx = uint256(tokenType);
            bool isNew = !typesSeen[typeIdx] && typeIdx != BAT_TYPE_INDEX;
            if (isNew) {
                typesSeen[typeIdx] = true;
                firstTokenOfType[typeIdx] = mintedTokenId;
                uniqueTypes++;
            }

            console.log(
                string.concat(
                    "  Mint #", vm.toString(mintCount),
                    " -> token ", vm.toString(mintedTokenId),
                    " = ", _getTokenSymbol(tokenType),
                    isNew ? " [NEW TYPE]" : " [duplicate]",
                    " (balance: ", vm.toString(tokenBalance), ")"
                )
            );
        }

        console.log("");
        console.log(
            string.concat(
                "All 13 non-BAT types covered after ", vm.toString(mintCount), " new mints (",
                vm.toString(invocations + mintCount), " total tokens)"
            )
        );

        // Verify BAT was never seen
        assertFalse(typesSeen[BAT_TYPE_INDEX], "BAT should never appear with V2 receiveFunds");

        // --- Build the 13 representative token IDs ---
        selectedTokenIds = new uint256[](NUM_VALID_TYPES);
        uint256 idx = 0;
        for (uint256 typeVal = 0; typeVal < NUM_TOKEN_TYPES; typeVal++) {
            if (typeVal == BAT_TYPE_INDEX) continue;
            require(typesSeen[typeVal], string.concat("Missing type ", vm.toString(typeVal)));
            selectedTokenIds[idx] = firstTokenOfType[typeVal];
            idx++;
        }
        assertEq(idx, NUM_VALID_TYPES, "Should have exactly 13 representatives");
    }

    // ============================================
    // Phase 2: Verify Selected Token Metadata
    // ============================================

    /// @dev Verify all 13 representative tokens have valid metadata.
    function _verifySelectedTokenMetadata(uint256[] memory selectedTokenIds) internal view {
        for (uint256 i = 0; i < selectedTokenIds.length; i++) {
            _logAndVerifyToken(selectedTokenIds[i]);
        }
        console.log("");
        console.log("All 13 representative tokens verified: initialized, non-BAT, valid metadata");
    }

    function _logAndVerifyToken(uint256 tokenId) internal view {
        (
            StratHooks.TokenType tokenType,
            uint256 tokenBalance,
            uint128 createdAt,
            uint32 intervalLengthSeconds,
            bool isWithdrawn,
        ) = hooks.tokenMetadata(tokenId);

        require(createdAt != 0, "Token not initialized");
        require(tokenType != StratHooks.TokenType.BAT, "Token is BAT");
        require(tokenBalance > 0, "Token has zero balance");
        require(intervalLengthSeconds > 0, "Token has zero interval");
        require(!isWithdrawn, "Token already withdrawn");

        console.log(
            string.concat(
                "  Token ", vm.toString(tokenId),
                ": ", _getTokenSymbol(tokenType),
                " | balance=", vm.toString(tokenBalance),
                " | interval=", vm.toString(uint256(intervalLengthSeconds)), "s"
            )
        );
    }

    // ============================================
    // Phase 3: Execute Price Checkins (Selected)
    // ============================================

    /// @dev Mock oracle, warp time, and directly perform 11 keeper rounds on each of the 13 representatives.
    function _executePriceCheckinsForSelected(uint256[] memory selectedTokenIds) internal {
        // Step 1: Snapshot a live oracle price before time-warping
        IGuardedEthTokenSwapper swapper = hooks.guardedEthTokenSwapper();
        address linkAddress = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        (uint256 currentPrice, uint8 priceDecimals) = swapper.getTokenPrice(linkAddress);
        console.log("Snapshotted oracle price:", currentPrice);
        console.log("Oracle price decimals:", uint256(priceDecimals));

        // Step 2: Mock getTokenPrice globally (all token addresses return same price)
        vm.mockCall(
            address(swapper),
            abi.encodeWithSelector(IGuardedEthTokenSwapper.getTokenPrice.selector),
            abi.encode(currentPrice, priceDecimals)
        );

        // Step 3: Find the maximum warp target across the 13 selected tokens
        uint256 maxWarpTarget = 0;
        for (uint256 i = 0; i < selectedTokenIds.length; i++) {
            (, , uint128 createdAt, uint32 interval, , ) = hooks.tokenMetadata(selectedTokenIds[i]);
            uint256 warpTarget = uint256(createdAt) + uint256(interval) * 12 + 1;
            if (warpTarget > maxWarpTarget) {
                maxWarpTarget = warpTarget;
            }
        }
        console.log("Warping to timestamp:", maxWarpTarget);
        vm.warp(maxWarpTarget);

        // Step 4: Directly perform 11 keeper rounds on each representative
        address keeperAddress = hooks.keeper();
        uint256 totalUpkeeps = 0;

        for (uint256 i = 0; i < selectedTokenIds.length; i++) {
            uint256 tokenId = selectedTokenIds[i];
            (StratHooks.TokenType tokenType, , , , , ) = hooks.tokenMetadata(tokenId);

            for (uint256 round = 1; round < 12; round++) {
                vm.prank(keeperAddress);
                hooks.performUpkeep(abi.encode(tokenId, round));
                totalUpkeeps++;
            }

            // Verify this token is now complete (round 12 should revert)
            vm.prank(keeperAddress);
            vm.expectRevert("Already complete");
            hooks.performUpkeep(abi.encode(tokenId, uint256(12)));

            console.log(
                string.concat(
                    "  Token ", vm.toString(tokenId),
                    " (", _getTokenSymbol(tokenType), ")",
                    ": 11 upkeep rounds performed, 12 total entries confirmed"
                )
            );
        }

        console.log("");
        console.log(
            string.concat("Total upkeep rounds: ", vm.toString(totalUpkeeps), " (11 x 13 types)")
        );
    }

    // ============================================
    // Phase 4: Withdraw Selected Tokens
    // ============================================

    /// @dev Execute withdrawal for the 13 representative tokens via PMPV0 and verify balances.
    function _executeWithdrawalsForSelected(uint256[] memory selectedTokenIds) internal {
        IPMPV0.PMPInput[] memory inputs = _buildWithdrawalInput();

        for (uint256 i = 0; i < selectedTokenIds.length; i++) {
            _withdrawSingleToken(selectedTokenIds[i], inputs);
        }

        console.log("");
        console.log("All 13 withdrawals successful, balances verified, double-withdrawal reverts confirmed");
    }

    /// @dev Withdraw a single token via PMPV0 and verify balances.
    function _withdrawSingleToken(uint256 tokenId, IPMPV0.PMPInput[] memory inputs) internal {
        (StratHooks.TokenType tokenType, uint256 tokenBalance, , , bool isWithdrawnBefore, ) =
            hooks.tokenMetadata(tokenId);

        assertFalse(isWithdrawnBefore, "Token already withdrawn before test");

        address tokenAddress = _getTokenAddress(tokenType);
        address tokenOwner = IERC721(CORE_CONTRACT).ownerOf(tokenId);

        // Record balances before withdrawal
        uint256 ownerERC20Before = IERC20(tokenAddress).balanceOf(tokenOwner);
        uint256 hooksERC20Before = IERC20(tokenAddress).balanceOf(STRAT_HOOKS_PROXY);

        // Execute withdrawal via PMPV0 as token owner
        vm.prank(tokenOwner);
        IPMPV0(PMPV0_ADDRESS).configureTokenParams(CORE_CONTRACT, tokenId, inputs);

        // Verify withdrawal state
        _verifyWithdrawalState(tokenId);

        // Verify ERC20 balance changes
        _verifyBalanceChanges(tokenAddress, tokenOwner, ownerERC20Before, hooksERC20Before, tokenBalance);

        console.log(
            string.concat(
                "  Token ", vm.toString(tokenId),
                " (", _getTokenSymbol(tokenType), ")",
                ": withdrew ", vm.toString(tokenBalance),
                " to ", vm.toString(tokenOwner)
            )
        );

        // Verify double-withdrawal is prevented
        vm.prank(tokenOwner);
        vm.expectRevert("Token already withdrawn");
        IPMPV0(PMPV0_ADDRESS).configureTokenParams(CORE_CONTRACT, tokenId, inputs);
    }

    /// @dev Verify token withdrawal state after withdrawal.
    function _verifyWithdrawalState(uint256 tokenId) internal view {
        (, , , , bool isWithdrawnAfter, uint128 withdrawnAt) = hooks.tokenMetadata(tokenId);
        assertTrue(isWithdrawnAfter, "Token should be marked as withdrawn");
        assertGt(withdrawnAt, 0, "withdrawnAt timestamp should be set");
    }

    /// @dev Verify ERC20 balance changes after withdrawal.
    function _verifyBalanceChanges(
        address tokenAddress,
        address tokenOwner,
        uint256 ownerERC20Before,
        uint256 hooksERC20Before,
        uint256 expectedTransfer
    ) internal view {
        uint256 ownerERC20After = IERC20(tokenAddress).balanceOf(tokenOwner);
        uint256 hooksERC20After = IERC20(tokenAddress).balanceOf(STRAT_HOOKS_PROXY);

        assertEq(ownerERC20After - ownerERC20Before, expectedTransfer, "Owner should receive full token balance");
        assertEq(hooksERC20Before - hooksERC20After, expectedTransfer, "Hooks balance should decrease by tokenBalance");
    }

    // ============================================
    // Helper Functions
    // ============================================

    /// @dev Build the PMPInput array for an IsWithdrawn = true withdrawal
    function _buildWithdrawalInput() internal pure returns (IPMPV0.PMPInput[] memory inputs) {
        inputs = new IPMPV0.PMPInput[](1);
        inputs[0] = IPMPV0.PMPInput({
            key: "IsWithdrawn",
            configuredParamType: IPMPV0.ParamType.Bool,
            configuredValue: bytes32(uint256(1)),
            configuringArtistString: false,
            configuredValueString: ""
        });
    }

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
