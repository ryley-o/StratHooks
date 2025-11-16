// SPDX-License-Identifier: LGPL-3.0-only
// Created By: Art Blocks Inc. & Contributors

pragma solidity 0.8.24;

import {IGenArt721CoreContractV3_Base} from "./interfaces/IGenArt721CoreContractV3_Base.sol";
import {StratHooks} from "./StratHooks.sol";

/**
 * @title AdditionalPayeeReceiver
 * @author Art Blocks Inc. & Contributors
 * @notice This contract receives funds from mints and distributes them appropriately.
 * Assumes the core contract will only mint one token at a time, so latest invocation is mint to be funded atomically.
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

    /// @notice The strat hooks contract address for this project
    address public immutable stratHooks;

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
     * @param allowedSender_ The address of the only allowed sender - expected to be the minter contract
     * @param coreContract_ The address of the core contract
     * @param projectId_ The project ID
     * @param stratHooks_ The address of the strat hooks contract
     */
    constructor(address allowedSender_, address coreContract_, uint256 projectId_, address stratHooks_) {
        allowedSender = allowedSender_;
        coreContract = coreContract_;
        projectId = projectId_;
        stratHooks = stratHooks_;
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
        // get most recently minted token id on our core contract's project
        (uint256 invocations,,,,,) = IGenArt721CoreContractV3_Base(coreContract).projectStateData(projectId);
        uint256 tokenId = projectId * 1_000_000 + invocations - 1;
        bytes32 tokenHash = IGenArt721CoreContractV3_Base(coreContract).tokenIdToHash(tokenId);

        // EFFECTS & INTERACTIONS
        // forward on the funds to StratHooks with appropriate metadata
        StratHooks(stratHooks).receiveFunds{value: msg.value}({tokenId: tokenId, tokenHash: tokenHash});
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

