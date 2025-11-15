// SPDX-License-Identifier: LGPL-3.0-only
// Created By: Art Blocks Inc. & Contributors

pragma solidity 0.8.24;

import {AbstractPMPAugmentHook} from "./abstract/AbstractPMPAugmentHook.sol";
import {AbstractPMPConfigureHook} from "./abstract/AbstractPMPConfigureHook.sol";

import {IWeb3Call} from "./interfaces/IWeb3Call.sol";
import {IPMPV0} from "./interfaces/IPMPV0.sol";
import {IPMPConfigureHook} from "./interfaces/IPMPConfigureHook.sol";
import {IPMPAugmentHook} from "./interfaces/IPMPAugmentHook.sol";
import {IGuardedEthTokenSwapper} from "./interfaces/IGuardedEthTokenSwapper.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

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
    using Strings for uint256;
    using Strings for uint128;
    using Strings for uint32;
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

    // PMPV0 contract address - hard-coded to mainnet
    address public constant PMPV0_CONTRACT_ADDRESS = 0x00000000A78E278b2d2e2935FaeBe19ee9F1FF14;
    address public immutable CORE_CONTRACT_ADDRESS;
    uint256 public immutable PROJECT_ID;
    // keeper address allowed to perform upkeep
    address public keeper;

    // additional payee receiver address allowed to assign funds to a token
    address public additionalPayeeReceiver;

    // guarded eth token swapper address
    IGuardedEthTokenSwapper public guardedEthTokenSwapper =
        IGuardedEthTokenSwapper(0x7FFc0E3F2aC6ba73ada2063D3Ad8c5aF554ED05f);

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

    struct TokenMetadata {
        TokenType tokenType;
        uint256 tokenBalance; // no decimals, raw value
        uint256[] priceHistory; // price history for the token
        uint128 createdAt; // timestamp when the token was created/first price history entry
        uint32 intervalLengthSeconds; // length of each interval in seconds (12 intervals is total length)
        bool isWithdrawn; // whether the token balance has been withdrawn (after all 12 rounds have been performed)
    }

    // mapping of token id to token metadata
    mapping(uint256 tokenId => TokenMetadata) public tokenMetadata;

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
    constructor(
        address owner_,
        address additionalPayeeReceiver_,
        address keeper_,
        address coreContract_,
        uint256 projectId_
    ) Ownable(owner_) {
        // Initialize any immutable or mutable state variables here
        additionalPayeeReceiver = additionalPayeeReceiver_;
        keeper = keeper_;
        CORE_CONTRACT_ADDRESS = coreContract_;
        PROJECT_ID = projectId_;
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
        t.tokenBalance = tokenBalance;
        t.createdAt = uint128(block.timestamp);
        t.intervalLengthSeconds = uint32(intervalLengthSeconds);

        // record the first price history entry
        // @dev we pull from the oracle for consistency
        _appendPriceHistoryEntry(tokenId, tokenType);
        // @dev price history array length is the round number, so we don't need to increment it separately
    }

    /**
     * @notice Execution logic to be executed when a token's PMP is configured.
     * @dev This hook is executed after the PMP is configured.
     * Revert here if the configuration should not be allowed.
     * @param coreContract The address of the core contract that was configured.
     * @param tokenId The tokenId of the token that was configured.
     * @param pmpInput The PMP input that was used to successfully configure the token.
     */
    function onTokenPMPConfigure(address coreContract, uint256 tokenId, IPMPV0.PMPInput calldata pmpInput)
        external
        override
    {
        // CHECKS
        // only allow if PMPV0 is calling
        require(msg.sender == PMPV0_CONTRACT_ADDRESS, "Only PMPV0 can call");
        // only allow if core contract is the configured core contract
        require(coreContract == CORE_CONTRACT_ADDRESS, "Core contract mismatch");
        // only allow if token id is from the configured project id
        require(tokenId / 1_000_000 == PROJECT_ID, "Project id mismatch");
        // only allow if pmp input key is the configured pmp input key
        require(keccak256(bytes(pmpInput.key)) == keccak256(bytes("IsWithdrawn")), "Invalid PMP input key");
        // only allow if pmp input value is currently false
        TokenMetadata storage t = tokenMetadata[tokenId];
        require(!t.isWithdrawn, "Token already withdrawn");
        // only allow setting to true
        require(pmpInput.configuredValue == bytes32(uint256(1)), "Invalid PMP input value");

        // EFFECTS
        // set the token to withdrawn
        t.isWithdrawn = true;
        // INTERACTIONS
        // send the token balance to the token owner
        address tokenOwner = IERC721(CORE_CONTRACT_ADDRESS).ownerOf(tokenId);
        // send the token balance to the token owner
        address tokenAddress = _getTokenAddressFromTokenType(t.tokenType);
        IERC20(tokenAddress).transfer(tokenOwner, t.tokenBalance);
    }

    /**
     * @notice Augment the token parameters for a given token.
     * Appends 17 items (5 metadata + 12 price history) to the token parameters.
     * - <original token params> (expect IsWithdrawn from PMPV0)
     * - tokenSymbol
     * - tokenBalance
     * - createdAt
     * - intervalLengthSeconds
     * - priceHistoryLength
     * - priceHistory0
     * - priceHistory1
     * - ...
     * - priceHistory11
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
    ) external view override returns (IWeb3Call.TokenParam[] memory augmentedTokenParams) {
        // we keep all existing token params, and append 17 items (5 metadata + 12 price history)
        uint256 originalLength = tokenParams.length;
        augmentedTokenParams = new IWeb3Call.TokenParam[](originalLength + 17);
        for (uint256 i = 0; i < originalLength; i++) {
            augmentedTokenParams[i] = tokenParams[i];
        }
        // append token token symbol
        TokenMetadata storage t = tokenMetadata[tokenId];
        augmentedTokenParams[originalLength] =
            IWeb3Call.TokenParam({key: "tokenSymbol", value: _getTokenSymbolFromTokenType(t.tokenType)});
        // append token token balance
        augmentedTokenParams[originalLength + 1] =
            IWeb3Call.TokenParam({key: "tokenBalance", value: t.tokenBalance.toString()});
        // append token token created at
        augmentedTokenParams[originalLength + 2] =
            IWeb3Call.TokenParam({key: "createdAt", value: t.createdAt.toString()});
        // append token token interval length seconds
        augmentedTokenParams[originalLength + 3] =
            IWeb3Call.TokenParam({key: "intervalLengthSeconds", value: t.intervalLengthSeconds.toString()});
        // append token token price history length
        uint256 priceHistoryLength = t.priceHistory.length;
        augmentedTokenParams[originalLength + 4] =
            IWeb3Call.TokenParam({key: "priceHistoryLength", value: priceHistoryLength.toString()});
        // append token token price history (up to 12 entries, 0 if not available)
        for (uint256 i = 0; i < 12; i++) {
            string memory priceValue;
            if (i < priceHistoryLength) {
                priceValue = t.priceHistory[i].toString();
            } else {
                priceValue = "0";
            }
            augmentedTokenParams[originalLength + 5 + i] =
                IWeb3Call.TokenParam({key: string.concat("priceHistory", i.toString()), value: priceValue});
        }

        return augmentedTokenParams;
    }

    /**
     * @notice ERC165 interface support
     * @param interfaceId The interface identifier to check
     * @return bool True if the interface is supported
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AbstractPMPAugmentHook, AbstractPMPConfigureHook)
        returns (bool)
    {
        return interfaceId == type(IPMPAugmentHook).interfaceId || interfaceId == type(IPMPConfigureHook).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ============================================
    // Chainlink Automation Functions
    // ============================================

    /**
     * @notice Checks if upkeep is needed for a token
     * WARNING: This function iterates over all tokens, and is intended for off-chain view calls only.
     * @dev input checkData is ignored, we check all tokens here
     * @dev This function is called off-chain by Chainlink Automation
     * @return upkeepNeeded Boolean indicating if upkeep is needed
     * @return performData ABI-encoded (uint256 tokenId, uint256 round) to pass to performUpkeep
     */
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        // we don't need any specific input checkData - we check all tokens here, and return the first found

        uint256 maxTokenId = latestReceivedTokenId;
        uint256 minTokenId = (latestReceivedTokenId / 1_000_000) * 1_000_000; // token 0 id
        for (uint256 tokenId_ = minTokenId; tokenId_ <= maxTokenId; tokenId_++) {
            // Get the current round for this token
            TokenMetadata storage t = tokenMetadata[tokenId_];
            uint256 currentRound = t.priceHistory.length;
            // if current round is 12, we know this token has already been fully updated
            if (currentRound == 12) {
                continue;
            }
            // if block timestamp is greater than the initial timestamp + interval length * current round, we need to perform upkeep
            if (block.timestamp > t.createdAt + t.intervalLengthSeconds * currentRound) {
                upkeepNeeded = true;
                performData = abi.encode(tokenId_, currentRound);
                return (upkeepNeeded, performData);
            }
        }
        // no upkeep needed

        return (false, "");
    }

    /**
     * @notice Performs the upkeep for a token
     * @dev This function is called on-chain by Chainlink Automation
     * @param performData ABI-encoded (uint256 tokenId, uint256 round)
     */
    function performUpkeep(bytes calldata performData) external override onlyKeeper {
        // CHECKS
        // Decode tokenId and round
        (uint256 tokenId, uint256 round) = abi.decode(performData, (uint256, uint256));
        // Verify this is the current round (prevents stale upkeeps)
        TokenMetadata storage t = tokenMetadata[tokenId];
        require(round == t.priceHistory.length, "Stale upkeep");
        // verify block timestamp requirements
        require(block.timestamp > t.createdAt + t.intervalLengthSeconds * round, "Block timestamp requirements not met");

        // EFFECTS
        // Perform the actual upkeep for the token
        // append a price history entry
        _appendPriceHistoryEntry(tokenId, t.tokenType);
        // @dev price history array length is the round number, so we don't need to increment it separately

        // Emit event
        emit UpkeepPerformed(tokenId, round, block.timestamp);
    }

    // ============================================
    // Internal Helper Functions
    // ============================================

    function _getIntervalLengthSecondsFromTokenHash(bytes32 tokenHash) internal view virtual returns (uint32) {
        // get value between 0 and 7 from the token hash
        uint256 value = uint256(tokenHash) % 16;
        // return the interval length in seconds
        if (value == 0) return 1 days; // 11 days total rare
        if (value <= 2) return 3 days; // 33 days total
        if (value <= 4) return 5 days; // 60 days total
        if (value <= 7) return 7 days; // 77 days total common
        if (value <= 10) return 9 days; // 99 days total common
        if (value <= 12) return 15 days; // 165 days total
        if (value <= 14) return 21 days; // 231 days total
        if (value <= 15) return 33 days; // 363 days total rare
        revert("Invalid value");
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
        (uint256 price,) = guardedEthTokenSwapper.getTokenPrice(tokenAddress);
        // populate result in tokenMetadata by appending to the price history
        tokenMetadata[tokenId].priceHistory.push(price);
    }

    /**
     * @notice Get the token address from the token type
     * @dev Internal function to get the token address from the token type
     * @param tokenType The token type to get the address for
     * @return tokenAddress The token address
     */
    function _getTokenAddressFromTokenType(TokenType tokenType) internal pure returns (address) {
        if (tokenType == TokenType.ONEINCH) return 0x111111111117dC0aa78b770fA6A738034120C302;
        if (tokenType == TokenType.AAVE) return 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
        if (tokenType == TokenType.APE) return 0x4d224452801ACEd8B2F0aebE155379bb5D594381;
        if (tokenType == TokenType.BAT) return 0x0D8775F648430679A709E98d2b0Cb6250d2887EF;
        if (tokenType == TokenType.COMP) return 0xc00e94Cb662C3520282E6f5717214004A7f26888;
        if (tokenType == TokenType.CRV) return 0xD533a949740bb3306d119CC777fa900bA034cd52;
        if (tokenType == TokenType.USDT) return 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        if (tokenType == TokenType.LDO) return 0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32;
        if (tokenType == TokenType.LINK) return 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        if (tokenType == TokenType.MKR) return 0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2;
        if (tokenType == TokenType.SHIB) return 0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE;
        if (tokenType == TokenType.UNI) return 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
        if (tokenType == TokenType.WBTC) return 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        if (tokenType == TokenType.ZRX) return 0xE41d2489571d322189246DaFA5ebDe1F4699F498;
        revert("Invalid token type");
    }

    function _getTokenSymbolFromTokenType(TokenType tokenType) internal pure returns (string memory) {
        if (tokenType == TokenType.ONEINCH) return "1INCH";
        if (tokenType == TokenType.AAVE) return "AAVE";
        if (tokenType == TokenType.APE) return "APE";
        if (tokenType == TokenType.BAT) return "BAT";
        if (tokenType == TokenType.COMP) return "COMP";
        if (tokenType == TokenType.CRV) return "CRV";
        if (tokenType == TokenType.USDT) return "USDT";
        if (tokenType == TokenType.LDO) return "LDO";
        if (tokenType == TokenType.LINK) return "LINK";
        if (tokenType == TokenType.MKR) return "MKR";
        if (tokenType == TokenType.SHIB) return "SHIB";
        if (tokenType == TokenType.UNI) return "UNI";
        if (tokenType == TokenType.WBTC) return "WBTC";
        if (tokenType == TokenType.ZRX) return "ZRX";
        revert("Invalid token type");
    }
}

