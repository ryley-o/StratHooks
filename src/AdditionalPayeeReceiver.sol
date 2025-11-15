// SPDX-License-Identifier: LGPL-3.0-only
// Created By: Art Blocks Inc. & Contributors

pragma solidity 0.8.24;

/**
 * @title AdditionalPayeeReceiver
 * @author Art Blocks Inc. & Contributors
 * @notice This contract receives funds from mints and distributes them appropriately.
 * @dev Only accepts funds from the configured allowed sender (core contract).
 */
contract AdditionalPayeeReceiver {
    // ============================================
    // Events
    // ============================================

    /**
     * @notice Emitted when funds are received
     * @param sender The address that sent the funds
     * @param amount The amount of funds received
     * @param tokenId The token ID associated with the mint
     */
    event FundsReceived(address indexed sender, uint256 amount, uint256 indexed tokenId);

    // ============================================
    // Immutable State Variables
    // ============================================

    /// @notice The only address allowed to send funds to this contract
    address public immutable allowedSender;

    /// @notice The core contract address for this project
    address public immutable coreContract;

    /// @notice The project ID for this project
    uint256 public immutable projectId;

    // ============================================
    // Errors
    // ============================================

    error UnauthorizedSender(address sender);
    error InvalidTokenId(uint256 tokenId);

    // ============================================
    // Constructor
    // ============================================

    /**
     * @notice Constructor
     * @param allowedSender_ The address of the only allowed sender
     * @param coreContract_ The address of the core contract
     * @param projectId_ The project ID
     */
    constructor(address allowedSender_, address coreContract_, uint256 projectId_) {
        allowedSender = allowedSender_;
        coreContract = coreContract_;
        projectId = projectId_;
    }

    // ============================================
    // Receive Function
    // ============================================

    /**
     * @notice Receive function that executes when funds are sent to this contract
     * @dev Only accepts funds from the allowed sender
     * @dev Placeholder logic - will be implemented with proper distribution logic
     */
    receive() external payable {
        // CHECKS
        // Only accept funds from the allowed sender
        if (msg.sender != allowedSender) {
            revert UnauthorizedSender(msg.sender);
        }

        // EFFECTS & INTERACTIONS
        // TODO: Implement proper logic to:
        // 1. Determine the token ID from the transaction context
        // 2. Call StratHooks.receiveFunds() with the token ID and hash
        // 3. Distribute remaining funds appropriately

        // Placeholder: emit event for now
        uint256 tokenId = 0; // TODO: Get actual token ID from context
        emit FundsReceived(msg.sender, msg.value, tokenId);

        // Placeholder implementation - funds are held in this contract
        // In production, this should forward funds to StratHooks or other recipients
    }

    // ============================================
    // View Functions
    // ============================================

    /**
     * @notice Get the contract balance
     * @return The current balance of this contract
     */
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }
}

