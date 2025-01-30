// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/AMM.sol";
import "solady/utils/FixedPointMathLib.sol";

// Mock ERC20 token for testing
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract AMMTest is Test {
    AMM public amm;
    address public token0;
    address public token1;

    function setUp() public {
        // Deploy the AMM contract
        amm = new AMM();

        // Deploy mock ERC20 tokens for testing
        token0 = address(new MockERC20("Token0", "TKN0"));
        token1 = address(new MockERC20("Token1", "TKN1"));

        // Initialize the pool
        amm.initializePool(token0, token1);
    }

    function testInitializePool() public {
        // Check that the pool is initialized
        (bool isInitialized,,) = amm.getPoolInfo(token0, token1);
        assertTrue(isInitialized);

        (isInitialized,,) = amm.getPoolInfo(token1, token0);
        assertTrue(isInitialized);

        // Try to initialize the pool again (should revert)
        vm.expectRevert(AMM.PoolAlreadyExist.selector);
        amm.initializePool(token0, token1);
        vm.expectRevert(AMM.PoolAlreadyExist.selector);
        amm.initializePool(token1, token0);
    }

    function testAddInitialLiquidity(uint256 amount0, uint256 amount1) public {
        amount0 = _bound(amount0, 1, (2 ** 128 - 1));
        amount1 = _bound(amount1, 1, (2 ** 128 - 1));

        // Mint tokens to the test contract
        MockERC20(token0).mint(address(this), amount0);
        MockERC20(token1).mint(address(this), amount1);

        // Approve the AMM contract to spend tokens
        MockERC20(token0).approve(address(amm), amount0);
        MockERC20(token1).approve(address(amm), amount1);

        // Add liquidity
        amm.addLiquidity(token0, token1, amount0, amount1, 0, 0);

        // Check that reserves are updated correctly
        (, uint256 reserve0, uint256 reserve1) = amm.getPoolInfo(token0, token1);
        assertEq(reserve0, amount0);
        assertEq(reserve1, amount1);

        // Check LP token balance
        uint256 id = uint256(keccak256(abi.encode(token0, token1)));
        uint256 lpBalance = amm.balanceOf(address(this), id);
        assertEq(lpBalance, FixedPointMathLib.sqrt(amount0 * amount1));
    }

    function testAddLiquidityRevertWIthPoolNotExist() public {
        address invalidToken = address(0x1234);

        vm.expectRevert(AMM.PoolNotExist.selector);
        amm.addLiquidity(invalidToken, token1, 100 ether, 100 ether, 0, 0);
    }

    function testAddLiquidityRevertWithLiquidityMustbeNotZero() public {
        vm.expectRevert(AMM.LiquidityMustbeNotZero.selector);
        amm.addLiquidity(token0, token1, 123, 0, 0, 0);
    }

    function testAddLiquidityRevertWithIncorrectAmount() public {
        uint256 amount0 = 100 ether;
        uint256 amount1 = 50 ether;

        // Mint tokens to the test contract
        MockERC20(token0).mint(address(this), 150 ether);
        MockERC20(token1).mint(address(this), 150 ether);

        // Approve the AMM contract to spend tokens
        MockERC20(token0).approve(address(amm), type(uint256).max);
        MockERC20(token1).approve(address(amm), type(uint256).max);

        amm.addLiquidity(token0, token1, 10 ether, 5 ether, 0, 0);

        // Try to add liquidity with incorrect amounts (should revert)
        vm.expectRevert(AMM.IncorrectAmount.selector);
        amm.addLiquidity(token0, token1, amount0, amount1, amount0 - 1, amount1);

        vm.expectRevert(AMM.IncorrectAmount.selector);
        amm.addLiquidity(token0, token1, amount0, amount1, amount0, amount1 - 1);
    }

    function testRemoveLiquidity() public {
        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        // Mint tokens and add liquidity first
        MockERC20(token0).mint(address(this), amount0);
        MockERC20(token1).mint(address(this), amount1);
        MockERC20(token0).approve(address(amm), amount0);
        MockERC20(token1).approve(address(amm), amount1);
        amm.addLiquidity(token0, token1, amount0, amount1, 0, 0);

        // Remove liquidity
        uint256 id = uint256(keccak256(abi.encode(token0, token1)));
        uint256 lpBalance = amm.balanceOf(address(this), id);
        amm.removeLiquidity(address(this), token0, token1, lpBalance);

        // Check that reserves are updated correctly
        (, uint256 reserve0, uint256 reserve1) = amm.getPoolInfo(token0, token1);
        assertEq(reserve0, 1000);
        assertEq(reserve1, 1000);

        // Check LP token balance
        assertEq(amm.balanceOf(address(this), id), 0);
    }

    function testRemoveLiquidityRevertWithPoolNotExist() public {
        address invalidToken = address(0x1234);

        vm.expectRevert(AMM.PoolNotExist.selector);
        amm.removeLiquidity(address(this), invalidToken, token1, 100 ether);
    }

    function testRemoveLiquidityRevertWithLiquidityZero() public {
        vm.expectRevert(AMM.LiquidityMustbeNotZero.selector);
        amm.removeLiquidity(address(this), token0, token1, 0);
    }

    function testSwap() public {
        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        // Mint tokens and add liquidity first
        MockERC20(token0).mint(address(this), amount0);
        MockERC20(token1).mint(address(this), amount1);
        MockERC20(token0).approve(address(amm), amount0);
        MockERC20(token1).approve(address(amm), amount1);
        amm.addLiquidity(token0, token1, amount0, amount1, 0, 0);

        // Mint tokens for swapping
        uint256 amountIn = 10 ether;
        MockERC20(token0).mint(address(this), amountIn);
        MockERC20(token0).approve(address(amm), amountIn);

        // Perform the swap
        amm.swap(token0, amountIn, token1, 0, address(this));

        // Check that reserves are updated correctly
        (, uint256 reserve0, uint256 reserve1) = amm.getPoolInfo(token0, token1);
        assertEq(reserve0, amount0 + amountIn);
        assertEq(reserve1, amount1 - ((amount1 * amountIn) / (amount0 + amountIn)));
    }

    function test_Swap_RevertIfPoolNotExist() public {
        address invalidToken = address(0x1234);

        vm.expectRevert(AMM.PoolNotExist.selector);
        amm.swap(invalidToken, 10 ether, token1, 0, address(this));
    }

    function test_Swap_RevertIfAmountInZero() public {
        vm.expectRevert(AMM.InvalidAmount.selector);
        amm.swap(token0, 0, token1, 0, address(this));
    }

    function testSwapRevertIfMinAmountNotMet() public {
        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        // Mint tokens and add liquidity first
        MockERC20(token0).mint(address(this), amount0);
        MockERC20(token1).mint(address(this), amount1);
        MockERC20(token0).approve(address(amm), amount0);
        MockERC20(token1).approve(address(amm), amount1);
        amm.addLiquidity(token0, token1, amount0, amount1, 0, 0);

        // Mint tokens for swapping
        uint256 amountIn = 10 ether;
        MockERC20(token0).mint(address(this), amountIn);
        MockERC20(token0).approve(address(amm), amountIn);

        vm.expectRevert(AMM.MinAmountIssue.selector);
        amm.swap(token0, amountIn, token1, 100 ether, address(this));
    }
}
