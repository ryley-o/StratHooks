// SPDX-License-Identifier: LGPL-3.0-only
// Created By: Art Blocks Inc. & Contributors

pragma solidity 0.8.22;

import {AbstractPMPAugmentHook} from "./abstract/AbstractPMPAugmentHook.sol";
import {AbstractPMPConfigureHook} from "./abstract/AbstractPMPConfigureHook.sol";

import {IWeb3Call} from "./interfaces/IWeb3Call.sol";
import {IPMPV0} from "./interfaces/IPMPV0.sol";
import {IPMPConfigureHook} from "./interfaces/IPMPConfigureHook.sol";
import {IPMPAugmentHook} from "./interfaces/IPMPAugmentHook.sol";

/**
 * @title StratHooks
 * @author Art Blocks Inc. & Contributors
 * @notice This hook provides custom PostMintParameter functionality for an Art Blocks project.
 * It supports both augment and configure hooks to enable custom parameter handling.
 * Configure hooks run during configuration to validate settings.
 * Augment hooks run during reads to inject or modify parameters.
 */
contract StratHooks is AbstractPMPAugmentHook, AbstractPMPConfigureHook {
    // Add your custom state variables here
    // Example:
    // address public immutable SOME_EXTERNAL_CONTRACT;
    // bytes32 internal constant _HASHED_KEY_EXAMPLE = keccak256("Example Key");
    
    // Example: GuardedEthTokenSwapper integration
    // import {IGuardedEthTokenSwapper} from "guarded-eth-token-swapper/IGuardedEthTokenSwapper.sol";
    // address public constant GUARDED_SWAPPER = 0x96E6a25565E998C6EcB98a59CC87F7Fc5Ed4D7b0;

    /**
     * @notice Constructor
     * @dev Add any initialization parameters needed for your hooks
     */
    constructor() {
        // Initialize any immutable state variables here
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

    // Add any additional helper functions below this line
}

