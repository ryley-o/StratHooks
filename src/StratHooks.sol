// SPDX-License-Identifier: LGPL-3.0-only
// Created By: Art Blocks Inc. & Contributors

pragma solidity 0.8.22;

import {AbstractPMPAugmentHook} from "./abstract/AbstractPMPAugmentHook.sol";
import {AbstractPMPConfigureHook} from "./abstract/AbstractPMPConfigureHook.sol";

import {IWeb3Call} from "./interfaces/IWeb3Call.sol";
import {IPMPV0} from "./interfaces/IPMPV0.sol";
import {IPMPConfigureHook} from "./interfaces/IPMPConfigureHook.sol";
import {IPMPAugmentHook} from "./interfaces/IPMPAugmentHook.sol";

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

    // latest received token id
    uint256 public latestReceivedTokenId;

    address public additionalPayeeReceiver;

    // TODO - make this in sync
    enum TokenType {
        ZRX,
        LINK,
        USDT,
        BAT,
        COMP,
        CRV,
        AAVE,
        UNI,
        WBTC
    }

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
    
    // Example: GuardedEthTokenSwapper integration
    // import {IGuardedEthTokenSwapper} from "guarded-eth-token-swapper/IGuardedEthTokenSwapper.sol";
    // address public constant GUARDED_SWAPPER = 0x96E6a25565E998C6EcB98a59CC87F7Fc5Ed4D7b0;

    modifier onlyAdditionalPayeeReceiver() {
        require(msg.sender == additionalPayeeReceiver, "Not additional payee receiver");
        _;
    }

    /**
     * @notice Constructor
     * @dev Add any initialization parameters needed for your hooks
     */
    constructor(address owner_, address additionalPayeeReceiver_) Ownable(owner_) {
        // Initialize any immutable state variables here
        additionalPayeeReceiver = additionalPayeeReceiver_;
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
        // build the token metadata
        TokenType tokenType = TokenType(uint256(tokenHash) % 9); // 9 token types
        uint256 intervalLengthSeconds = _getIntervalLengthSecondsFromTokenHash(tokenHash);
        uint256 tokenBalance = 1; // TODO - implement swap
        uint256 firstPriceHistoryEntry = tokenBalance/msg.value; // TODO what to record?
        tokenMetadata[tokenId] = TokenMetadata({
            tokenType: tokenType,
            tokenBalance: msg.value,
            priceHistory: new uint256[](12),
            createdAt: uint128(block.timestamp),
            intervalLengthSeconds: 12
        });
        // record the first price history entry
        tokenMetadata[tokenId].priceHistory[0] = firstPriceHistoryEntry;

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
    function performUpkeep(bytes calldata performData) external override {
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
        
        // This is where you'd implement your strategy-specific logic
        // For example, calling GuardedEthTokenSwapper, updating PMPs, etc.
    }

    function _getIntervalLengthSecondsFromTokenHash(bytes32 tokenHash) internal view virtual returns (uint32) {
        // TODO - implement this better, this is a placeholder
        // 5 days + 7 days * (tokenHash % 10)
        return uint32((5 days) + (7 days * (uint256(tokenHash) % 10)));
    }
}

