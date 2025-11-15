// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IGuardedEthTokenSwapper
 * @notice Interface for the GuardedEthTokenSwapper contract
 * @dev Interface for swapping ETH to ERC20 tokens with Chainlink oracle price validation
 *
 * The GuardedEthTokenSwapper is deployed on Ethereum mainnet at:
 * 0x96E6a25565E998C6EcB98a59CC87F7Fc5Ed4D7b0
 *
 * Features:
 * - Swap ETH for 14 supported ERC20 tokens
 * - Chainlink oracle price validation
 * - Configurable slippage protection per token
 * - Uniswap V3 integration with optimal fee tiers
 */
interface IGuardedEthTokenSwapper {
    // ============================================
    // Events
    // ============================================

    /**
     * @notice Emitted when a price feed is configured for a token
     * @param token The ERC20 token address
     * @param aggregator The Chainlink price feed address (TOKEN/ETH)
     * @param decimals The number of decimals in the price feed
     * @param feeTier The Uniswap V3 fee tier (500=0.05%, 3000=0.30%, 10000=1.00%)
     * @param toleranceBps The price tolerance in basis points (e.g., 200=2%)
     */
    event FeedSet(
        address indexed token, address indexed aggregator, uint8 decimals, uint24 feeTier, uint16 toleranceBps
    );

    /**
     * @notice Emitted when a price feed is removed for a token
     * @param token The ERC20 token address that was removed
     */
    event FeedRemoved(address indexed token);

    /**
     * @notice Emitted when an ETH to token swap is executed
     * @param user The address that initiated the swap
     * @param token The ERC20 token received
     * @param ethIn The amount of ETH swapped
     * @param tokensOut The amount of tokens received
     * @param fee The Uniswap V3 fee tier used
     * @param minOut The minimum tokens expected (after slippage)
     * @param oraclePrice The Chainlink oracle price used for validation
     */
    event Swapped(
        address indexed user,
        address indexed token,
        uint256 ethIn,
        uint256 tokensOut,
        uint24 fee,
        uint256 minOut,
        uint256 oraclePrice
    );

    // ============================================
    // Errors
    // ============================================

    /// @notice Thrown when no ETH is sent with the swap transaction
    error NoEthSent();

    /// @notice Thrown when a token doesn't have a configured price feed
    error FeedNotSet();

    /// @notice Thrown when oracle data is older than 24 hours
    error StalePrice();

    /// @notice Thrown when the slippage tolerance exceeds 100%
    error InvalidSlippage();

    /// @notice Thrown when the deadline has passed
    error DeadlineTooSoon();

    // ============================================
    // Core Functions
    // ============================================

    /**
     * @notice Swap ETH for a supported ERC20 token with oracle-validated pricing
     * @dev Validates price using Chainlink oracle before executing Uniswap V3 swap
     *
     * @param token The ERC20 token address to receive
     * @param slippageBps Maximum allowed slippage in basis points (e.g., 300 = 3%)
     * @param deadline Unix timestamp after which the transaction will revert
     * @return amountOut The amount of tokens received
     *
     * Requirements:
     * - Must send ETH with the transaction (msg.value > 0)
     * - Token must have a configured price feed
     * - Slippage must be ≤ 10000 bps (100%)
     * - Deadline must be at least 300 seconds (5 minutes) in the future
     * - Oracle price must be fresh (< 24 hours old)
     * - Swap must meet minimum output based on oracle price and slippage
     *
     * Example:
     * ```solidity
     * // Swap 1 ETH for LINK with 2% slippage, 10 minute deadline
     * uint256 deadline = block.timestamp + 600;
     * uint256 tokensReceived = swapper.swapEthForToken{value: 1 ether}(
     *     LINK_ADDRESS,
     *     200,  // 2% slippage
     *     deadline
     * );
     * ```
     */
    function swapEthForToken(address token, uint16 slippageBps, uint256 deadline)
        external
        payable
        returns (uint256 amountOut);

    // ============================================
    // Admin Functions (Owner Only)
    // ============================================

    /**
     * @notice Configure price feeds and swap parameters for multiple tokens (owner only)
     * @dev All arrays must be the same length. Sets up Chainlink feeds and Uniswap configs.
     *
     * @param tokens Array of ERC20 token addresses to configure
     * @param aggregators Array of Chainlink TOKEN/ETH price feed addresses
     * @param feeTiers Array of Uniswap V3 fee tiers (500, 3000, or 10000)
     * @param toleranceBpsArr Array of price tolerance values in basis points (≤ 2000)
     *
     * Requirements:
     * - Caller must be contract owner
     * - All arrays must have matching length
     * - Token and aggregator addresses must be non-zero
     * - Fee tiers must be 500, 3000, or 10000
     * - Tolerance must be ≤ 2000 bps (20%)
     */
    function setFeeds(
        address[] calldata tokens,
        address[] calldata aggregators,
        uint24[] calldata feeTiers,
        uint16[] calldata toleranceBpsArr
    ) external;

    /**
     * @notice Remove price feed configuration for a token (owner only)
     * @dev After removal, swaps for this token will revert with FeedNotSet error
     *
     * @param token The ERC20 token address to remove from supported tokens
     *
     * Requirements:
     * - Caller must be contract owner
     * - Token must have an existing configuration
     */
    function removeFeed(address token) external;

    // ============================================
    // View Functions
    // ============================================

    /**
     * @notice Returns the configuration for a given token
     * @param token The ERC20 token address to query
     * @return aggregator The Chainlink price feed address (zero if not configured)
     * @return decimals The cached decimal count from the price feed
     * @return feeTier The Uniswap V3 fee tier to use for swaps
     * @return toleranceBps The price tolerance in basis points
     */
    function getFeed(address token)
        external
        view
        returns (address aggregator, uint8 decimals, uint24 feeTier, uint16 toleranceBps);

    /**
     * @notice Returns the current TOKEN/ETH price from the Chainlink oracle
     * @param token The ERC20 token address to get the price for
     * @return price The current price of the token in ETH (scaled by decimals)
     * @return decimals The number of decimals in the price value
     *
     * @dev Reverts if the token is not configured (FeedNotSet error)
     * @dev Reverts if the oracle data is stale - older than 24 hours (OracleStale error)
     * @dev Reverts if the oracle returns invalid data (OracleBad error)
     *
     * Price Interpretation:
     * - The price represents how much ETH one token is worth
     * - Example: If LINK/ETH = 0.004 ETH (with 18 decimals):
     *   - price = 4000000000000000 (4 * 10^15)
     *   - decimals = 18
     *   - Meaning: 1 LINK = 0.004 ETH
     *
     * Usage:
     * ```solidity
     * (uint256 price, uint8 decimals) = swapper.getTokenPrice(LINK_ADDRESS);
     * // To convert to human-readable: actualPrice = price / (10 ** decimals)
     * ```
     */
    function getTokenPrice(address token) external view returns (uint256 price, uint8 decimals);

    /**
     * @notice Returns the Uniswap V3 Router address
     * @return The address of the Uniswap V3 SwapRouter
     */
    function router() external view returns (address);

    /**
     * @notice Returns the WETH9 token address
     * @return The address of the Wrapped Ether (WETH9) contract
     */
    function weth() external view returns (address);

    /**
     * @notice Returns the contract owner address
     * @return The address that owns this contract
     */
    function owner() external view returns (address);
}

