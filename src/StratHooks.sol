// SPDX-License-Identifier: LGPL-3.0-only
// Created By: Art Blocks Inc. & Contributors

pragma solidity 0.8.22;

import {AbstractPMPAugmentHook} from "./abstract/AbstractPMPAugmentHook.sol";
import {AbstractPMPConfigureHook} from "./abstract/AbstractPMPConfigureHook.sol";

import {IWeb3Call} from "./interfaces/IWeb3Call.sol";
import {IPMPV0} from "./interfaces/IPMPV0.sol";
import {IPMPConfigureHook} from "./interfaces/IPMPConfigureHook.sol";
import {IPMPAugmentHook} from "./interfaces/IPMPAugmentHook.sol";
import {IGuardedEthTokenSwapper} from "./interfaces/IGuardedEthTokenSwapper.sol";

import {AutomationCompatibleInterface} from "@chainlink/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title StratHooks
 * @author Art Blocks Inc. & Contributors
 * @notice This hook provides custom PostMintParameter functionality for an Art Blocks project.
 * It supports both augment and configure hooks to enable custom parameter handling.
 * Configure hooks run during configuration to validate settings.
 * Augment hooks run during reads to inject or modify parameters.
 * 
 * Implements Chainlink Automation for automated upkeep of token states.
 */
contract StratHooks is AbstractPMPAugmentHook, AbstractPMPConfigureHook, AutomationCompatibleInterface, Ownable {
    // ============================================
    // Events
    // ============================================
    
    /**
     * @notice Emitted when upkeep is performed for a token
     * @param tokenId The token ID that was updated
     * @param round The round number for idempotency
     * @param timestamp The timestamp when upkeep was performed
     */
    event UpkeepPerformed(uint256 indexed tokenId, uint256 indexed round, uint256 timestamp);
    
    // ============================================
    // State Variables
    // ============================================

    // keeper address allowed to perform upkeep
    address public keeper;

    // additional payee receiver address allowed to assign funds to a token
    address public additionalPayeeReceiver;

    // guarded eth token swapper address
    IGuardedEthTokenSwapper public guardedEthTokenSwapper = IGuardedEthTokenSwapper(0x7FFc0E3F2aC6ba73ada2063D3Ad8c5aF554ED05f);

    // latest received token id
    uint256 public latestReceivedTokenId;

    // 14 token types, configured in GuardedEthTokenSwapper
    enum TokenType {
        ONEINCH,
        AAVE,
        APE,
        BAT,
        COMP,
        CRV,
        USDT,
        LDO,
        LINK,
        MKR,
        SHIB,
        UNI,
        WBTC,
        ZRX
    }

    address[] public tokenAddresses = [
        0x111111111117dC0aa78b770fA6A738034120C302, // 1INCH
        0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9, // AAVE
        0x4d224452801ACEd8B2F0aebE155379bb5D594381, // APE
        0x0D8775F648430679A709E98d2b0Cb6250d2887EF, // BAT
        0xc00e94Cb662C3520282E6f5717214004A7f26888, // COMP
        0xD533a949740bb3306d119CC777fa900bA034cd52, // CRV
        0xdAC17F958D2ee523a2206206994597C13D831ec7, // USDT
        0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32, // LDO
        0x514910771AF9Ca656af840dff83E8264EcF986CA, // LINK
        0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2, // MKR
        0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE, // SHIB
        0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984, // UNI
        0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599, // WBTC
        0xE41d2489571d322189246DaFA5ebDe1F4699F498 // ZRX
    ];

    struct TokenMetadata {
        TokenType tokenType;
        uint256 tokenBalance; // no decimals, raw value
        uint256[] priceHistory; // price history for the token
        uint128 createdAt; // timestamp when the token was created/first price history entry
        uint32 intervalLengthSeconds; // length of each interval in seconds (12 intervals is total length)
    }
    
    // mapping of token id to token metadata
    mapping(uint256 tokenId => TokenMetadata) public tokenMetadata;

    // Track the current round for each token (for idempotency)
    mapping(uint256 => uint256) public tokenRound;
    
    // Track the last upkeep timestamp for each token
    mapping(uint256 => uint256) public lastUpkeepTimestamp;
    
    // Track whether a specific round has been executed for a token
    mapping(uint256 => mapping(uint256 => bool)) public roundExecuted;

    // modifier to only allow the additional payee receiver to receive funds
    modifier onlyAdditionalPayeeReceiver() {
        require(msg.sender == additionalPayeeReceiver, "Not additional payee receiver");
        _;
    }

    // modifier to only allow the keeper to perform upkeep
    modifier onlyKeeper() {
        require(msg.sender == keeper, "Not keeper");
        _;
    }

    /**
     * @notice Constructor
     * @dev Add any initialization parameters needed for your hooks
     */
    constructor(address owner_, address additionalPayeeReceiver_, address keeper_) Ownable(owner_) {
        // Initialize any immutable or mutable state variables here
        additionalPayeeReceiver = additionalPayeeReceiver_;
        keeper = keeper_;
    }

    /**
     * @notice Set the keeper address
     * @dev Only the owner can set the keeper address
     * @param newKeeper The new keeper address
     */
    function setKeeper(address newKeeper) external onlyOwner {
        keeper = newKeeper;
    }

    /**
     * @notice Set the additional payee receiver address
     * @dev Only the owner can set the additional payee receiver address
     * @param newAdditionalPayeeReceiver The new additional payee receiver address
     */
    function setAdditionalPayeeReceiver(address newAdditionalPayeeReceiver) external onlyOwner {
        additionalPayeeReceiver = newAdditionalPayeeReceiver;
    }

    /**
     * @notice Set the guarded eth token swapper address
     * @dev Only the owner can set the guarded eth token swapper address
     * @param newGuardedEthTokenSwapper The new guarded eth token swapper address
     */
    function setGuardedEthTokenSwapper(address newGuardedEthTokenSwapper) external onlyOwner {
        guardedEthTokenSwapper = IGuardedEthTokenSwapper(newGuardedEthTokenSwapper);
    }

    /**
     * @notice Receive funds for a new token during mint, initializes the token metadata
     * @dev Called by the additional payee receiver during mint
     * @param tokenId The token id to receive funds for
     * @param tokenHash The hash of the token to receive funds for
     * @dev msg.value is the appropriate proportion of the mint price for the token
     */
    function receiveFunds(uint256 tokenId, bytes32 tokenHash) external payable onlyAdditionalPayeeReceiver {
        // CHECKS
        // only additional payee receiver may call
        require(latestReceivedTokenId == 0 || latestReceivedTokenId == tokenId - 1, "Invalid token id");

        // EFFECTS
        latestReceivedTokenId = tokenId;
        // assign prng values
        TokenType tokenType = TokenType(uint256(tokenHash) % 14); // 14 token types
        address tokenAddress = _getTokenAddressFromTokenType(tokenType);
        uint32 intervalLengthSeconds = _getIntervalLengthSecondsFromTokenHash(tokenHash);
        // assign token metadata values
        uint256 tokenBalance = guardedEthTokenSwapper.swapEthForToken({
            token: tokenAddress,
            slippageBps: 200, // 2% slippage
            deadline: block.timestamp + 600 // 10 minutes
        });
        TokenMetadata storage t = tokenMetadata[tokenId];
        t.tokenType = tokenType;
        t. tokenBalance = tokenBalance;
        t.createdAt = uint128(block.timestamp);
        t. intervalLengthSeconds = uint32(intervalLengthSeconds);
        
        // record the first price history entry
        // @dev we pull from the oracle for consistency
        _appendPriceHistoryEntry(tokenId, tokenType);

    }

    /**
     * @notice Append a price history entry to the token metadata.
     * Internal function - assumes checks have been performed, blindly appends to the price history.
     * @dev Internal function to append a price history entry to the token metadata
     * @param tokenId The token id to append the price history entry for
     * @param tokenType The token type to append the price history entry for
     */
    function _appendPriceHistoryEntry(uint256 tokenId, TokenType tokenType) internal {
        // @dev we pull from the oracle for consistency
        address tokenAddress = _getTokenAddressFromTokenType(tokenType);
        (uint256 price, ) = guardedEthTokenSwapper.getTokenPrice(tokenAddress);
        // populate result in tokenMetadata by appending to the price history
        tokenMetadata[tokenId].priceHistory.push(price);
    }

    /**
     * @notice Get the token address from the token type
     * @dev Internal function to get the token address from the token type
     * @param tokenType The token type to get the address for
     * @return tokenAddress The token address
     */
    function _getTokenAddressFromTokenType(TokenType tokenType) internal view returns (address) {
        return tokenAddresses[uint256(tokenType)];
    }

    /**
     * @notice Execution logic to be executed when a token's PMP is configured.
     * @dev This hook is executed after the PMP is configured.
     * Revert here if the configuration should not be allowed.
     * @param coreContract The address of the core contract that was configured.
     * @param tokenId The tokenId of the token that was configured.
     * @param pmpInput The PMP input that was used to successfully configure the token.
     */
    function onTokenPMPConfigure(
        address coreContract,
        uint256 tokenId,
        IPMPV0.PMPInput calldata pmpInput
    ) external view override {
        // Add your custom validation logic here
        // This runs when a user configures PMPs for their token
        
        // Example: Check if specific keys are being configured
        // if (keccak256(bytes(pmpInput.key)) == _HASHED_KEY_EXAMPLE) {
        //     // Validate the configuration
        //     require(someCondition, "Configuration validation failed");
        // }
        
        // If you don't revert, the configuration is accepted
    }

    /**
     * @notice Augment the token parameters for a given token.
     * @dev This hook is called when a token's PMPs are read.
     * @dev This must return all desired tokenParams, not just additional data.
     * @param coreContract The address of the core contract being queried.
     * @param tokenId The tokenId of the token being queried.
     * @param tokenParams The token parameters for the queried token.
     * @return augmentedTokenParams The augmented token parameters.
     */
    function onTokenPMPReadAugmentation(
        address coreContract,
        uint256 tokenId,
        IWeb3Call.TokenParam[] calldata tokenParams
    )
        external
        view
        override
        returns (IWeb3Call.TokenParam[] memory augmentedTokenParams)
    {
        // Add your custom augmentation logic here
        // This runs when token parameters are read
        
        // Example: Simply return the original params (no augmentation)
        augmentedTokenParams = tokenParams;
        
        // Or you can modify/inject new parameters:
        // 1. Create a new array with space for additional params
        // 2. Copy over existing params (optionally filtering some out)
        // 3. Add new params
        // 4. Return the augmented array
        
        return augmentedTokenParams;
    }

    /**
     * @notice ERC165 interface support
     * @param interfaceId The interface identifier to check
     * @return bool True if the interface is supported
     */
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(AbstractPMPAugmentHook, AbstractPMPConfigureHook)
        returns (bool)
    {
        return
            interfaceId == type(IPMPAugmentHook).interfaceId ||
            interfaceId == type(IPMPConfigureHook).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ============================================
    // Chainlink Automation Functions
    // ============================================

    /**
     * @notice Checks if upkeep is needed for a token
     * @dev This function is called off-chain by Chainlink Automation
     * @param checkData ABI-encoded uint256 tokenId
     * @return upkeepNeeded Boolean indicating if upkeep is needed
     * @return performData ABI-encoded (uint256 tokenId, uint256 round) to pass to performUpkeep
     */
    function checkUpkeep(bytes calldata checkData)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // Decode the tokenId from checkData
        uint256 tokenId = abi.decode(checkData, (uint256));
        
        // Get the current round for this token
        uint256 currentRound = tokenRound[tokenId];
        
        // Check if this round has already been executed
        bool alreadyExecuted = roundExecuted[tokenId][currentRound];
        
        // Determine if upkeep is needed
        // Add your custom logic here to determine when upkeep should be performed
        // Example conditions:
        // - Time-based: enough time has passed since last upkeep
        // - Event-based: some condition has changed
        // - State-based: token is in a state requiring action
        
        // Example: Perform upkeep if not yet executed for current round
        // In a real implementation, you'd check specific conditions
        upkeepNeeded = !alreadyExecuted && _shouldPerformUpkeep(tokenId);
        
        if (upkeepNeeded) {
            // Encode tokenId and current round for idempotency
            performData = abi.encode(tokenId, currentRound);
        }
        
        return (upkeepNeeded, performData);
    }

    /**
     * @notice Performs the upkeep for a token
     * @dev This function is called on-chain by Chainlink Automation
     * @param performData ABI-encoded (uint256 tokenId, uint256 round)
     */
    function performUpkeep(bytes calldata performData) external override onlyKeeper() {
        // Decode tokenId and round
        (uint256 tokenId, uint256 round) = abi.decode(performData, (uint256, uint256));
        
        // Verify this is the current round (prevents stale upkeeps)
        require(round == tokenRound[tokenId], "Stale upkeep");
        
        // Ensure idempotency: check if this round was already executed
        require(!roundExecuted[tokenId][round], "Round already executed");
        
        // Mark this round as executed
        roundExecuted[tokenId][round] = true;
        
        // Update last upkeep timestamp
        lastUpkeepTimestamp[tokenId] = block.timestamp;
        
        // Increment the round for next upkeep
        tokenRound[tokenId]++;
        
        // Perform the actual upkeep logic here
        _performTokenUpkeep(tokenId, round);
        
        // Emit event
        emit UpkeepPerformed(tokenId, round, block.timestamp);
    }

    // ============================================
    // Internal Helper Functions
    // ============================================

    /**
     * @notice Determines if upkeep should be performed for a token
     * @dev Override this function with your custom logic
     * @param tokenId The token ID to check
     * @return bool True if upkeep should be performed
     */
    function _shouldPerformUpkeep(uint256 tokenId) internal view virtual returns (bool) {
        // Add your custom condition logic here
        // Example: Check if enough time has passed
        // Example: Check if token state requires action
        // Example: Check external conditions
        
        // Default implementation: always return false
        // Override this in your implementation
        return false;
    }

    /**
     * @notice Performs the actual upkeep logic for a token
     * @dev Override this function with your custom upkeep actions
     * @param tokenId The token ID to perform upkeep for
     * @param round The round number (for reference in your logic)
     */
    function _performTokenUpkeep(uint256 tokenId, uint256 round) internal virtual {
        // Add your custom upkeep logic here
        // Example: Execute a token swap
        // Example: Update token parameters
        // Example: Trigger external actions
        // Example: Call GuardedEthTokenSwapper
        // This is where you'd implement your strategy-specific logic
        // For example, calling GuardedEthTokenSwapper, updating PMPs, etc.
    }

    function _getIntervalLengthSecondsFromTokenHash(bytes32 tokenHash) internal view virtual returns (uint32) {
        // TODO - implement this better, this is a placeholder
        // 5 days + 7 days * (tokenHash % 10)
        return uint32((5 days) + (7 days * (uint256(tokenHash) % 10)));
    }
}

