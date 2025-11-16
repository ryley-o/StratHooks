// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AdditionalPayeeReceiver} from "../src/AdditionalPayeeReceiver.sol";
import {StratHooks} from "../src/StratHooks.sol";
import {IGuardedEthTokenSwapper} from "../src/interfaces/IGuardedEthTokenSwapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Mock Core Contract for testing - implements only what we need
contract MockCoreContract {
    mapping(uint256 => uint256) private _projectInvocations;
    mapping(uint256 => bytes32) private _tokenHashes;

    function setProjectInvocations(uint256 projectId, uint256 invocations) external {
        _projectInvocations[projectId] = invocations;
    }

    function setTokenHash(uint256 tokenId, bytes32 hash) external {
        _tokenHashes[tokenId] = hash;
    }

    function projectStateData(uint256 projectId)
        external
        view
        returns (uint256 invocations, uint256, uint256, uint256, bool, bool)
    {
        return (_projectInvocations[projectId], 0, 0, 0, false, false);
    }

    function tokenIdToHash(uint256 tokenId) external view returns (bytes32) {
        return _tokenHashes[tokenId];
    }
}

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

    function mint(address to, uint256 tokenId) external {
        _owners[tokenId] = to;
        _balances[to]++;
    }
}

// Mock GuardedEthTokenSwapper for testing
contract MockGuardedEthTokenSwapper is IGuardedEthTokenSwapper {
    uint256 public mockSwapReturn = 1000e18;
    uint256 public mockPrice = 0.004e18;
    uint8 public mockDecimals = 18;

    function setMockSwapReturn(uint256 _amount) external {
        mockSwapReturn = _amount;
    }

    function setMockPrice(uint256 _price, uint8 _decimals) external {
        mockPrice = _price;
        mockDecimals = _decimals;
    }

    function swapEthForToken(address, uint16, uint256) external payable override returns (uint256) {
        return mockSwapReturn;
    }

    function setFeeds(address[] calldata, address[] calldata, uint24[] calldata, uint16[] calldata) external override {}

    function removeFeed(address) external override {}

    function getFeed(address)
        external
        view
        override
        returns (address aggregator, uint8 decimals, uint24 feeTier, uint16 toleranceBps)
    {
        return (address(0x123), mockDecimals, 3000, 200);
    }

    function getTokenPrice(address) external view override returns (uint256 price, uint8 decimals) {
        return (mockPrice, mockDecimals);
    }

    function router() external pure override returns (address) {
        return address(0);
    }

    function weth() external pure override returns (address) {
        return address(0);
    }

    function owner() external view override returns (address) {
        return address(this);
    }
}

contract AdditionalPayeeReceiverTest is Test {
    AdditionalPayeeReceiver public receiver;
    StratHooks public hooks;
    MockCoreContract public mockCore;
    MockGuardedEthTokenSwapper public mockSwapper;
    MockERC721 public mockNFT;
    MockERC20 public mockToken;

    address constant MINTER = address(0x100);
    address constant OWNER = address(0x200);
    address constant KEEPER = address(0x300);
    uint256 constant PROJECT_ID = 1;
    uint256 constant BASE_TOKEN_ID = PROJECT_ID * 1_000_000;

    event FundsReceived(address indexed sender, uint256 amount, uint256 indexed tokenId);

    function setUp() public {
        // Deploy mocks
        mockCore = new MockCoreContract();
        mockSwapper = new MockGuardedEthTokenSwapper();
        mockNFT = new MockERC721();
        mockToken = new MockERC20();

        // Deploy StratHooks implementation
        StratHooks implementation = new StratHooks();

        // Prepare initializer data
        bytes memory initData = abi.encodeWithSelector(
            StratHooks.initialize.selector,
            OWNER,
            address(0), // Will set this to receiver after deployment
            KEEPER,
            address(mockCore),
            PROJECT_ID
        );

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        hooks = StratHooks(address(proxy));

        // Deploy AdditionalPayeeReceiver
        receiver = new AdditionalPayeeReceiver(MINTER, address(mockCore), PROJECT_ID, address(hooks));

        // Set receiver as additional payee receiver in hooks
        vm.prank(OWNER);
        hooks.setAdditionalPayeeReceiver(address(receiver));

        // Set mock swapper
        vm.prank(OWNER);
        hooks.setGuardedEthTokenSwapper(address(mockSwapper));
    }

    // ============================================
    // Constructor Tests
    // ============================================

    function test_Constructor() public view {
        assertEq(receiver.allowedSender(), MINTER, "Allowed sender should be MINTER");
        assertEq(receiver.coreContract(), address(mockCore), "Core contract should match");
        assertEq(receiver.projectId(), PROJECT_ID, "Project ID should match");
        assertEq(receiver.stratHooks(), address(hooks), "StratHooks should match");
    }

    // ============================================
    // Receive Function Tests - Success Cases
    // ============================================

    function test_Receive_SuccessfullyForwardsFirstToken() public {
        // Setup: First token (invocation = 1)
        uint256 invocations = 1;
        uint256 expectedTokenId = BASE_TOKEN_ID; // PROJECT_ID * 1_000_000 + 0
        bytes32 expectedHash = keccak256("token0");

        mockCore.setProjectInvocations(PROJECT_ID, invocations);
        mockCore.setTokenHash(expectedTokenId, expectedHash);

        uint256 sendAmount = 1 ether;

        // Act: Send funds from minter
        vm.deal(MINTER, sendAmount);
        vm.prank(MINTER);
        (bool success,) = address(receiver).call{value: sendAmount}("");

        // Assert
        assertTrue(success, "Receive should succeed");
        assertEq(address(receiver).balance, 0, "Receiver should forward all funds");
    }

    function test_Receive_SuccessfullyForwardsMultipleTokens() public {
        // Test with token #5
        uint256 invocations = 5;
        uint256 expectedTokenId = BASE_TOKEN_ID + 4; // invocations - 1
        bytes32 expectedHash = keccak256("token4");

        mockCore.setProjectInvocations(PROJECT_ID, invocations);
        mockCore.setTokenHash(expectedTokenId, expectedHash);

        uint256 sendAmount = 0.5 ether;

        vm.deal(MINTER, sendAmount);
        vm.prank(MINTER);
        (bool success,) = address(receiver).call{value: sendAmount}("");

        assertTrue(success, "Receive should succeed for token 5");
        assertEq(address(receiver).balance, 0, "Receiver should forward all funds");
    }

    function test_Receive_CorrectlyCalculatesTokenId() public {
        // Test token ID calculation for different invocations
        uint256[] memory invocations = new uint256[](5);
        invocations[0] = 1;
        invocations[1] = 2;
        invocations[2] = 3;
        invocations[3] = 4;
        invocations[4] = 5;

        for (uint256 i = 0; i < invocations.length; i++) {
            uint256 expectedTokenId = BASE_TOKEN_ID + invocations[i] - 1;
            bytes32 hash = keccak256(abi.encodePacked("token", i));

            mockCore.setProjectInvocations(PROJECT_ID, invocations[i]);
            mockCore.setTokenHash(expectedTokenId, hash);

            vm.deal(MINTER, 0.1 ether);
            vm.prank(MINTER);
            (bool success,) = address(receiver).call{value: 0.1 ether}("");

            assertTrue(success, string.concat("Should succeed for invocation ", vm.toString(invocations[i])));
            assertEq(hooks.latestReceivedTokenId(), expectedTokenId, "Token ID should match");
        }
    }

    function test_Receive_ForwardsCorrectAmount() public {
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 0.01 ether;
        amounts[1] = 0.1 ether;
        amounts[2] = 1 ether;
        amounts[3] = 10 ether;

        for (uint256 i = 0; i < amounts.length; i++) {
            // Each iteration mints a new token (sequential)
            uint256 invocations = i + 1;
            uint256 tokenId = BASE_TOKEN_ID + i;
            bytes32 hash = keccak256(abi.encodePacked("token", i));

            mockCore.setProjectInvocations(PROJECT_ID, invocations);
            mockCore.setTokenHash(tokenId, hash);

            vm.deal(MINTER, amounts[i]);

            uint256 hookBalanceBefore = address(hooks).balance;

            vm.prank(MINTER);
            (bool success,) = address(receiver).call{value: amounts[i]}("");

            assertTrue(success, "Should succeed");
            assertEq(address(receiver).balance, 0, "Receiver balance should be 0");
            assertEq(address(hooks).balance - hookBalanceBefore, amounts[i], "Hooks should receive correct amount");
        }
    }

    function test_Receive_MultipleSequentialMints() public {
        // Simulate 3 sequential mints
        for (uint256 i = 1; i <= 3; i++) {
            uint256 tokenId = BASE_TOKEN_ID + i - 1;
            bytes32 hash = keccak256(abi.encodePacked("token", i));

            mockCore.setProjectInvocations(PROJECT_ID, i);
            mockCore.setTokenHash(tokenId, hash);

            vm.deal(MINTER, 1 ether);
            vm.prank(MINTER);
            (bool success,) = address(receiver).call{value: 1 ether}("");

            assertTrue(success, string.concat("Mint ", vm.toString(i), " should succeed"));
            assertEq(address(receiver).balance, 0, "Receiver should not hold funds");
        }
    }

    function test_Receive_HandlesZeroValue() public {
        // Setup
        uint256 invocations = 1;
        uint256 tokenId = BASE_TOKEN_ID;
        bytes32 hash = keccak256("token");

        mockCore.setProjectInvocations(PROJECT_ID, invocations);
        mockCore.setTokenHash(tokenId, hash);

        // Act: Send 0 value
        vm.prank(MINTER);
        (bool success,) = address(receiver).call{value: 0}("");

        // Assert: Should still work (though not particularly useful)
        assertTrue(success, "Should handle zero value");
    }

    // ============================================
    // Receive Function Tests - Failure Cases
    // ============================================

    function test_Receive_RevertsUnauthorizedSender() public {
        address unauthorizedSender = address(0x999);

        vm.deal(unauthorizedSender, 1 ether);
        vm.prank(unauthorizedSender);
        vm.expectRevert(abi.encodeWithSelector(AdditionalPayeeReceiver.UnauthorizedSender.selector, unauthorizedSender));
        address(receiver).call{value: 1 ether}("");
    }

    function test_Receive_RevertsNonMinterAddresses() public {
        address[] memory unauthorized = new address[](5);
        unauthorized[0] = address(0x123);
        unauthorized[1] = address(0x456);
        unauthorized[2] = OWNER;
        unauthorized[3] = KEEPER;
        unauthorized[4] = address(hooks);

        for (uint256 i = 0; i < unauthorized.length; i++) {
            vm.deal(unauthorized[i], 1 ether);
            vm.prank(unauthorized[i]);
            vm.expectRevert(
                abi.encodeWithSelector(AdditionalPayeeReceiver.UnauthorizedSender.selector, unauthorized[i])
            );
            address(receiver).call{value: 1 ether}("");
        }
    }

    function test_Receive_RevertsZeroAddress() public {
        // Can't actually send from zero address, but test the check is there
        vm.deal(address(0), 1 ether);
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(AdditionalPayeeReceiver.UnauthorizedSender.selector, address(0)));
        address(receiver).call{value: 1 ether}("");
    }

    // ============================================
    // Integration Tests with StratHooks
    // ============================================

    function test_Integration_TokenMetadataCreated() public {
        // Setup
        uint256 invocations = 1;
        uint256 tokenId = BASE_TOKEN_ID;
        bytes32 hash = keccak256("token");

        mockCore.setProjectInvocations(PROJECT_ID, invocations);
        mockCore.setTokenHash(tokenId, hash);

        // Act: Send funds
        vm.deal(MINTER, 1 ether);
        vm.prank(MINTER);
        address(receiver).call{value: 1 ether}("");

        // Assert: Check token metadata was created in StratHooks
        (StratHooks.TokenType tokenType, uint256 balance, uint128 createdAt, uint32 intervalLength, bool isWithdrawn) =
            hooks.tokenMetadata(tokenId);

        assertTrue(balance > 0, "Token should have balance");
        assertTrue(createdAt > 0, "Token should have creation timestamp");
        assertTrue(intervalLength > 0, "Token should have interval length");
        assertFalse(isWithdrawn, "Token should not be withdrawn initially");
    }

    function test_Integration_UpdatesLatestReceivedTokenId() public {
        // Test that StratHooks tracks latest token
        uint256 invocations1 = 1;
        uint256 tokenId1 = BASE_TOKEN_ID;
        bytes32 hash1 = keccak256("token1");

        mockCore.setProjectInvocations(PROJECT_ID, invocations1);
        mockCore.setTokenHash(tokenId1, hash1);

        vm.deal(MINTER, 1 ether);
        vm.prank(MINTER);
        address(receiver).call{value: 1 ether}("");

        assertEq(hooks.latestReceivedTokenId(), tokenId1, "Latest token ID should be updated");

        // Mint another token
        uint256 invocations2 = 2;
        uint256 tokenId2 = BASE_TOKEN_ID + 1;
        bytes32 hash2 = keccak256("token2");

        mockCore.setProjectInvocations(PROJECT_ID, invocations2);
        mockCore.setTokenHash(tokenId2, hash2);

        vm.deal(MINTER, 1 ether);
        vm.prank(MINTER);
        address(receiver).call{value: 1 ether}("");

        assertEq(hooks.latestReceivedTokenId(), tokenId2, "Latest token ID should be updated to token2");
    }

    // ============================================
    // View Function Tests
    // ============================================

    function test_GetBalance_ReturnsZero() public view {
        assertEq(receiver.getBalance(), 0, "Balance should be 0 initially");
    }

    function test_GetBalance_AfterReceive() public {
        // Setup
        uint256 invocations = 1;
        uint256 tokenId = BASE_TOKEN_ID;
        bytes32 hash = keccak256("token");

        mockCore.setProjectInvocations(PROJECT_ID, invocations);
        mockCore.setTokenHash(tokenId, hash);

        // Send funds
        vm.deal(MINTER, 1 ether);
        vm.prank(MINTER);
        address(receiver).call{value: 1 ether}("");

        // Should still be 0 as funds are forwarded
        assertEq(receiver.getBalance(), 0, "Balance should remain 0 after forwarding");
    }

    // ============================================
    // Edge Cases
    // ============================================

    function test_EdgeCase_VeryLargeInvocationNumber() public {
        uint256 invocations = 999999; // Near max for standard project
        uint256 expectedTokenId = BASE_TOKEN_ID + invocations - 1;
        bytes32 hash = keccak256("token");

        mockCore.setProjectInvocations(PROJECT_ID, invocations);
        mockCore.setTokenHash(expectedTokenId, hash);

        vm.deal(MINTER, 1 ether);
        vm.prank(MINTER);
        (bool success,) = address(receiver).call{value: 1 ether}("");

        assertTrue(success, "Should handle large invocation numbers");
    }

    function test_EdgeCase_VerySmallAmount() public {
        uint256 invocations = 1;
        uint256 tokenId = BASE_TOKEN_ID;
        bytes32 hash = keccak256("token");

        mockCore.setProjectInvocations(PROJECT_ID, invocations);
        mockCore.setTokenHash(tokenId, hash);

        uint256 smallAmount = 1 wei;
        vm.deal(MINTER, smallAmount);
        vm.prank(MINTER);
        (bool success,) = address(receiver).call{value: smallAmount}("");

        assertTrue(success, "Should handle very small amounts");
    }

    function test_EdgeCase_VeryLargeAmount() public {
        uint256 invocations = 1;
        uint256 tokenId = BASE_TOKEN_ID;
        bytes32 hash = keccak256("token");

        mockCore.setProjectInvocations(PROJECT_ID, invocations);
        mockCore.setTokenHash(tokenId, hash);

        uint256 largeAmount = 1000 ether;
        vm.deal(MINTER, largeAmount);
        vm.prank(MINTER);
        (bool success,) = address(receiver).call{value: largeAmount}("");

        assertTrue(success, "Should handle large amounts");
    }

    // ============================================
    // Fuzz Tests
    // ============================================

    function testFuzz_Receive_AnyValidInvocation(uint256 invocations) public {
        // Bound invocations to reasonable range (1 to 1 million)
        invocations = bound(invocations, 1, 1_000_000);

        uint256 expectedTokenId = BASE_TOKEN_ID + invocations - 1;
        bytes32 hash = keccak256(abi.encodePacked("token", invocations));

        mockCore.setProjectInvocations(PROJECT_ID, invocations);
        mockCore.setTokenHash(expectedTokenId, hash);

        vm.deal(MINTER, 1 ether);
        vm.prank(MINTER);
        (bool success,) = address(receiver).call{value: 1 ether}("");

        assertTrue(success, "Should succeed for any valid invocation");
        assertEq(address(receiver).balance, 0, "Should forward all funds");
    }

    function testFuzz_Receive_AnyAmount(uint256 amount) public {
        // Bound amount to reasonable range
        amount = bound(amount, 0, 10000 ether);

        uint256 invocations = 1;
        uint256 tokenId = BASE_TOKEN_ID;
        bytes32 hash = keccak256("token");

        mockCore.setProjectInvocations(PROJECT_ID, invocations);
        mockCore.setTokenHash(tokenId, hash);

        vm.deal(MINTER, amount);
        vm.prank(MINTER);
        (bool success,) = address(receiver).call{value: amount}("");

        assertTrue(success, "Should succeed for any amount");
        assertEq(address(receiver).balance, 0, "Should forward all funds");
    }

    function testFuzz_Receive_RevertsAnyUnauthorized(address sender) public {
        vm.assume(sender != MINTER);
        vm.assume(sender != address(0)); // Can't prank zero address

        vm.deal(sender, 1 ether);
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(AdditionalPayeeReceiver.UnauthorizedSender.selector, sender));
        address(receiver).call{value: 1 ether}("");
    }
}

