// SPDX-License-Identifier: LGPL-3.0-only
// Created By: Art Blocks Inc. & Contributors

pragma solidity 0.8.24;

import {StratHooks} from "./StratHooks.sol";

/**
 * @title StratHooksV2
 * @author Art Blocks Inc. & Contributors
 * @notice Upgraded StratHooks with bug fixes for:
 *   1) performUpkeep/checkUpkeep hardening to prevent upkeep on uninitialized tokens
 *   2) 12-entry cap enforcement on priceHistory
 *   3) receiveFunds double-receive prevention
 *   4) One-time migration to repair token 0's corrupted priceHistory
 * @dev This contract inherits from StratHooks and overrides the buggy functions.
 *      Storage layout is preserved - no new storage variables are added.
 */
contract StratHooksV2 is StratHooks {
    // ============================================
    // Events (appended at end, no storage impact)
    // ============================================

    /**
     * @notice Emitted when token 0's price history is repaired during V2 migration
     * @param tokenId The token ID that was repaired
     * @param keptPrice The price entry that was kept (last entry)
     * @param oldLength The original length of priceHistory before repair
     */
    event TokenPriceHistoryRepaired(uint256 indexed tokenId, uint256 keptPrice, uint256 oldLength);

    // ============================================
    // V2 Initializer (reinitializer for upgrade)
    // ============================================

    /**
     * @notice One-time migration function to repair token 0's corrupted price history.
     * @dev Called via upgradeToAndCall during the UUPS upgrade.
     *      Uses reinitializer(2) since initialize() was reinitializer(1).
     *      Repairs token 0 by keeping only the last priceHistory entry (the real baseline).
     */
    function initializeV2RepairToken0() external reinitializer(2) {
        // Calculate token 0 ID based on project ID
        uint256 token0 = PROJECT_ID() * 1_000_000;

        TokenMetadata storage t = tokenMetadata[token0];

        // Safety checks
        require(t.createdAt != 0, "Token not initialized");
        require(t.priceHistory.length > 0, "No history");

        // Only repair if needed (length > 1, which indicates the bug occurred)
        uint256 oldLen = t.priceHistory.length;
        if (oldLen > 1) {
            // Keep the last entry (the real post-receiveFunds baseline price)
            uint256 kept = t.priceHistory[oldLen - 1];

            // Clear the array and push back the kept entry
            delete t.priceHistory;
            t.priceHistory.push(kept);

            emit TokenPriceHistoryRepaired(token0, kept, oldLen);
        }
        // If length == 1, no repair needed - token is already correct
    }

    // ============================================
    // Overridden Functions with Bug Fixes
    // ============================================

    /**
     * @notice Receive funds for a new token during mint, initializes the token metadata
     * @dev OVERRIDE: Added double-receive prevention check
     * @param tokenId The token id to receive funds for
     * @param tokenHash The hash of the token to receive funds for
     */
    function receiveFunds(uint256 tokenId, bytes32 tokenHash) external payable override onlyAdditionalPayeeReceiver {
        // CHECKS
        // Prevent double-receive (V2 extra guard)
        require(tokenMetadata[tokenId].createdAt == 0, "Token already initialized");
        // must receive sequentially
        require(latestReceivedTokenId == 0 || latestReceivedTokenId == tokenId - 1, "Invalid token id");

        // EFFECTS
        latestReceivedTokenId = tokenId;
        // assign prng values
        TokenType tokenType = TokenType(uint256(tokenHash) % 14); // 14 token types
        address tokenAddress = _getTokenAddressFromTokenType(tokenType);
        uint32 intervalLengthSeconds = _getIntervalLengthSecondsFromTokenHash(tokenHash);
        // assign token metadata values
        uint256 tokenBalance = guardedEthTokenSwapper.swapEthForToken{value: msg.value}({
            token: tokenAddress,
            slippageBps: 200, // 2% slippage
            deadline: block.timestamp + 600 // 10 minutes
        });
        TokenMetadata storage t = tokenMetadata[tokenId];
        t.tokenType = tokenType;
        t.tokenBalance = tokenBalance;
        t.createdAt = uint128(block.timestamp);
        t.intervalLengthSeconds = uint32(intervalLengthSeconds);

        // record the first price history entry
        // @dev we pull from the oracle for consistency
        _appendPriceHistoryEntry(tokenId, tokenType);
        // @dev price history array length is the round number, so we don't need to increment it separately
    }

    /**
     * @notice Checks if upkeep is needed for a token
     * @dev OVERRIDE: Added initialization check and fixed terminal condition to >= 12
     * WARNING: This function iterates over all tokens, and is intended for off-chain view calls only.
     * @return upkeepNeeded Boolean indicating if upkeep is needed
     * @return performData ABI-encoded (uint256 tokenId, uint256 round) to pass to performUpkeep
     */
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        uint256 maxTokenId = latestReceivedTokenId;
        uint256 minTokenId = (latestReceivedTokenId / 1_000_000) * 1_000_000; // token 0 id

        for (uint256 tokenId_ = minTokenId; tokenId_ <= maxTokenId; tokenId_++) {
            TokenMetadata storage t = tokenMetadata[tokenId_];

            // V2 fix: Skip uninitialized tokens (createdAt == 0 means not yet received via receiveFunds)
            if (t.createdAt == 0) {
                continue;
            }

            uint256 currentRound = t.priceHistory.length;

            // V2 fix: Use >= 12 for terminal condition (not == 12)
            // This ensures tokens with corrupted history (len > 12) are also skipped
            if (currentRound >= 12) {
                continue;
            }

            // Check if it's time for the next upkeep
            if (block.timestamp > t.createdAt + t.intervalLengthSeconds * currentRound) {
                upkeepNeeded = true;
                performData = abi.encode(tokenId_, currentRound);
                return (upkeepNeeded, performData);
            }
        }

        return (false, "");
    }

    /**
     * @notice Performs the upkeep for a token
     * @dev OVERRIDE: Added initialization check and reordered checks for safety
     * @param performData ABI-encoded (uint256 tokenId, uint256 round)
     */
    function performUpkeep(bytes calldata performData) external override onlyKeeper {
        // CHECKS
        (uint256 tokenId, uint256 round) = abi.decode(performData, (uint256, uint256));
        TokenMetadata storage t = tokenMetadata[tokenId];

        // V2 fix: Check token is initialized FIRST (before any other checks)
        require(t.createdAt != 0, "Token not initialized");

        // V2 fix: Enforce 12 TOTAL price entries cap
        require(t.priceHistory.length < 12, "Already complete");

        // Verify this is the current round (prevents stale upkeeps)
        require(round == t.priceHistory.length, "Stale upkeep");

        // Verify block timestamp requirements (checked after initialization/completion checks)
        require(block.timestamp > t.createdAt + t.intervalLengthSeconds * round, "Block timestamp requirements not met");

        // EFFECTS
        _appendPriceHistoryEntry(tokenId, t.tokenType);

        // Emit event
        emit UpkeepPerformed(tokenId, round, block.timestamp);
    }
}
