// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {StratHooks} from "../src/StratHooks.sol";
import {IGuardedEthTokenSwapper} from "../src/interfaces/IGuardedEthTokenSwapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

// Fork test to debug first token mint on mainnet.
// Run: forge test --match-contract MainnetForkMintTest -vvvv --fork-url $MAINNET_RPC_URL

// Purchase selector for MinterSlidingScaleV0 at 0x8c4ceA530b2Ff89d312F15A8DB38f04cDB5371d8 (from Etherscan)
bytes4 constant PURCHASE_SELECTOR = 0xae77c237;
// Temporarily: configure price so mint doesn't revert (price not yet configured)
bytes4 constant UPDATE_PRICE_PER_TOKEN_SELECTOR = 0x7e947f24;

// Interface for SlidingScaleMinter - view functions only (purchase uses correct selector via low-level call)
interface ISlidingScaleMinterFull {
    function getTokenPricePaid(address coreContract, uint256 tokenId) external view returns (uint256 pricePaidInWei);

    // Project config
    function projectMaxHasBeenInvoked(address coreContract, uint256 projectId) external view returns (bool);
    function projectMaxInvocations(address coreContract, uint256 projectId) external view returns (uint256);
}

// Interface for Art Blocks core contract
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

    function projectIdToAdditionalPayeePrimarySales(uint256 projectId)
        external
        view
        returns (address additionalPayeePrimarySales, uint256 additionalPayeePrimarySalesPercentage);

    function projectIdToArtistAddress(uint256 projectId) external view returns (address);

    function ownerOf(uint256 tokenId) external view returns (address);

    function tokenIdToHash(uint256 tokenId) external view returns (bytes32);

    function minterContract() external view returns (address);
}

// Interface for AdditionalPayeeReceiver
interface IAdditionalPayeeReceiver {
    function allowedSender() external view returns (address);
    function coreContract() external view returns (address);
    function projectId() external view returns (uint256);
    function stratHooks() external view returns (address);
}

contract MainnetForkMintTest is Test {
    // Mainnet addresses from user
    address constant STRAT_HOOKS_PROXY = 0x9a3f4307b1d12aeA5E2633e6e10Fb3cf9Ac81F9a;
    address constant CORE_CONTRACT = 0xaa00B2b2dB36B8F8004A9AA96F0012005D92B300;
    address constant MINTER_CONTRACT = 0x8c4ceA530b2Ff89d312F15A8DB38f04cDB5371d8;
    address constant ARTIST_WALLET = 0x2574c77a694700b7baB562fefeB9Ce93DB5A097A;
    uint256 constant PROJECT_ID = 0;
    uint256 constant MINT_PRICE = 0.015 ether;

    StratHooks hooks;
    ISlidingScaleMinterFull minter;
    IGenArt721CoreV3 core;

    function setUp() public {
        // The fork is handled by command line --fork-url flag
        // Cast to interfaces
        hooks = StratHooks(STRAT_HOOKS_PROXY);
        minter = ISlidingScaleMinterFull(MINTER_CONTRACT);
        core = IGenArt721CoreV3(CORE_CONTRACT);
    }

    function test_DebugMintTransaction() public {
        console.log("=== MAINNET FORK MINT DEBUG TEST ===");
        console.log("");

        // Log initial state
        console.log("--- CONFIGURATION ---");
        console.log("StratHooks Proxy:", STRAT_HOOKS_PROXY);
        console.log("Core Contract:", CORE_CONTRACT);
        console.log("Minter Contract:", MINTER_CONTRACT);
        console.log("Artist Wallet:", ARTIST_WALLET);
        console.log("Project ID:", PROJECT_ID);
        console.log("Mint Price:", MINT_PRICE);
        console.log("");

        // Check artist wallet balance
        uint256 artistBalanceBefore = ARTIST_WALLET.balance;
        console.log("--- ARTIST WALLET STATE ---");
        console.log("Artist ETH Balance Before:", artistBalanceBefore);

        // Fund artist wallet if needed
        if (artistBalanceBefore < MINT_PRICE) {
            console.log("WARNING: Artist wallet has insufficient ETH, funding...");
            vm.deal(ARTIST_WALLET, MINT_PRICE + 0.01 ether);
            console.log("Artist ETH Balance After Funding:", ARTIST_WALLET.balance);
        }
        console.log("");

        // Check project state
        console.log("--- PROJECT STATE ---");
        try core.projectStateData(PROJECT_ID) returns (
            uint256 invocations,
            uint256 maxInvocations,
            bool active,
            bool paused,
            uint256 completedTimestamp,
            bool locked
        ) {
            console.log("Invocations:", invocations);
            console.log("Max Invocations:", maxInvocations);
            console.log("Active:", active);
            console.log("Paused:", paused);
            console.log("Completed Timestamp:", completedTimestamp);
            console.log("Locked:", locked);

            if (!active) {
                console.log("ERROR: Project is NOT active!");
            }
            if (paused) {
                console.log("ERROR: Project is PAUSED!");
            }
            if (invocations >= maxInvocations) {
                console.log("ERROR: Project has reached max invocations!");
            }
        } catch Error(string memory reason) {
            console.log("ERROR getting project state:", reason);
        } catch {
            console.log("ERROR getting project state (no reason)");
        }
        console.log("");

        // Check additional payee configuration
        console.log("--- ADDITIONAL PAYEE CONFIG ---");
        try core.projectIdToAdditionalPayeePrimarySales(PROJECT_ID) returns (
            address additionalPayee, uint256 percentage
        ) {
            console.log("Additional Payee Address:", additionalPayee);
            console.log("Additional Payee Percentage:", percentage);

            // If there's an additional payee, check its configuration
            if (additionalPayee != address(0)) {
                IAdditionalPayeeReceiver receiver = IAdditionalPayeeReceiver(additionalPayee);

                try receiver.allowedSender() returns (address allowedSender) {
                    console.log("AdditionalPayeeReceiver.allowedSender:", allowedSender);
                    if (allowedSender != MINTER_CONTRACT) {
                        console.log("WARNING: allowedSender != MINTER_CONTRACT!");
                    }
                } catch {}

                try receiver.stratHooks() returns (address stratHooksAddr) {
                    console.log("AdditionalPayeeReceiver.stratHooks:", stratHooksAddr);
                    if (stratHooksAddr != STRAT_HOOKS_PROXY) {
                        console.log("WARNING: stratHooks != STRAT_HOOKS_PROXY!");
                    }
                } catch {}
            }
        } catch Error(string memory reason) {
            console.log("ERROR getting additional payee:", reason);
        } catch {
            console.log("ERROR getting additional payee (no reason)");
        }
        console.log("");

        // Check minter configuration
        console.log("--- MINTER CONFIG ---");
        try core.minterContract() returns (address registeredMinter) {
            console.log("Registered Minter on Core:", registeredMinter);
            if (registeredMinter != MINTER_CONTRACT) {
                console.log("WARNING: Registered minter does not match expected!");
            }
        } catch {}

        // getPriceInfo has a different selector on MinterSlidingScaleV0 - skip to avoid selector revert
        console.log("");

        // Check StratHooks state
        console.log("--- STRAT HOOKS STATE ---");
        try hooks.CORE_CONTRACT_ADDRESS() returns (address coreAddr) {
            console.log("StratHooks.CORE_CONTRACT_ADDRESS:", coreAddr);
            if (coreAddr != CORE_CONTRACT) {
                console.log("WARNING: Core contract mismatch!");
            }
        } catch Error(string memory reason) {
            console.log("ERROR getting core address:", reason);
        } catch {}

        try hooks.PROJECT_ID() returns (uint256 projId) {
            console.log("StratHooks.PROJECT_ID:", projId);
            if (projId != PROJECT_ID) {
                console.log("WARNING: Project ID mismatch!");
            }
        } catch Error(string memory reason) {
            console.log("ERROR getting project ID:", reason);
        } catch {}

        try hooks.additionalPayeeReceiver() returns (address receiver) {
            console.log("StratHooks.additionalPayeeReceiver:", receiver);
        } catch Error(string memory reason) {
            console.log("ERROR getting additionalPayeeReceiver:", reason);
        } catch {}

        try hooks.latestReceivedTokenId() returns (uint256 latestId) {
            console.log("StratHooks.latestReceivedTokenId:", latestId);
        } catch Error(string memory reason) {
            console.log("ERROR getting latestReceivedTokenId:", reason);
        } catch {}

        address swapper;
        try hooks.guardedEthTokenSwapper() returns (IGuardedEthTokenSwapper swapperContract) {
            swapper = address(swapperContract);
            console.log("StratHooks.guardedEthTokenSwapper:", swapper);
        } catch Error(string memory reason) {
            console.log("ERROR getting guardedEthTokenSwapper:", reason);
        } catch {}
        console.log("");

        // Temporarily: artist configures price per token so mint can succeed (otherwise "price not yet configured" revert)
        console.log("=== CONFIGURING PRICE (updatePricePerTokenInWei 0x7e947f24) ===");
        console.log("Calling with projectId:", PROJECT_ID);
        console.log("coreContract:", CORE_CONTRACT);
        console.log("pricePerTokenInWei:", MINT_PRICE);
        vm.startPrank(ARTIST_WALLET);
        (bool priceUpdateSuccess, bytes memory priceUpdateReturnData) = address(minter)
            .call(abi.encodeWithSelector(UPDATE_PRICE_PER_TOKEN_SELECTOR, PROJECT_ID, CORE_CONTRACT, MINT_PRICE));
        if (priceUpdateSuccess) {
            console.log("Price configured successfully.");
        } else {
            console.log("Price update FAILED. Return data length:", priceUpdateReturnData.length);
            if (priceUpdateReturnData.length >= 4) {
                console.log("Error selector:", vm.toString(bytes4(priceUpdateReturnData)));
            }
            if (priceUpdateReturnData.length > 0) {
                console.logBytes(priceUpdateReturnData);
            }
        }
        console.log("");

        // Mine next block so purchase runs in a new block and sees the price state update
        vm.roll(block.number + 1);

        // Attempt the purchase using correct selector 0xae77c237 (MinterSlidingScaleV0 on Etherscan)
        console.log("=== ATTEMPTING PURCHASE ===");
        console.log("Calling purchase(selector 0xae77c237) from artist wallet with", MINT_PRICE, "wei");
        console.log("");

        // Record balances before
        uint256 artistEthBefore = ARTIST_WALLET.balance;

        (bool purchaseSuccess, bytes memory purchaseReturnData) = address(minter).call{value: MINT_PRICE}(
            abi.encodeWithSelector(PURCHASE_SELECTOR, PROJECT_ID, CORE_CONTRACT)
        );

        if (purchaseSuccess) {
            uint256 tokenId = abi.decode(purchaseReturnData, (uint256));
            console.log("SUCCESS! Token minted with ID:", tokenId);
            console.log("");

            // Log post-mint state
            console.log("--- POST-MINT STATE ---");
            console.log("Artist ETH After:", ARTIST_WALLET.balance);
            console.log("ETH Spent:", artistEthBefore - ARTIST_WALLET.balance);

            // Check token ownership
            try core.ownerOf(tokenId) returns (address owner) {
                console.log("Token Owner:", owner);
            } catch {}

            // Check token hash
            try core.tokenIdToHash(tokenId) returns (bytes32 hash) {
                console.log("Token Hash:", vm.toString(hash));
            } catch {}

            // Check StratHooks received funds
            try hooks.latestReceivedTokenId() returns (uint256 latestId) {
                console.log("StratHooks.latestReceivedTokenId (after):", latestId);
                if (latestId == tokenId) {
                    console.log("SUCCESS: StratHooks received token funds!");
                } else {
                    console.log("WARNING: StratHooks may not have received funds");
                }
            } catch {}

            // Check token metadata in StratHooks
            try hooks.tokenMetadata(tokenId) returns (
                StratHooks.TokenType tokenType,
                uint256 tokenBalance,
                uint128 createdAt,
                uint32 intervalLengthSeconds,
                bool, /* isWithdrawn */
                uint128 /* withdrawnAt */
            ) {
                console.log("Token Type:", uint256(tokenType));
                console.log("Token Balance:", tokenBalance);
                console.log("Created At:", createdAt);
                console.log("Interval Length (seconds):", intervalLengthSeconds);
            } catch Error(string memory reason) {
                console.log("ERROR getting token metadata:", reason);
            } catch {}
        } else {
            console.log("PURCHASE FAILED (low-level revert)");
            console.log("Return data length:", purchaseReturnData.length);
            if (purchaseReturnData.length >= 4) {
                bytes4 errorSelector = bytes4(purchaseReturnData);
                console.log("Error selector:", vm.toString(errorSelector));
            }
            if (purchaseReturnData.length > 0) {
                console.logBytes(purchaseReturnData);
            }
        }

        vm.stopPrank();
        console.log("");
        console.log("=== TEST COMPLETE ===");
    }

    function test_DebugPurchaseTo() public view {
        // MinterSlidingScaleV0 purchase uses selector 0xae77c237; test_DebugMintTransaction covers it.
        // No separate purchaseTo test - main test calls purchase(coreContract, projectId) with correct selector.
    }

    function test_CheckAllPrerequisites() public view {
        console.log("=== PREREQUISITE CHECK ===");
        console.log("");

        // 1. Check project is active and not paused
        (uint256 invocations, uint256 maxInvocations, bool active, bool paused,,) = core.projectStateData(PROJECT_ID);

        bool projectOk = active && !paused && (invocations < maxInvocations);
        console.log("[", projectOk ? "OK" : "FAIL", "] Project state (active, not paused, has capacity)");
        console.log("    - Active:", active);
        console.log("    - Paused:", paused);
        console.log("    - Invocations:", invocations, "/", maxInvocations);
        console.log("");

        // 2. Check minter is registered
        address registeredMinter = core.minterContract();
        bool minterOk = registeredMinter == MINTER_CONTRACT;
        console.log("[", minterOk ? "OK" : "FAIL", "] Minter registration");
        console.log("    - Registered:", registeredMinter);
        console.log("    - Expected:", MINTER_CONTRACT);
        console.log("");

        // 3. Check StratHooks configuration
        address hooksCore = hooks.CORE_CONTRACT_ADDRESS();
        uint256 hooksProjectId = hooks.PROJECT_ID();
        bool hooksOk = (hooksCore == CORE_CONTRACT) && (hooksProjectId == PROJECT_ID);
        console.log("[", hooksOk ? "OK" : "FAIL", "] StratHooks configuration");
        console.log("    - Core:", hooksCore, hooksCore == CORE_CONTRACT ? "(match)" : "(MISMATCH)");
        console.log("    - Project:", hooksProjectId, hooksProjectId == PROJECT_ID ? "(match)" : "(MISMATCH)");
        console.log("");

        // 4. Check additional payee receiver
        address payeeReceiver = hooks.additionalPayeeReceiver();
        (address configuredPayee, uint256 percentage) = core.projectIdToAdditionalPayeePrimarySales(PROJECT_ID);
        bool payeeOk = payeeReceiver == configuredPayee && percentage > 0;
        console.log("[", payeeOk ? "OK" : "FAIL", "] Additional payee configuration");
        console.log("    - StratHooks.additionalPayeeReceiver:", payeeReceiver);
        console.log("    - Core configured payee:", configuredPayee);
        console.log("    - Payee percentage:", percentage);
        console.log("");

        // 5. Check swapper is set
        address swapper = address(hooks.guardedEthTokenSwapper());
        bool swapperOk = swapper != address(0);
        console.log("[", swapperOk ? "OK" : "FAIL", "] GuardedEthTokenSwapper");
        console.log("    - Address:", swapper);
        console.log("");

        // Summary
        console.log("=== SUMMARY ===");
        if (projectOk && minterOk && hooksOk && payeeOk && swapperOk) {
            console.log("All prerequisites PASSED");
        } else {
            console.log("Some prerequisites FAILED - see above");
        }
    }
}
