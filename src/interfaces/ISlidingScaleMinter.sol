// SPDX-License-Identifier: LGPL-3.0-only
// Created By: Art Blocks Inc.

pragma solidity 0.8.24;

/**
 * @title ISlidingScaleMinter
 * @notice Interface for querying token purchase prices from a sliding scale minter
 */
interface ISlidingScaleMinter {
    /**
     * @notice Gets the price paid for a specific token.
     * @dev Returns 0 if the token was not minted via this minter or if
     * the token does not exist. This function does not validate that the
     * token was minted via this minter.
     * @param coreContract Core contract address for the token
     * @param tokenId Token ID to get the price paid for
     * @return pricePaidInWei Price paid for the token in Wei, or 0 if not
     * minted via this minter
     */
    function getTokenPricePaid(address coreContract, uint256 tokenId)
        external
        view
        returns (uint256 pricePaidInWei);
}
