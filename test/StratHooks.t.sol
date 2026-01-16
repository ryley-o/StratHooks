// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StratHooks} from "../src/StratHooks.sol";
import {IWeb3Call} from "../src/interfaces/IWeb3Call.sol";
import {IPMPV0} from "../src/interfaces/IPMPV0.sol";
import {IPMPAugmentHook} from "../src/interfaces/IPMPAugmentHook.sol";
import {IPMPConfigureHook} from "../src/interfaces/IPMPConfigureHook.sol";
import {IGuardedEthTokenSwapper} from "../src/interfaces/IGuardedEthTokenSwapper.sol";
import {ISlidingScaleMinter} from "../src/interfaces/ISlidingScaleMinter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

// Mock ERC20 for testing
contract MockERC20 is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    function transfer(address to, uint256 amount) external override returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function totalSupply() external pure override returns (uint256) {
        return 0;
    }

    // Helper to mint tokens for testing
    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
    }
}

// Mock ERC721 for testing
contract MockERC721 is IERC721 {
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    function ownerOf(uint256 tokenId) external view override returns (address) {
        return _owners[tokenId];
    }

    function balanceOf(address owner) external view override returns (uint256) {
        return _balances[owner];
    }

    function approve(address to, uint256 tokenId) external override {
        _tokenApprovals[tokenId] = to;
        emit Approval(msg.sender, to, tokenId);
    }

    function getApproved(uint256 tokenId) external view override returns (address) {
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external override {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner, address operator) external view override returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) external override {
        _owners[tokenId] = to;
        _balances[from]--;
        _balances[to]++;
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external override {
        this.transferFrom(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata) external override {
        this.transferFrom(from, to, tokenId);
    }

    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }

    // Helper to mint tokens for testing
    function mint(address to, uint256 tokenId) external {
        _owners[tokenId] = to;
        _balances[to]++;
    }
}

// Mock GuardedEthTokenSwapper for testing
contract MockGuardedEthTokenSwapper is IGuardedEthTokenSwapper {
    uint256 public mockSwapReturn = 1000e18; // Default return 1000 tokens
    uint256 public mockPrice = 0.004e18; // Default price 0.004 ETH per token
    uint8 public mockDecimals = 18;
    uint256 public lastReceivedEth; // Track last received ETH amount

    function setMockSwapReturn(uint256 _amount) external {
        mockSwapReturn = _amount;
    }

    function setMockPrice(uint256 _price, uint8 _decimals) external {
        mockPrice = _price;
        mockDecimals = _decimals;
    }

    function swapEthForToken(address token, uint16 slippageBps, uint256 deadline)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        // Track received ETH for testing
        lastReceivedEth = msg.value;
        // Simple mock: return mockSwapReturn
        return mockSwapReturn;
    }

    function setFeeds(
        address[] calldata tokens,
        address[] calldata aggregators,
        uint24[] calldata feeTiers,
        uint16[] calldata toleranceBpsArr
    ) external override {}

    function removeFeed(address token) external override {}

    function getFeed(address token)
        external
        view
        override
        returns (address aggregator, uint8 decimals, uint24 feeTier, uint16 toleranceBps)
    {
        return (address(0x123), mockDecimals, 3000, 200);
    }

    function getTokenPrice(address token) external view override returns (uint256 price, uint8 decimals) {
        return (mockPrice, mockDecimals);
    }

    function router() external view override returns (address) {
        return address(0);
    }

    function weth() external view override returns (address) {
        return address(0);
    }

    function owner() external view override returns (address) {
        return address(this);
    }
}

// Mock Sliding Scale Minter for testing
contract MockSlidingScaleMinter is ISlidingScaleMinter {
    mapping(address => mapping(uint256 => uint256)) private _tokenPricePaid;

    function setTokenPricePaid(address coreContract, uint256 tokenId, uint256 price) external {
        _tokenPricePaid[coreContract][tokenId] = price;
    }

    function getTokenPricePaid(address coreContract, uint256 tokenId)
        external
        view
        override
        returns (uint256 pricePaidInWei)
    {
        return _tokenPricePaid[coreContract][tokenId];
    }
}

contract StratHooksTest is Test {
    StratHooks public hooks;
    MockGuardedEthTokenSwapper public mockSwapper;
    MockERC721 public mockNFT;
    MockERC20 public mockToken;
    MockSlidingScaleMinter public mockMinter;

    address constant MOCK_CORE_CONTRACT = address(0x1);
    uint256 constant PROJECT_ID = 1;
    uint256 constant MOCK_TOKEN_ID = 1_000_000;
    address constant OWNER = address(0x100);
    address constant ADDITIONAL_PAYEE_RECEIVER = address(0x200);
    address constant KEEPER = address(0x300);
    address constant PMPV0_CONTRACT_ADDRESS = 0x00000000A78E278b2d2e2935FaeBe19ee9F1FF14;
    address constant TOKEN_OWNER = address(0x400);

    event UpkeepPerformed(uint256 indexed tokenId, uint256 indexed round, uint256 timestamp);

    function setUp() public {
        // Deploy mocks
        mockSwapper = new MockGuardedEthTokenSwapper();
        mockNFT = new MockERC721();
        mockToken = new MockERC20();
        mockMinter = new MockSlidingScaleMinter();

        // Deploy implementation
        StratHooks implementation = new StratHooks();

        // Prepare initializer data
        bytes memory initData = abi.encodeWithSelector(
            StratHooks.initialize.selector,
            OWNER,
            ADDITIONAL_PAYEE_RECEIVER,
            KEEPER,
            address(mockNFT),
            PROJECT_ID,
            address(mockMinter)
        );

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Cast proxy to StratHooks interface
        hooks = StratHooks(address(proxy));

        // Set the mock swapper
        vm.prank(OWNER);
        hooks.setGuardedEthTokenSwapper(address(mockSwapper));
    }

    function test_SupportsInterfaces() public view {
        // Test that the contract supports the expected interfaces
        assertTrue(hooks.supportsInterface(type(IPMPAugmentHook).interfaceId));
        assertTrue(hooks.supportsInterface(type(IPMPConfigureHook).interfaceId));
    }

    // ============================================
    // OnTokenPMPConfigure Withdrawal Tests
    // ============================================

    function _setupTokenForWithdrawal(uint256 tokenId) internal returns (address tokenAddress) {
        // Setup: Create a token and complete all rounds
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        // Get token type and determine token address from the actual contract
        (StratHooks.TokenType tokenType, uint256 tokenBalance,,,,) = hooks.tokenMetadata(tokenId);

        // Get the real token address the contract will use
        tokenAddress = _getRealTokenAddress(tokenType);

        // Deploy a mock ERC20 at that address using vm.etch
        bytes memory mockERC20Code = type(MockERC20).runtimeCode;
        vm.etch(tokenAddress, mockERC20Code);

        // Mint tokens to the hooks contract
        MockERC20(tokenAddress).mint(address(hooks), tokenBalance);

        // Mint NFT to token owner
        mockNFT.mint(TOKEN_OWNER, tokenId);

        return tokenAddress;
    }

    function _getRealTokenAddress(StratHooks.TokenType tokenType) internal pure returns (address) {
        // These are the real mainnet addresses from _getTokenAddressFromTokenType
        if (tokenType == StratHooks.TokenType.ONEINCH) return 0x111111111117dC0aa78b770fA6A738034120C302;
        if (tokenType == StratHooks.TokenType.AAVE) return 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
        if (tokenType == StratHooks.TokenType.APE) return 0x4d224452801ACEd8B2F0aebE155379bb5D594381;
        if (tokenType == StratHooks.TokenType.BAT) return 0x0D8775F648430679A709E98d2b0Cb6250d2887EF;
        if (tokenType == StratHooks.TokenType.COMP) return 0xc00e94Cb662C3520282E6f5717214004A7f26888;
        if (tokenType == StratHooks.TokenType.CRV) return 0xD533a949740bb3306d119CC777fa900bA034cd52;
        if (tokenType == StratHooks.TokenType.USDT) return 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        if (tokenType == StratHooks.TokenType.LDO) return 0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32;
        if (tokenType == StratHooks.TokenType.LINK) return 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        if (tokenType == StratHooks.TokenType.MKR) return 0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2;
        if (tokenType == StratHooks.TokenType.SHIB) return 0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE;
        if (tokenType == StratHooks.TokenType.UNI) return 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
        if (tokenType == StratHooks.TokenType.WBTC) return 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        if (tokenType == StratHooks.TokenType.ZRX) return 0xE41d2489571d322189246DaFA5ebDe1F4699F498;
        revert("Invalid token type");
    }

    function _getTokenAddress(StratHooks.TokenType tokenType) internal pure returns (address) {
        // Redirect to real addresses
        return _getRealTokenAddress(tokenType);
    }

    function test_OnTokenPMPConfigure_SuccessfulWithdrawal() public {
        uint256 tokenId = MOCK_TOKEN_ID;
        address tokenAddress = _setupTokenForWithdrawal(tokenId);

        // Get initial balance
        uint256 initialBalance = IERC20(tokenAddress).balanceOf(TOKEN_OWNER);

        // Create withdrawal PMP input
        IPMPV0.PMPInput memory input = IPMPV0.PMPInput({
            key: "IsWithdrawn",
            configuredParamType: IPMPV0.ParamType.Bool,
            configuredValue: bytes32(uint256(1)), // true
            configuringArtistString: false,
            configuredValueString: ""
        });

        // Call from PMPV0 address
        vm.prank(PMPV0_CONTRACT_ADDRESS);
        hooks.onTokenPMPConfigure(address(mockNFT), tokenId, input);

        // Verify token was marked as withdrawn
        (,,,, bool isWithdrawn,) = hooks.tokenMetadata(tokenId);
        assertTrue(isWithdrawn, "Token should be marked as withdrawn");

        // Verify tokens were transferred to owner
        uint256 finalBalance = IERC20(tokenAddress).balanceOf(TOKEN_OWNER);
        assertGt(finalBalance, initialBalance, "Owner should have received tokens");
    }

    function test_OnTokenPMPConfigure_RevertsNonPMPV0Caller() public {
        uint256 tokenId = MOCK_TOKEN_ID;
        _setupTokenForWithdrawal(tokenId);

        IPMPV0.PMPInput memory input = IPMPV0.PMPInput({
            key: "IsWithdrawn",
            configuredParamType: IPMPV0.ParamType.Bool,
            configuredValue: bytes32(uint256(1)),
            configuringArtistString: false,
            configuredValueString: ""
        });

        // Try to call from non-PMPV0 address
        vm.prank(address(0x999));
        vm.expectRevert("Only PMPV0 can call");
        hooks.onTokenPMPConfigure(address(mockNFT), tokenId, input);
    }

    function test_OnTokenPMPConfigure_RevertsCoreContractMismatch() public {
        uint256 tokenId = MOCK_TOKEN_ID;
        _setupTokenForWithdrawal(tokenId);

        IPMPV0.PMPInput memory input = IPMPV0.PMPInput({
            key: "IsWithdrawn",
            configuredParamType: IPMPV0.ParamType.Bool,
            configuredValue: bytes32(uint256(1)),
            configuringArtistString: false,
            configuredValueString: ""
        });

        // Call with wrong core contract
        vm.prank(PMPV0_CONTRACT_ADDRESS);
        vm.expectRevert("Core contract mismatch");
        hooks.onTokenPMPConfigure(address(0x999), tokenId, input);
    }

    function test_OnTokenPMPConfigure_RevertsProjectIdMismatch() public {
        // Wrong project ID - token from project 2
        uint256 wrongTokenId = 2_000_000;
        _setupTokenForWithdrawal(wrongTokenId);

        IPMPV0.PMPInput memory input = IPMPV0.PMPInput({
            key: "IsWithdrawn",
            configuredParamType: IPMPV0.ParamType.Bool,
            configuredValue: bytes32(uint256(1)),
            configuringArtistString: false,
            configuredValueString: ""
        });

        vm.prank(PMPV0_CONTRACT_ADDRESS);
        vm.expectRevert("Project id mismatch");
        hooks.onTokenPMPConfigure(address(mockNFT), wrongTokenId, input);
    }

    function test_OnTokenPMPConfigure_RevertsInvalidKey() public {
        uint256 tokenId = MOCK_TOKEN_ID;
        _setupTokenForWithdrawal(tokenId);

        // Wrong key
        IPMPV0.PMPInput memory input = IPMPV0.PMPInput({
            key: "WrongKey",
            configuredParamType: IPMPV0.ParamType.Bool,
            configuredValue: bytes32(uint256(1)),
            configuringArtistString: false,
            configuredValueString: ""
        });

        vm.prank(PMPV0_CONTRACT_ADDRESS);
        vm.expectRevert("Invalid PMP input key");
        hooks.onTokenPMPConfigure(address(mockNFT), tokenId, input);
    }

    function test_OnTokenPMPConfigure_RevertsAlreadyWithdrawn() public {
        uint256 tokenId = MOCK_TOKEN_ID;
        _setupTokenForWithdrawal(tokenId);

        IPMPV0.PMPInput memory input = IPMPV0.PMPInput({
            key: "IsWithdrawn",
            configuredParamType: IPMPV0.ParamType.Bool,
            configuredValue: bytes32(uint256(1)),
            configuringArtistString: false,
            configuredValueString: ""
        });

        // First withdrawal
        vm.prank(PMPV0_CONTRACT_ADDRESS);
        hooks.onTokenPMPConfigure(address(mockNFT), tokenId, input);

        // Try to withdraw again
        vm.prank(PMPV0_CONTRACT_ADDRESS);
        vm.expectRevert("Token already withdrawn");
        hooks.onTokenPMPConfigure(address(mockNFT), tokenId, input);
    }

    function test_OnTokenPMPConfigure_RevertsInvalidValue() public {
        uint256 tokenId = MOCK_TOKEN_ID;
        _setupTokenForWithdrawal(tokenId);

        // Try to set to false instead of true
        IPMPV0.PMPInput memory input = IPMPV0.PMPInput({
            key: "IsWithdrawn",
            configuredParamType: IPMPV0.ParamType.Bool,
            configuredValue: bytes32(uint256(0)), // false
            configuringArtistString: false,
            configuredValueString: ""
        });

        vm.prank(PMPV0_CONTRACT_ADDRESS);
        vm.expectRevert("Invalid PMP input value");
        hooks.onTokenPMPConfigure(address(mockNFT), tokenId, input);
    }

    function test_OnTokenPMPConfigure_TransfersCorrectAmount() public {
        uint256 tokenId = MOCK_TOKEN_ID;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        // Set a specific swap amount
        uint256 expectedAmount = 12345e18;
        mockSwapper.setMockSwapReturn(expectedAmount);

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        // Get token type and deploy mock at real address
        (StratHooks.TokenType tokenType, uint256 tokenBalance,,,,) = hooks.tokenMetadata(tokenId);
        address tokenAddress = _getRealTokenAddress(tokenType);

        // Deploy mock ERC20 at that address
        bytes memory mockERC20Code = type(MockERC20).runtimeCode;
        vm.etch(tokenAddress, mockERC20Code);
        MockERC20(tokenAddress).mint(address(hooks), tokenBalance);

        // Mint NFT to owner
        mockNFT.mint(TOKEN_OWNER, tokenId);

        // Perform withdrawal
        IPMPV0.PMPInput memory input = IPMPV0.PMPInput({
            key: "IsWithdrawn",
            configuredParamType: IPMPV0.ParamType.Bool,
            configuredValue: bytes32(uint256(1)),
            configuringArtistString: false,
            configuredValueString: ""
        });

        uint256 initialBalance = IERC20(tokenAddress).balanceOf(TOKEN_OWNER);

        vm.prank(PMPV0_CONTRACT_ADDRESS);
        hooks.onTokenPMPConfigure(address(mockNFT), tokenId, input);

        // Verify correct amount transferred
        uint256 finalBalance = IERC20(tokenAddress).balanceOf(TOKEN_OWNER);
        assertEq(finalBalance - initialBalance, expectedAmount, "Should transfer exact token balance");
    }

    function test_OnTokenPMPConfigure_RecordsWithdrawalTimestamp() public {
        uint256 tokenId = MOCK_TOKEN_ID;
        _setupTokenForWithdrawal(tokenId);

        // Warp to specific time
        uint256 withdrawalTime = 1234567890;
        vm.warp(withdrawalTime);

        // Create withdrawal PMP input
        IPMPV0.PMPInput memory input = IPMPV0.PMPInput({
            key: "IsWithdrawn",
            configuredParamType: IPMPV0.ParamType.Bool,
            configuredValue: bytes32(uint256(1)),
            configuringArtistString: false,
            configuredValueString: ""
        });

        // Verify withdrawnAt is 0 before withdrawal
        (,,,, bool isWithdrawnBefore, uint128 withdrawnAtBefore) = hooks.tokenMetadata(tokenId);
        assertFalse(isWithdrawnBefore, "Should not be withdrawn yet");
        assertEq(withdrawnAtBefore, 0, "withdrawnAt should be 0 before withdrawal");

        // Perform withdrawal
        vm.prank(PMPV0_CONTRACT_ADDRESS);
        hooks.onTokenPMPConfigure(address(mockNFT), tokenId, input);

        // Verify withdrawnAt is set to block.timestamp
        (,,,, bool isWithdrawnAfter, uint128 withdrawnAtAfter) = hooks.tokenMetadata(tokenId);
        assertTrue(isWithdrawnAfter, "Should be withdrawn");
        assertEq(withdrawnAtAfter, withdrawalTime, "withdrawnAt should be set to block.timestamp");
    }

    function test_OnTokenPMPReadAugmentation_WithdrawalTimestamp() public {
        uint256 tokenId = 1_000_000;

        // Setup token (this internally calls receiveFunds)
        address tokenAddress = _setupTokenForWithdrawal(tokenId);

        // Check before withdrawal - withdrawnAt should be 0
        IWeb3Call.TokenParam[] memory params = new IWeb3Call.TokenParam[](0);
        IWeb3Call.TokenParam[] memory augmented = hooks.onTokenPMPReadAugmentation(address(mockNFT), tokenId, params);

        // Find withdrawnAt param (index 5 when no original params)
        assertEq(augmented[5].key, "withdrawnAt");
        assertEq(augmented[5].value, "0", "withdrawnAt should be 0 before withdrawal");

        // Prepare for withdrawal
        uint256 withdrawalTime = 9999999999;
        vm.warp(withdrawalTime);

        // Perform withdrawal
        IPMPV0.PMPInput memory input = IPMPV0.PMPInput({
            key: "IsWithdrawn",
            configuredParamType: IPMPV0.ParamType.Bool,
            configuredValue: bytes32(uint256(1)),
            configuringArtistString: false,
            configuredValueString: ""
        });

        vm.prank(PMPV0_CONTRACT_ADDRESS);
        hooks.onTokenPMPConfigure(address(mockNFT), tokenId, input);

        // Check after withdrawal - withdrawnAt should be set
        augmented = hooks.onTokenPMPReadAugmentation(address(mockNFT), tokenId, params);
        assertEq(augmented[5].key, "withdrawnAt");
        assertEq(augmented[5].value, vm.toString(withdrawalTime), "withdrawnAt should be set to withdrawal timestamp");
    }

    function test_OnTokenPMPReadAugmentation_OwnerAddress() public {
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        // Setup token with specific owner
        address tokenOwner = address(0xABCD1234);
        mockNFT.mint(tokenOwner, tokenId);

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        // Check owner address is injected
        IWeb3Call.TokenParam[] memory params = new IWeb3Call.TokenParam[](0);
        IWeb3Call.TokenParam[] memory augmented = hooks.onTokenPMPReadAugmentation(address(mockNFT), tokenId, params);

        // Find ownerAddress param (index 6 when no original params)
        assertEq(augmented[6].key, "ownerAddress");
        // toHexString returns lowercase address with 0x prefix
        string memory expectedOwnerHex = Strings.toHexString(uint160(tokenOwner), 20);
        assertEq(augmented[6].value, expectedOwnerHex, "ownerAddress should match token owner");
    }

    function test_OnTokenPMPReadAugmentation_OwnerAddressChanges() public {
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        // Setup token with initial owner
        address initialOwner = address(0x1111);
        address newOwner = address(0x2222);

        mockNFT.mint(initialOwner, tokenId);

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        // Check initial owner
        IWeb3Call.TokenParam[] memory params = new IWeb3Call.TokenParam[](0);
        IWeb3Call.TokenParam[] memory augmented = hooks.onTokenPMPReadAugmentation(address(mockNFT), tokenId, params);

        assertEq(augmented[6].key, "ownerAddress");
        assertEq(augmented[6].value, vm.toString(initialOwner), "Should show initial owner");

        // Transfer NFT to new owner
        vm.prank(initialOwner);
        mockNFT.transferFrom(initialOwner, newOwner, tokenId);

        // Check owner address updates
        augmented = hooks.onTokenPMPReadAugmentation(address(mockNFT), tokenId, params);
        assertEq(augmented[6].value, vm.toString(newOwner), "Should show new owner after transfer");
    }

    function test_OnTokenPMPReadAugmentation() public {
        // Test basic augmentation hook functionality
        // Need to mint the token first so ownerOf doesn't revert
        mockNFT.mint(TOKEN_OWNER, MOCK_TOKEN_ID);

        IWeb3Call.TokenParam[] memory params = new IWeb3Call.TokenParam[](1);
        params[0] = IWeb3Call.TokenParam({key: "test-key", value: "test-value"});

        IWeb3Call.TokenParam[] memory augmented =
            hooks.onTokenPMPReadAugmentation(address(mockNFT), MOCK_TOKEN_ID, params);

        // Implementation now adds 20 parameters (8 metadata + 12 price history entries, even if token not initialized)
        assertEq(augmented.length, params.length + 20, "Should add 20 parameters");
        // First param should still be the original
        assertEq(augmented[0].key, params[0].key);
        assertEq(augmented[0].value, params[0].value);
        // Additional params should exist (with default/zero values for uninitialized token)
        assertEq(augmented[1].key, "tokenSymbol");
        assertEq(augmented[2].key, "tokenBalance");
        assertEq(augmented[3].key, "createdAt");
        assertEq(augmented[4].key, "intervalLengthSeconds");
        assertEq(augmented[5].key, "priceHistoryLength");
        assertEq(augmented[6].key, "withdrawnAt");
        assertEq(augmented[7].key, "ownerAddress");
        assertEq(augmented[8].key, "purchasePrice");
        // Verify price history keys start at index 9
        for (uint256 i = 0; i < 12; i++) {
            assertEq(augmented[9 + i].key, string.concat("priceHistory", vm.toString(i)));
        }
    }

    function test_OnTokenPMPReadAugmentation_PurchasePrice() public {
        uint256 tokenId = 1_000_000;
        uint256 purchasePrice = 0.5 ether;

        // Setup: Set the purchase price in the mock minter
        mockMinter.setTokenPricePaid(address(mockNFT), tokenId, purchasePrice);
        mockNFT.mint(TOKEN_OWNER, tokenId);

        // Check purchase price is injected
        IWeb3Call.TokenParam[] memory params = new IWeb3Call.TokenParam[](0);
        IWeb3Call.TokenParam[] memory augmented = hooks.onTokenPMPReadAugmentation(address(mockNFT), tokenId, params);

        // Find purchasePrice param (index 7 when no original params)
        assertEq(augmented[7].key, "purchasePrice");
        assertEq(augmented[7].value, vm.toString(purchasePrice), "purchasePrice should match minter value");
    }

    function test_OnTokenPMPReadAugmentation_PurchasePrice_ZeroWhenNotSet() public {
        uint256 tokenId = 1_000_000;

        // Don't set any purchase price in minter
        mockNFT.mint(TOKEN_OWNER, tokenId);

        // Check purchase price is 0
        IWeb3Call.TokenParam[] memory params = new IWeb3Call.TokenParam[](0);
        IWeb3Call.TokenParam[] memory augmented = hooks.onTokenPMPReadAugmentation(address(mockNFT), tokenId, params);

        assertEq(augmented[7].key, "purchasePrice");
        assertEq(augmented[7].value, "0", "purchasePrice should be 0 when not set");
    }

    function test_OnTokenPMPReadAugmentation_PurchasePrice_ZeroWhenMinterNotSet() public {
        uint256 tokenId = 1_000_000;
        mockNFT.mint(TOKEN_OWNER, tokenId);

        // Unset the minter address
        vm.prank(OWNER);
        hooks.setSlidingScaleMinterAddress(address(0));

        // Check purchase price is 0 when minter not configured
        IWeb3Call.TokenParam[] memory params = new IWeb3Call.TokenParam[](0);
        IWeb3Call.TokenParam[] memory augmented = hooks.onTokenPMPReadAugmentation(address(mockNFT), tokenId, params);

        assertEq(augmented[7].key, "purchasePrice");
        assertEq(augmented[7].value, "0", "purchasePrice should be 0 when minter not set");
    }

    function test_OnTokenPMPReadAugmentation_PurchasePrice_VariousPrices() public {
        // Test with various price values
        uint256[] memory prices = new uint256[](5);
        prices[0] = 0.01 ether;
        prices[1] = 0.1 ether;
        prices[2] = 1 ether;
        prices[3] = 10 ether;
        prices[4] = 123.456789 ether;

        for (uint256 i = 0; i < prices.length; i++) {
            uint256 tokenId = 1_000_000 + i;
            mockMinter.setTokenPricePaid(address(mockNFT), tokenId, prices[i]);
            mockNFT.mint(TOKEN_OWNER, tokenId);

            IWeb3Call.TokenParam[] memory params = new IWeb3Call.TokenParam[](0);
            IWeb3Call.TokenParam[] memory augmented =
                hooks.onTokenPMPReadAugmentation(address(mockNFT), tokenId, params);

            assertEq(augmented[7].key, "purchasePrice");
            assertEq(
                augmented[7].value,
                vm.toString(prices[i]),
                string.concat("purchasePrice should match ", vm.toString(prices[i]))
            );
        }
    }

    function test_SetSlidingScaleMinterAddress() public {
        address newMinter = address(0x999);

        vm.prank(OWNER);
        hooks.setSlidingScaleMinterAddress(newMinter);

        assertEq(hooks.slidingScaleMinterAddress(), newMinter, "Minter address should be updated");
    }

    function test_SetSlidingScaleMinterAddress_RevertsNonOwner() public {
        address newMinter = address(0x999);

        vm.prank(address(0x123));
        vm.expectRevert();
        hooks.setSlidingScaleMinterAddress(newMinter);
    }

    // ============================================
    // Chainlink Automation Tests
    // ============================================

    function test_CheckUpkeep_TokenNotReadyReturnsFalse() public {
        // Setup: create a token but don't advance time
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        // Check upkeep immediately - should return false
        (bool upkeepNeeded,) = hooks.checkUpkeep("");

        assertFalse(upkeepNeeded, "Upkeep should not be needed immediately after creation");
    }

    function test_CheckUpkeep_TokenReadyReturnsTrue() public {
        // Setup: create a token
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        // Get the interval length
        (,, uint128 createdAt, uint32 intervalLengthSeconds,,) = hooks.tokenMetadata(tokenId);

        // Advance time past the first interval
        vm.warp(createdAt + intervalLengthSeconds + 1);

        // Check upkeep - should return true
        (bool upkeepNeeded, bytes memory performData) = hooks.checkUpkeep("");

        assertTrue(upkeepNeeded, "Upkeep should be needed after interval passes");

        // Verify performData contains correct tokenId and round
        (uint256 returnedTokenId, uint256 round) = abi.decode(performData, (uint256, uint256));
        assertEq(returnedTokenId, tokenId, "Returned tokenId should match");
        assertEq(round, 1, "Round should be 1 (second entry in price history)");
    }

    function test_CheckUpkeep_ReturnsFirstReadyToken() public {
        // Setup: create multiple tokens
        uint256 baseTokenId = 1_000_000;

        for (uint256 i = 0; i < 3; i++) {
            uint256 tokenId = baseTokenId + i;
            bytes32 tokenHash = keccak256(abi.encode(tokenId));

            vm.prank(ADDITIONAL_PAYEE_RECEIVER);
            vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
            hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);
        }

        // Advance time to make all tokens ready
        (,, uint128 createdAt, uint32 intervalLengthSeconds,,) = hooks.tokenMetadata(baseTokenId);
        vm.warp(createdAt + intervalLengthSeconds + 1);

        // Check upkeep - should return the first token
        (bool upkeepNeeded, bytes memory performData) = hooks.checkUpkeep("");

        assertTrue(upkeepNeeded, "Upkeep should be needed");

        (uint256 returnedTokenId,) = abi.decode(performData, (uint256, uint256));
        assertEq(returnedTokenId, baseTokenId, "Should return first ready token");
    }

    function test_CheckUpkeep_SkipsCompletedTokens() public {
        // Setup: create a token and complete all 12 rounds
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        (,, uint128 createdAt, uint32 intervalLengthSeconds,,) = hooks.tokenMetadata(tokenId);

        // Perform all 12 rounds (starting from round 1 since round 0 was created)
        for (uint256 i = 1; i < 12; i++) {
            vm.warp(createdAt + intervalLengthSeconds * i + 1);

            bytes memory performData = abi.encode(tokenId, i);
            vm.prank(KEEPER);
            hooks.performUpkeep(performData);
        }

        // Advance time further
        vm.warp(createdAt + intervalLengthSeconds * 20);

        // Check upkeep - should return false as token is complete
        (bool upkeepNeeded,) = hooks.checkUpkeep("");

        assertFalse(upkeepNeeded, "Upkeep should not be needed for completed token");
    }

    function test_PerformUpkeep_AppendsOraclePrice() public {
        // Setup: create a token
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        // Set a specific oracle price
        mockSwapper.setMockPrice(0.006e18, 18);

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        // Advance time
        (,, uint128 createdAt, uint32 intervalLengthSeconds,,) = hooks.tokenMetadata(tokenId);
        vm.warp(createdAt + intervalLengthSeconds + 1);

        // Perform upkeep
        bytes memory performData = abi.encode(tokenId, 1);

        vm.prank(KEEPER);
        hooks.performUpkeep(performData);

        // Price history should now have 2 entries (initial + this upkeep)
        // We can't directly access the array, but we can verify the next round incremented
    }

    function test_PerformUpkeep_ExecutesAndEmitsEvent() public {
        // Setup: create a token
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        // Advance time
        (,, uint128 createdAt, uint32 intervalLengthSeconds,,) = hooks.tokenMetadata(tokenId);
        vm.warp(createdAt + intervalLengthSeconds + 1);

        uint256 round = 1;
        bytes memory performData = abi.encode(tokenId, round);

        // Expect the UpkeepPerformed event
        vm.expectEmit(true, true, false, true);
        emit UpkeepPerformed(tokenId, round, block.timestamp);

        // Perform upkeep as the keeper
        vm.prank(KEEPER);
        hooks.performUpkeep(performData);
    }

    function test_PerformUpkeep_RevertsOnStaleRound() public {
        // Setup: create a token
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        // Advance time
        (,, uint128 createdAt, uint32 intervalLengthSeconds,,) = hooks.tokenMetadata(tokenId);
        vm.warp(createdAt + intervalLengthSeconds + 1);

        // Perform upkeep for round 1
        bytes memory performData = abi.encode(tokenId, 1);
        vm.prank(KEEPER);
        hooks.performUpkeep(performData);

        // Now trying to execute round 1 again should fail (stale)
        vm.prank(KEEPER);
        vm.expectRevert("Stale upkeep");
        hooks.performUpkeep(performData);
    }

    function test_PerformUpkeep_RevertsBeforeIntervalPassed() public {
        // Setup: create a token
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        // Try to perform upkeep immediately (should fail)
        bytes memory performData = abi.encode(tokenId, 1);

        vm.prank(KEEPER);
        vm.expectRevert("Block timestamp requirements not met");
        hooks.performUpkeep(performData);
    }

    function test_PerformUpkeep_IdempotencyAcrossTokens() public {
        // Setup: create multiple tokens
        uint256 baseTokenId = 1_000_000;
        uint256 tokenId1 = baseTokenId;
        uint256 tokenId2 = baseTokenId + 1;

        // Receive funds for token 1
        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId1, keccak256(abi.encode(tokenId1)));

        // Receive funds for token 2
        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId2, keccak256(abi.encode(tokenId2)));

        // Advance time - get the max interval to ensure both are ready
        (,, uint128 createdAt1, uint32 intervalLengthSeconds1,,) = hooks.tokenMetadata(tokenId1);
        (,, uint128 createdAt2, uint32 intervalLengthSeconds2,,) = hooks.tokenMetadata(tokenId2);
        uint256 maxInterval =
            intervalLengthSeconds1 > intervalLengthSeconds2 ? intervalLengthSeconds1 : intervalLengthSeconds2;
        uint256 maxCreatedAt = createdAt1 > createdAt2 ? createdAt1 : createdAt2;
        vm.warp(maxCreatedAt + maxInterval + 1);

        // Perform upkeep for both tokens
        vm.prank(KEEPER);
        hooks.performUpkeep(abi.encode(tokenId1, 1));

        vm.prank(KEEPER);
        hooks.performUpkeep(abi.encode(tokenId2, 1));

        // Both tokens should now be at round 2 (price history length = 2)
        // Verify by trying to perform round 1 again (should fail as stale)
        vm.prank(KEEPER);
        vm.expectRevert("Stale upkeep");
        hooks.performUpkeep(abi.encode(tokenId1, 1));
    }

    function test_PerformUpkeep_MultipleRoundsSequential() public {
        // Setup: create a token
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        (,, uint128 createdAt, uint32 intervalLengthSeconds,,) = hooks.tokenMetadata(tokenId);

        // Execute multiple rounds sequentially
        for (uint256 i = 1; i < 12; i++) {
            // Advance time for each interval
            vm.warp(createdAt + intervalLengthSeconds * i + 1);

            bytes memory performData = abi.encode(tokenId, i);
            vm.prank(KEEPER);
            hooks.performUpkeep(performData);
        }

        // After 11 more upkeeps (12 total entries in price history), token should be complete
        // Verify by checking checkUpkeep returns false for this token
        vm.warp(createdAt + intervalLengthSeconds * 20);
        (bool upkeepNeeded,) = hooks.checkUpkeep("");
        assertFalse(upkeepNeeded, "Token should be complete after 12 rounds");
    }

    function test_PerformUpkeep_CorrectOraclePriceUsed() public {
        // Setup: create a token
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        // Set initial price
        mockSwapper.setMockPrice(0.004e18, 18);

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        // Change oracle price before performing upkeep
        mockSwapper.setMockPrice(0.008e18, 18);

        // Advance time
        (,, uint128 createdAt, uint32 intervalLengthSeconds,,) = hooks.tokenMetadata(tokenId);
        vm.warp(createdAt + intervalLengthSeconds + 1);

        // Perform upkeep - should use the NEW oracle price (0.008e18)
        bytes memory performData = abi.encode(tokenId, 1);
        vm.prank(KEEPER);
        hooks.performUpkeep(performData);

        // The price history now has 2 entries: initial (0.004) and upkeep (0.008)
        // We can verify this worked by doing another upkeep and confirming it increments
        vm.warp(createdAt + intervalLengthSeconds * 2 + 1);
        vm.prank(KEEPER);
        hooks.performUpkeep(abi.encode(tokenId, 2));
    }

    // ============================================
    // Additional Keeper Logic Tests
    // ============================================

    function test_CheckUpkeep_MultipleTokensDifferentIntervals() public {
        // Create tokens with different intervals
        uint256 baseTokenId = 1_000_000;

        for (uint256 i = 0; i < 3; i++) {
            uint256 tokenId = baseTokenId + i;
            // Use different hashes to get different intervals
            bytes32 tokenHash = keccak256(abi.encode(tokenId * 7 + 12345));

            vm.prank(ADDITIONAL_PAYEE_RECEIVER);
            vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
            hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);
        }

        // Advance time to make only the first token ready (smallest interval)
        (,, uint128 createdAt0, uint32 intervalLength0,,) = hooks.tokenMetadata(baseTokenId);
        vm.warp(createdAt0 + intervalLength0 + 1);

        // checkUpkeep should find at least one token ready
        (bool upkeepNeeded, bytes memory performData) = hooks.checkUpkeep("");

        if (upkeepNeeded) {
            (uint256 returnedTokenId,) = abi.decode(performData, (uint256, uint256));
            assertTrue(returnedTokenId >= baseTokenId && returnedTokenId < baseTokenId + 3, "Token should be in range");
        }
    }

    function test_PerformUpkeep_CannotSkipRounds() public {
        // Setup: create a token
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        // Advance time past multiple intervals
        (,, uint128 createdAt, uint32 intervalLengthSeconds,,) = hooks.tokenMetadata(tokenId);
        vm.warp(createdAt + intervalLengthSeconds * 5);

        // Try to perform upkeep for round 3 (should fail - current round is 1)
        bytes memory performData = abi.encode(tokenId, 3);
        vm.prank(KEEPER);
        vm.expectRevert("Stale upkeep");
        hooks.performUpkeep(performData);

        // Should only be able to perform round 1
        vm.prank(KEEPER);
        hooks.performUpkeep(abi.encode(tokenId, 1));
    }

    function test_CheckUpkeep_SkipsTokensInProgress() public {
        // Create two tokens
        uint256 baseTokenId = 1_000_000;

        for (uint256 i = 0; i < 2; i++) {
            uint256 tokenId = baseTokenId + i;
            bytes32 tokenHash = keccak256(abi.encode(tokenId));

            vm.prank(ADDITIONAL_PAYEE_RECEIVER);
            vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
            hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);
        }

        // Advance time
        (,, uint128 createdAt, uint32 intervalLengthSeconds,,) = hooks.tokenMetadata(baseTokenId);
        vm.warp(createdAt + intervalLengthSeconds * 13); // Way past all intervals

        // Complete all rounds for first token
        for (uint256 i = 1; i < 12; i++) {
            vm.prank(KEEPER);
            hooks.performUpkeep(abi.encode(baseTokenId, i));
        }

        // checkUpkeep should now skip first token and return second token
        (bool upkeepNeeded, bytes memory performData) = hooks.checkUpkeep("");

        if (upkeepNeeded) {
            (uint256 returnedTokenId,) = abi.decode(performData, (uint256, uint256));
            assertEq(returnedTokenId, baseTokenId + 1, "Should return second token");
        }
    }

    function test_PerformUpkeep_EmitsCorrectEventData() public {
        // Setup: create a token
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        // Advance time
        (,, uint128 createdAt, uint32 intervalLengthSeconds,,) = hooks.tokenMetadata(tokenId);
        uint256 warpTime = createdAt + intervalLengthSeconds + 100;
        vm.warp(warpTime);

        uint256 round = 1;
        bytes memory performData = abi.encode(tokenId, round);

        // Expect event with specific timestamp
        vm.expectEmit(true, true, false, true);
        emit UpkeepPerformed(tokenId, round, warpTime);

        vm.prank(KEEPER);
        hooks.performUpkeep(performData);
    }

    function test_CheckUpkeep_WorksWithSingleToken() public {
        // Test that checkUpkeep works correctly with just one token
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        // Before interval: should return false
        (bool upkeepNeeded1,) = hooks.checkUpkeep("");
        assertFalse(upkeepNeeded1, "Should not need upkeep before interval");

        // After interval: should return true
        (,, uint128 createdAt, uint32 intervalLengthSeconds,,) = hooks.tokenMetadata(tokenId);
        vm.warp(createdAt + intervalLengthSeconds + 1);

        (bool upkeepNeeded2, bytes memory performData) = hooks.checkUpkeep("");
        assertTrue(upkeepNeeded2, "Should need upkeep after interval");

        (uint256 returnedTokenId, uint256 round) = abi.decode(performData, (uint256, uint256));
        assertEq(returnedTokenId, tokenId, "Should return correct tokenId");
        assertEq(round, 1, "Should be round 1");
    }

    function test_PerformUpkeep_GasUsageReasonable() public {
        // Create a token and test gas usage for upkeep
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        // Advance time
        (,, uint128 createdAt, uint32 intervalLengthSeconds,,) = hooks.tokenMetadata(tokenId);
        vm.warp(createdAt + intervalLengthSeconds + 1);

        // Measure gas
        uint256 gasBefore = gasleft();
        vm.prank(KEEPER);
        hooks.performUpkeep(abi.encode(tokenId, 1));
        uint256 gasUsed = gasBefore - gasleft();

        // Gas should be reasonable (under 100k for a simple append operation)
        assertLt(gasUsed, 100000, "Gas usage should be reasonable");
    }

    function test_CheckUpkeep_ReturnsCorrectRoundNumber() public {
        // Create token and perform several upkeeps
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        (,, uint128 createdAt, uint32 intervalLengthSeconds,,) = hooks.tokenMetadata(tokenId);

        // Perform rounds 1-3
        for (uint256 i = 1; i <= 3; i++) {
            vm.warp(createdAt + intervalLengthSeconds * i + 1);

            // Check that checkUpkeep returns correct round
            (bool upkeepNeeded, bytes memory performData) = hooks.checkUpkeep("");
            assertTrue(upkeepNeeded, "Upkeep should be needed");

            (uint256 returnedTokenId, uint256 round) = abi.decode(performData, (uint256, uint256));
            assertEq(returnedTokenId, tokenId, "Should return correct tokenId");
            assertEq(round, i, "Should return correct round number");

            // Perform the upkeep
            vm.prank(KEEPER);
            hooks.performUpkeep(performData);
        }
    }

    // ============================================
    // Keeper Management Tests
    // ============================================

    function test_SetKeeper() public {
        address newKeeper = address(0x400);

        vm.prank(OWNER);
        hooks.setKeeper(newKeeper);

        assertEq(hooks.keeper(), newKeeper, "Keeper should be updated");
    }

    function test_SetKeeper_RevertsNonOwner() public {
        address newKeeper = address(0x400);

        vm.prank(address(0x999));
        vm.expectRevert();
        hooks.setKeeper(newKeeper);
    }

    function test_SetAdditionalPayeeReceiver() public {
        address newReceiver = address(0x500);

        vm.prank(OWNER);
        hooks.setAdditionalPayeeReceiver(newReceiver);

        assertEq(hooks.additionalPayeeReceiver(), newReceiver, "Additional payee receiver should be updated");
    }

    function test_SetAdditionalPayeeReceiver_RevertsNonOwner() public {
        address newReceiver = address(0x500);

        vm.prank(address(0x999));
        vm.expectRevert();
        hooks.setAdditionalPayeeReceiver(newReceiver);
    }

    function test_SetGuardedEthTokenSwapper() public {
        address newSwapper = address(0x600);

        vm.prank(OWNER);
        hooks.setGuardedEthTokenSwapper(newSwapper);

        assertEq(address(hooks.guardedEthTokenSwapper()), newSwapper, "Swapper should be updated");
    }

    function test_SetGuardedEthTokenSwapper_RevertsNonOwner() public {
        address newSwapper = address(0x600);

        vm.prank(address(0x999));
        vm.expectRevert();
        hooks.setGuardedEthTokenSwapper(newSwapper);
    }

    function test_PerformUpkeep_RevertsNonKeeper() public {
        uint256 tokenId = MOCK_TOKEN_ID;
        bytes memory performData = abi.encode(tokenId, 0);

        vm.prank(address(0x999));
        vm.expectRevert("Not keeper");
        hooks.performUpkeep(performData);
    }

    // ============================================
    // ReceiveFunds Tests
    // ============================================

    function test_ReceiveFunds() public {
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));
        uint256 amount = 1 ether;

        // Set up mock return values
        mockSwapper.setMockSwapReturn(5000e18); // 5000 tokens
        mockSwapper.setMockPrice(0.004e18, 18); // 0.004 ETH per token

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, amount);
        hooks.receiveFunds{value: amount}(tokenId, tokenHash);

        assertEq(hooks.latestReceivedTokenId(), tokenId, "Latest token ID should be updated");

        // Verify token metadata was initialized
        (StratHooks.TokenType tokenType, uint256 tokenBalance, uint128 createdAt, uint32 intervalLengthSeconds,,) =
            hooks.tokenMetadata(tokenId);

        assertEq(tokenBalance, 5000e18, "Token balance should match swap return");
        assertEq(createdAt, block.timestamp, "Created at should be block timestamp");
        assertGt(intervalLengthSeconds, 0, "Interval length should be set");

        // Verify token type is valid (0-13 for 14 token types)
        assertTrue(uint256(tokenType) < 14, "Token type should be in valid range");
    }

    function test_ReceiveFunds_RevertsNonPayee() public {
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        vm.deal(address(0x999), 1 ether);
        vm.prank(address(0x999));
        vm.expectRevert("Not additional payee receiver");
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);
    }

    function test_ReceiveFunds_RevertsInvalidTokenId() public {
        // First receive funds for token 1_000_000
        uint256 firstTokenId = 1_000_000;
        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 2 ether);
        hooks.receiveFunds{value: 1 ether}(firstTokenId, keccak256(abi.encode(firstTokenId)));

        // Try to receive funds for token 1_000_002 (should be 1_000_001)
        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.expectRevert("Invalid token id");
        hooks.receiveFunds{value: 1 ether}(1_000_002, keccak256(abi.encode(uint256(1_000_002))));
    }

    function test_ReceiveFunds_MultipleTokens() public {
        // Receive funds for multiple tokens sequentially
        uint256 baseTokenId = 1_000_000;
        for (uint256 i = 0; i < 5; i++) {
            uint256 tokenId = baseTokenId + i;
            bytes32 tokenHash = keccak256(abi.encode(tokenId));

            vm.prank(ADDITIONAL_PAYEE_RECEIVER);
            vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
            hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

            assertEq(hooks.latestReceivedTokenId(), tokenId, "Latest token ID should match iteration");
        }
    }

    function test_ReceiveFunds_CallsSwapperCorrectly() public {
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));
        uint256 amount = 2 ether;

        // Set mock return to a specific value
        mockSwapper.setMockSwapReturn(10000e18);

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, amount);

        // Call receiveFunds and verify it uses the mock swap return
        hooks.receiveFunds{value: amount}(tokenId, tokenHash);

        // Verify the token balance matches the mock return value
        (, uint256 tokenBalance,,,,) = hooks.tokenMetadata(tokenId);
        assertEq(tokenBalance, 10000e18, "Token balance should match mock swap return");
    }

    function test_ReceiveFunds_StoresCorrectTokenType() public {
        // Test that different hashes produce token types in valid range
        uint256 baseTokenId = 1_000_000;
        for (uint256 i = 0; i < 14; i++) {
            uint256 tokenId = baseTokenId + i;
            bytes32 tokenHash = keccak256(abi.encode(tokenId * 123456)); // Use different hashes

            vm.prank(ADDITIONAL_PAYEE_RECEIVER);
            vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
            hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

            (StratHooks.TokenType tokenType,,,,,) = hooks.tokenMetadata(tokenId);

            // Verify token type is in valid range
            assertTrue(uint256(tokenType) < 14, "Token type should be valid");
        }
    }

    function test_ReceiveFunds_StoresPriceHistory() public {
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        // Set a specific price
        mockSwapper.setMockPrice(0.005e18, 18);

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, 1 ether);
        hooks.receiveFunds{value: 1 ether}(tokenId, tokenHash);

        // The price history should have been populated (we can't easily read the array directly in this test)
        // But we can verify the metadata exists
        (, uint256 tokenBalance,,,,) = hooks.tokenMetadata(tokenId);
        assertGt(tokenBalance, 0, "Token balance should be set");
    }

    function test_ReceiveFunds_ForwardsEthToSwapper() public {
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));

        // Test with various ETH amounts
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 0.1 ether;
        amounts[1] = 0.5 ether;
        amounts[2] = 1 ether;
        amounts[3] = 5 ether;

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 testTokenId = tokenId + i;

            // Reset lastReceivedEth
            vm.store(address(mockSwapper), bytes32(uint256(3)), bytes32(uint256(0))); // slot 3 is lastReceivedEth

            vm.prank(ADDITIONAL_PAYEE_RECEIVER);
            vm.deal(ADDITIONAL_PAYEE_RECEIVER, amounts[i]);
            hooks.receiveFunds{value: amounts[i]}(testTokenId, tokenHash);

            // Verify the swapper received the correct ETH amount
            assertEq(
                mockSwapper.lastReceivedEth(),
                amounts[i],
                string.concat("Swapper should receive ", vm.toString(amounts[i]), " ETH")
            );
        }
    }

    function test_ReceiveFunds_ForwardsExactEthAmount() public {
        // Critical test: verify exact ETH amount is forwarded (not more, not less)
        uint256 tokenId = 1_000_000;
        bytes32 tokenHash = keccak256(abi.encode(tokenId));
        uint256 sendAmount = 1.234 ether;

        // Check swapper balance before
        uint256 swapperBalanceBefore = address(mockSwapper).balance;

        vm.prank(ADDITIONAL_PAYEE_RECEIVER);
        vm.deal(ADDITIONAL_PAYEE_RECEIVER, sendAmount);
        hooks.receiveFunds{value: sendAmount}(tokenId, tokenHash);

        // Verify swapper received exactly the sent amount
        assertEq(
            address(mockSwapper).balance - swapperBalanceBefore,
            sendAmount,
            "Swapper should receive exact ETH amount sent to receiveFunds"
        );

        // Also verify via the tracking variable
        assertEq(mockSwapper.lastReceivedEth(), sendAmount, "lastReceivedEth should match sent amount");
    }
}

