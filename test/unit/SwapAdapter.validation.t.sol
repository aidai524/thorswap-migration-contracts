// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title SwapAdapter.validation.t.sol
 * @notice Unit tests for SwapAdapter (business paths + security boundaries).
 */

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SwapAdapter, IV3SwapRouter } from "../../src/SwapAdapter.sol";
import { ERC20Mintable } from "../mocks/ERC20Mintable.sol";

contract SwapAdapterValidationTest is Test {
    event Swapped(uint256 amountIn, uint256 amountOut, uint8 dexType);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    /// @notice xMETRO address (EOA in tests) for onlyXMetro checks.
    address internal xmetro = makeAddr("xMETRO");
    address internal owner = address(this);
    address internal user = makeAddr("user");

    ERC20Mintable internal usdc;
    ERC20Mintable internal metro;
    SwapAdapter internal adapter;
    MockRouterV2 internal routerV2;
    MockRouterV3 internal routerV3;

    /// @dev Uniswap V2.
    uint8 internal constant DEX_V2 = 0;

    /// @dev Uniswap V3.
    uint8 internal constant DEX_V3 = 1;

    function setUp() public {
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        metro = new ERC20Mintable("METRO", "METRO", 18);

        routerV2 = new MockRouterV2(address(usdc), address(metro));
        routerV3 = new MockRouterV3(address(usdc), address(metro));

        adapter = new SwapAdapter(
            address(usdc),
            address(metro),
            xmetro,
            address(routerV2),
            address(routerV3),
            owner
        );
    }

    /// @dev Encode V2 swapData: abi.encode(DEX_V2, abi.encode(path)).
    function _encodeV2(address[] memory path) internal pure returns (bytes memory) {
        return abi.encode(uint8(DEX_V2), abi.encode(path));
    }

    /// @dev Encode V3 swapData: abi.encode(DEX_V3, packedPath).
    function _encodeV3(bytes memory packedPath) internal pure returns (bytes memory) {
        return abi.encode(uint8(DEX_V3), packedPath);
    }

    /// @dev Encode V3 packed path: token0 + fee0 + token1 (+ fee1 + token2 ...).
    function _encodeV3Path(address[] memory tokens, uint24[] memory fees) internal pure returns (bytes memory path) {
        require(tokens.length >= 2, "bad tokens len");
        require(fees.length == tokens.length - 1, "bad fees len");

        path = abi.encodePacked(tokens[0]);
        for (uint256 i = 0; i < fees.length; i++) {
            path = abi.encodePacked(path, fees[i], tokens[i + 1]);
        }
    }

    /// @dev Fund xMETRO with USDC and approve the adapter (simulate pre-approve flow).
    function _fundAndApproveXMetro(uint256 amount) internal {
        usdc.mint(xmetro, amount);
        vm.prank(xmetro);
        usdc.approve(address(adapter), type(uint256).max);
    }

    function test_Constructor_ZeroAddr_Revert() public {
        vm.expectRevert(bytes("SwapAdapter: zero addr"));
        new SwapAdapter(address(0), address(metro), xmetro, address(routerV2), address(routerV3), owner);

        vm.expectRevert(bytes("SwapAdapter: zero addr"));
        new SwapAdapter(address(usdc), address(0), xmetro, address(routerV2), address(routerV3), owner);

        vm.expectRevert(bytes("SwapAdapter: zero addr"));
        new SwapAdapter(address(usdc), address(metro), address(0), address(routerV2), address(routerV3), owner);

        vm.expectRevert(bytes("SwapAdapter: zero router"));
        new SwapAdapter(address(usdc), address(metro), xmetro, address(0), address(routerV3), owner);

        vm.expectRevert(bytes("SwapAdapter: zero router"));
        new SwapAdapter(address(usdc), address(metro), xmetro, address(routerV2), address(0), owner);
    }

    function test_OnlyXMetro() public {
        bytes memory swapData = abi.encode(uint8(0), bytes(""));
        vm.expectRevert(bytes("SwapAdapter: only xMETRO"));
        adapter.swap(1, 0, swapData);
    }

    function test_Pause_Unpause_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        adapter.pause();

        adapter.pause();

        vm.prank(user);
        vm.expectRevert();
        adapter.unpause();

        adapter.unpause();
    }

    function test_V2_EmptyRoutes_Revert() public {
        bytes memory pathData = abi.encode(new address[](0));
        bytes memory swapData = abi.encode(uint8(0), pathData);

        usdc.mint(xmetro, 1e6);
        vm.prank(xmetro);
        usdc.approve(address(adapter), type(uint256).max);

        vm.prank(xmetro);
        vm.expectRevert(bytes("SwapAdapter: bad path"));
        adapter.swap(1e6, 0, swapData);
    }

    function test_V3_BadPath_Revert() public {
        bytes memory badPath = hex"1234";
        bytes memory swapData = abi.encode(uint8(1), badPath);

        usdc.mint(xmetro, 1e6);
        vm.prank(xmetro);
        usdc.approve(address(adapter), type(uint256).max);

        vm.prank(xmetro);
        vm.expectRevert(bytes("SwapAdapter: bad path"));
        adapter.swap(1e6, 0, swapData);
    }

    function test_RescueTokens_NotRequirePaused() public {
        usdc.mint(address(adapter), 1e6);

        adapter.rescueTokens(address(usdc), address(this), 1e6);
        assertEq(usdc.balanceOf(address(this)), 1e6);
    }

    function test_RescueTokens_OnlyOwner_AndBadToRevert() public {
        usdc.mint(address(adapter), 123);
        vm.prank(user);
        vm.expectRevert();
        adapter.rescueTokens(address(usdc), user, 1);

        vm.expectRevert(bytes("SwapAdapter: bad to"));
        adapter.rescueTokens(address(usdc), address(0), 1);

        vm.expectEmit(true, true, false, true);
        emit TokensRescued(address(usdc), user, 23);
        adapter.rescueTokens(address(usdc), user, 23);
        assertEq(usdc.balanceOf(user), 23);
    }

    function test_Swap_WhenPaused_Revert() public {
        adapter.pause();

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(metro);
        bytes memory swapData = _encodeV2(path);

        _fundAndApproveXMetro(1e6);
        vm.prank(xmetro);
        vm.expectRevert();
        adapter.swap(1e6, 0, swapData);
    }

    function test_Swap_ZeroAmount_Revert() public {
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(metro);
        bytes memory swapData = _encodeV2(path);

        vm.prank(xmetro);
        vm.expectRevert(bytes("SwapAdapter: zero amount"));
        adapter.swap(0, 0, swapData);
    }

    function test_Swap_BadDexType_Revert() public {
        _fundAndApproveXMetro(1e6);
        vm.prank(xmetro);
        vm.expectRevert(bytes("SwapAdapter: bad dexType"));
        adapter.swap(1e6, 0, abi.encode(uint8(99), bytes("")));
    }

    function test_Swap_V2_Success_MintsToXMetro_AndAllowanceReset() public {
        uint256 amountIn = 1_000_000;
        uint256 expectedOut = routerV2.quoteOut(amountIn);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(metro);
        bytes memory swapData = _encodeV2(path);

        _fundAndApproveXMetro(amountIn);

        vm.expectEmit(false, false, false, true);
        emit Swapped(amountIn, expectedOut, DEX_V2);

        vm.prank(xmetro);
        uint256 out = adapter.swap(amountIn, expectedOut, swapData);

        assertEq(out, expectedOut);
        assertEq(metro.balanceOf(xmetro), expectedOut);
        assertEq(usdc.balanceOf(xmetro), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);

        assertEq(usdc.allowance(address(adapter), address(routerV2)), 0);
    }

    function test_Swap_V2_SlippageRevert_WhenReceivedTooLow() public {
        uint256 amountIn = 1_000_000;
        uint256 out = routerV2.quoteOut(amountIn);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(metro);
        bytes memory swapData = _encodeV2(path);

        _fundAndApproveXMetro(amountIn);
        vm.prank(xmetro);
        vm.expectRevert(bytes("SwapAdapter: slippage"));
        adapter.swap(amountIn, out + 1, swapData);
    }

    function test_Swap_V2_RevertsIfRouterDoesNotCreditXMetro() public {
        MockRouterV2WrongRecipient badRouter = new MockRouterV2WrongRecipient(address(usdc), address(metro));
        SwapAdapter localAdapter = new SwapAdapter(
            address(usdc),
            address(metro),
            xmetro,
            address(badRouter),
            address(routerV3),
            owner
        );

        uint256 amountIn = 1_000_000;
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(metro);
        bytes memory swapData = abi.encode(uint8(DEX_V2), abi.encode(path));

        usdc.mint(xmetro, amountIn);
        vm.prank(xmetro);
        usdc.approve(address(localAdapter), type(uint256).max);

        vm.prank(xmetro);
        vm.expectRevert(bytes("SwapAdapter: slippage"));
        localAdapter.swap(amountIn, 1, swapData);
    }

    function test_Swap_V3_SingleHop_Success_AndAllowanceReset() public {
        uint256 amountIn = 2_000_000;
        uint256 expectedOut = routerV3.quoteOut(amountIn);

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(metro);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;

        bytes memory path = _encodeV3Path(tokens, fees);
        bytes memory swapData = _encodeV3(path);

        _fundAndApproveXMetro(amountIn);

        vm.expectEmit(false, false, false, true);
        emit Swapped(amountIn, expectedOut, DEX_V3);

        vm.prank(xmetro);
        uint256 out = adapter.swap(amountIn, expectedOut, swapData);

        assertEq(out, expectedOut);
        assertEq(metro.balanceOf(xmetro), expectedOut);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.allowance(address(adapter), address(routerV3)), 0);
    }

    function test_Swap_V3_RevertsIfRouterDoesNotCreditXMetro() public {
        MockRouterV3WrongRecipient badRouter = new MockRouterV3WrongRecipient(address(usdc), address(metro));
        SwapAdapter localAdapter = new SwapAdapter(
            address(usdc),
            address(metro),
            xmetro,
            address(routerV2),
            address(badRouter),
            owner
        );

        uint256 amountIn = 2_000_000;
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(metro);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        bytes memory path = _encodeV3Path(tokens, fees);
        bytes memory swapData = _encodeV3(path);

        usdc.mint(xmetro, amountIn);
        vm.prank(xmetro);
        usdc.approve(address(localAdapter), type(uint256).max);

        vm.prank(xmetro);
        vm.expectRevert(bytes("SwapAdapter: slippage"));
        localAdapter.swap(amountIn, 1, swapData);
    }

    function test_Swap_V3_MultiHop_Success() public {
        uint256 amountIn = 3_000_000;
        uint256 expectedOut = routerV3.quoteOut(amountIn);

        address mid = makeAddr("MID");
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = mid;
        tokens[2] = address(metro);
        uint24[] memory fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 3000;

        bytes memory path = _encodeV3Path(tokens, fees);
        bytes memory swapData = _encodeV3(path);

        _fundAndApproveXMetro(amountIn);
        vm.prank(xmetro);
        uint256 out = adapter.swap(amountIn, expectedOut, swapData);

        assertEq(out, expectedOut);
        assertEq(metro.balanceOf(xmetro), expectedOut);
    }

    function test_V2_BadRouteIn_Revert() public {
        uint256 amountIn = 1_000_000;

        address[] memory path = new address[](2);
        path[0] = makeAddr("NOT_USDC");
        path[1] = address(metro);
        bytes memory swapData = _encodeV2(path);

        _fundAndApproveXMetro(amountIn);
        vm.prank(xmetro);
        vm.expectRevert(bytes("SwapAdapter: bad path in"));
        adapter.swap(amountIn, 0, swapData);
    }

    function test_V2_BadRouteOut_Revert() public {
        uint256 amountIn = 1_000_000;

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = makeAddr("NOT_METRO");
        bytes memory swapData = _encodeV2(path);

        _fundAndApproveXMetro(amountIn);
        vm.prank(xmetro);
        vm.expectRevert(bytes("SwapAdapter: bad path out"));
        adapter.swap(amountIn, 0, swapData);
    }

    function test_V2_BadPathLen_Revert() public {
        uint256 amountIn = 1_000_000;

        address[] memory path = new address[](1);
        path[0] = address(usdc);
        bytes memory swapData = _encodeV2(path);

        _fundAndApproveXMetro(amountIn);
        vm.prank(xmetro);
        vm.expectRevert(bytes("SwapAdapter: bad path"));
        adapter.swap(amountIn, 0, swapData);
    }

    function test_V3_BadPathLen_Revert() public {
        uint256 amountIn = 1_000_000;
        _fundAndApproveXMetro(amountIn);

        bytes memory badLen = new bytes(44);
        bytes memory swapData = _encodeV3(badLen);

        vm.prank(xmetro);
        vm.expectRevert(bytes("SwapAdapter: bad path len"));
        adapter.swap(amountIn, 0, swapData);
    }

    function test_V3_BadPathInOut_Revert() public {
        uint256 amountIn = 1_000_000;
        _fundAndApproveXMetro(amountIn);

        address[] memory tokens1 = new address[](2);
        tokens1[0] = makeAddr("NOT_USDC");
        tokens1[1] = address(metro);
        uint24[] memory fees1 = new uint24[](1);
        fees1[0] = 500;
        bytes memory path1 = _encodeV3Path(tokens1, fees1);

        vm.prank(xmetro);
        vm.expectRevert(bytes("SwapAdapter: bad path in"));
        adapter.swap(amountIn, 0, _encodeV3(path1));

        address[] memory tokens2 = new address[](2);
        tokens2[0] = address(usdc);
        tokens2[1] = makeAddr("NOT_METRO");
        uint24[] memory fees2 = new uint24[](1);
        fees2[0] = 500;
        bytes memory path2 = _encodeV3Path(tokens2, fees2);

        vm.prank(xmetro);
        vm.expectRevert(bytes("SwapAdapter: bad path out"));
        adapter.swap(amountIn, 0, _encodeV3(path2));
    }

    function test_NonReentrant_RouterCallsBackIntoXMetro_Revert() public {
        ReenterRouterV2 reenterRouter = new ReenterRouterV2(address(usdc), address(metro));
        XMetroCaller xmetroContract = new XMetroCaller(address(usdc));

        SwapAdapter localAdapter = new SwapAdapter(
            address(usdc),
            address(metro),
            address(xmetroContract),
            address(reenterRouter),
            address(routerV3),
            owner
        );

        reenterRouter.setTargets(address(localAdapter), address(xmetroContract));
        xmetroContract.setAdapter(address(localAdapter));

        uint256 amountIn = 1_000_000;
        usdc.mint(address(xmetroContract), amountIn * 2);
        xmetroContract.approveToAdapter(type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(metro);
        bytes memory swapData = abi.encode(uint8(DEX_V2), abi.encode(path));

        vm.expectRevert();
        xmetroContract.callSwap(amountIn, 0, swapData);
    }

    function test_ForceApprove_CompatibleWithRequireZeroApproveToken() public {
        ERC20RequireZeroApprove usdtLike = new ERC20RequireZeroApprove("USDTLike", "USDT", 6);
        ERC20Mintable metro2 = new ERC20Mintable("METRO2", "METRO2", 18);
        MockRouterV2 router2 = new MockRouterV2(address(usdtLike), address(metro2));
        MockRouterV3 router3 = new MockRouterV3(address(usdtLike), address(metro2));

        SwapAdapter localAdapter = new SwapAdapter(
            address(usdtLike),
            address(metro2),
            xmetro,
            address(router2),
            address(router3),
            owner
        );

        usdtLike.setAllowanceForTest(address(localAdapter), address(router2), 1);

        uint256 amountIn = 1_000_000;
        usdtLike.mint(xmetro, amountIn * 2);
        vm.prank(xmetro);
        usdtLike.approve(address(localAdapter), type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = address(usdtLike);
        path[1] = address(metro2);
        bytes memory swapData = abi.encode(uint8(DEX_V2), abi.encode(path));

        vm.prank(xmetro);
        localAdapter.swap(amountIn, 0, swapData);

        usdtLike.setAllowanceForTest(address(localAdapter), address(router2), 7);

        vm.prank(xmetro);
        localAdapter.swap(amountIn, 0, swapData);
        assertEq(metro2.balanceOf(xmetro), router2.quoteOut(amountIn) * 2);
    }
}

/**
 * @title MockRouterV2
 * @notice Simulates Uniswap V2 router behavior for unit tests.
 */
contract MockRouterV2 {
    ERC20Mintable internal outToken;
    IERC20 internal inToken;

    constructor(address inToken_, address outToken_) {
        inToken = IERC20(inToken_);
        outToken = ERC20Mintable(outToken_);
    }

    /// @notice Simple quote: 1 USDC -> 2 METRO (tests only).
    function quoteOut(uint256 amountIn) external pure returns (uint256) {
        return amountIn * 2;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 /*amountOutMin*/,
        address[] calldata /*path*/,
        address to,
        uint256 /*deadline*/
    ) external returns (uint256[] memory amounts) {
        require(inToken.transferFrom(msg.sender, address(this), amountIn), "transferFrom failed");
        outToken.mint(to, amountIn * 2);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * 2;
    }
}

/**
 * @title MockRouterV2WrongRecipient
 * @notice Malicious router: mints output to adapter (msg.sender) instead of `to`.
 * @dev Validates SwapAdapter's balance-delta check.
 */
contract MockRouterV2WrongRecipient {
    ERC20Mintable internal outToken;
    IERC20 internal inToken;

    constructor(address inToken_, address outToken_) {
        inToken = IERC20(inToken_);
        outToken = ERC20Mintable(outToken_);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256,
        address[] calldata,
        address,
        uint256
    ) external returns (uint256[] memory amounts) {
        require(inToken.transferFrom(msg.sender, address(this), amountIn), "transferFrom failed");
        outToken.mint(msg.sender, amountIn * 2);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * 2;
    }
}

/**
 * @title MockRouterV3
 * @notice Simulates Uniswap V3 router exactInput behavior.
 */
contract MockRouterV3 {
    ERC20Mintable internal outToken;
    IERC20 internal inToken;

    constructor(address inToken_, address outToken_) {
        inToken = IERC20(inToken_);
        outToken = ERC20Mintable(outToken_);
    }

    function quoteOut(uint256 amountIn) external pure returns (uint256) {
        return amountIn * 2;
    }

    function exactInput(
        IV3SwapRouter.ExactInputParams calldata params
    ) external payable returns (uint256 amountOut) {
        require(inToken.transferFrom(msg.sender, address(this), params.amountIn), "transferFrom failed");
        amountOut = params.amountIn * 2;
        outToken.mint(params.recipient, amountOut);
    }
}

/**
 * @title MockRouterV3WrongRecipient
 * @notice Malicious router: mints output to adapter (msg.sender) instead of params.recipient.
 */
contract MockRouterV3WrongRecipient {
    ERC20Mintable internal outToken;
    IERC20 internal inToken;

    constructor(address inToken_, address outToken_) {
        inToken = IERC20(inToken_);
        outToken = ERC20Mintable(outToken_);
    }

    function exactInput(IV3SwapRouter.ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        require(inToken.transferFrom(msg.sender, address(this), params.amountIn), "transferFrom failed");
        amountOut = params.amountIn * 2;
        outToken.mint(msg.sender, amountOut);
    }
}

/**
 * @title XMetroCaller
 * @notice Minimal contract that simulates xMETRO calling SwapAdapter.swap().
 * @dev Lets a router callback reenter within the same transaction.
 */
contract XMetroCaller {
    address public adapter;
    IERC20 public immutable usdc;

    constructor(address usdc_) {
        usdc = IERC20(usdc_);
    }

    function setAdapter(address adapter_) external {
        adapter = adapter_;
    }

    function approveToAdapter(uint256 amount) external {
        usdc.approve(adapter, amount);
    }

    /// @notice External swap call entry.
    function callSwap(uint256 amountIn, uint256 minOut, bytes calldata swapData) external returns (uint256) {
        return SwapAdapter(adapter).swap(amountIn, minOut, swapData);
    }

    /// @notice Called by router to attempt reentrancy (should hit nonReentrant).
    function reenterSwap(uint256 amountIn, bytes calldata swapData) external {
        SwapAdapter(adapter).swap(amountIn, 0, swapData);
    }
}

/**
 * @title ReenterRouterV2
 * @notice Malicious router that calls back into xMETRO during swap to trigger reentrancy.
 */
contract ReenterRouterV2 {
    IERC20 public immutable inToken;
    ERC20Mintable public immutable outToken;

    address public adapter;
    address public xmetro;

    constructor(address inToken_, address outToken_) {
        inToken = IERC20(inToken_);
        outToken = ERC20Mintable(outToken_);
    }

    function setTargets(address adapter_, address xmetro_) external {
        adapter = adapter_;
        xmetro = xmetro_;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        require(inToken.transferFrom(msg.sender, address(this), amountIn), "transferFrom failed");

        bytes memory swapData = abi.encode(uint8(0), abi.encode(path));
        XMetroCaller(xmetro).reenterSwap(amountIn, swapData);

        outToken.mint(to, amountIn * 2);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * 2;
    }
}

/**
 * @title ERC20RequireZeroApprove
 * @notice USDT-like approve behavior: if allowance != 0, must approve(0) first.
 * @dev Used to validate SafeERC20.forceApprove compatibility.
 */
contract ERC20RequireZeroApprove is ERC20Mintable {
    /// @dev Custom allowance mapping (avoid clashing with OZ internals).
    mapping(address => mapping(address => uint256)) private _allowances2;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20Mintable(name_, symbol_, decimals_) {}

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances2[owner][spender];
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        if (_allowances2[msg.sender][spender] != 0 && value != 0) revert("USDTLike: must approve 0 first");
        _allowances2[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        uint256 currentAllowance = _allowances2[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= value, "ERC20: insufficient allowance");
            unchecked {
                _allowances2[from][msg.sender] = currentAllowance - value;
            }
            emit Approval(from, msg.sender, _allowances2[from][msg.sender]);
        }
        _transfer(from, to, value);
        return true;
    }

    /// @notice Test-only: set allowance directly to simulate legacy non-zero allowance.
    function setAllowanceForTest(address owner, address spender, uint256 value) external {
        _allowances2[owner][spender] = value;
        emit Approval(owner, spender, value);
    }
}
