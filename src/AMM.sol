// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC6909} from "solady/tokens/ERC6909.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract AMM is ERC6909 {
    /// @dev If pool is already initialized.
    error PoolAlreadyExist();
    /// @dev If pool is already not initialized.
    error PoolNotExist();

    /// @dev If Amount doesn't match to desried.
    error IncorrectAmount();
    /// @dev If liquity is zero at add/remove time.
    error LiquidityMustbeNotZero();

    /// @dev If `amountIn == 0` during swap.
    error InvalidAmount();
    /// @dev If enough liquidity not available for a swap
    error InsufficientLiquidity();

    /// @dev If `amountOut` is less than minimum required
    error MinAmountIssue();

    /// @dev If Pool both token address is same.
    error AddressMustBeNotSame();

    /// @dev emit when new pool is initialized
    event PoolInitialized(address token0, address token1);

    /// @dev store pool information
    ///
    /// Storage layout :-
    ///     mstore(0x00, token0)
    ///     mstore(0x20, token1)
    ///     let poolSlot := keccak256(0x00, 0x20)
    ///     isInitialized := sload(poolSlot)
    ///     reserve0 := sload(add(poolSlot, 1))
    ///     reserve1 := sload(add(poolSlot, 2))
    struct PoolInformation {
        bool isInitialized;
        uint256 reserve0;
        uint256 reserve1;
    }

    /// @dev Track total supply of lp token for each pool.
    mapping(uint256 id => uint256) totalSupply;

    /// @dev Create token0 and token1 pair of x*y >= k pool.
    function initializePool(address token0, address token1) public {
        (bool isInitialized,,) = getPoolInfo(token0, token1);
        (token0, token1) = sortAddress(token0, token1);
        if (isInitialized) revert PoolAlreadyExist();
        if (token0 == token1) revert AddressMustBeNotSame();
        initPool(token0, token1);
        // mint minimal liquity to zero address prevent inflation attack
        uint256 id = uint256(keccak256(abi.encode(token0, token1)));
        _mint(address(0), id, 1000);
        totalSupply[id] += 1000;
        emit PoolInitialized(token0, token1);
    }

    /// @dev Add liquidity to pool of token0 and token1.
    function addLiquidity(
        address token0,
        address token1,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0InMin,
        uint256 amount1InMin
    ) public {
        (bool isInitialized, uint256 reserve0, uint256 reserve1) = getPoolInfo(token0, token1);

        if (!isInitialized) revert PoolNotExist();

        (address token0Sorted, address token1Sorted) = sortAddress(token0, token1);
        uint256 id = uint256(keccak256(abi.encode(token0Sorted, token1Sorted)));
        uint256 amount0Optimal;
        uint256 amount1Optimal;
        {
            uint256 liquidity;
            if (reserve0 == 0 && reserve1 == 0) {
                amount0Optimal = amount0In;
                amount1Optimal = amount1In;
                liquidity = FixedPointMathLib.sqrt(amount0In * amount1In);
            } else {
                amount0Optimal = getOptimalAmount(amount0In, reserve0, reserve1);
                if (amount0Optimal > amount0InMin) revert IncorrectAmount();
                amount1Optimal = getOptimalAmount(amount1In, reserve1, reserve0);
                if (amount1Optimal > amount1InMin) revert IncorrectAmount();

                liquidity = FixedPointMathLib.min(
                    (amount0Optimal * totalSupply[id] / reserve0), (amount1Optimal * totalSupply[id] / reserve1)
                );
            }

            if (liquidity == 0) revert LiquidityMustbeNotZero();

            SafeTransferLib.safeTransferFrom(token0, msg.sender, address(this), amount0Optimal);
            SafeTransferLib.safeTransferFrom(token1, msg.sender, address(this), amount1Optimal);

            _mint(msg.sender, id, liquidity);
            totalSupply[id] += liquidity;
        }
        _update(token0, reserve0 + amount0Optimal, token1, reserve1 + amount1Optimal);
    }

    /// @dev Remove liquidity from pool of `token0` and `token1`.
    function removeLiquidity(address to, address token0, address token1, uint256 liquidity) public {
        (bool isInitialized, uint256 reserve0, uint256 reserve1) = getPoolInfo(token0, token1);

        if (!isInitialized) revert PoolNotExist();

        if (liquidity == 0) revert LiquidityMustbeNotZero();

        (address token0Sorted, address token1Sorted) = sortAddress(token0, token1);
        uint256 id = uint256(keccak256(abi.encode(token0Sorted, token1Sorted)));

        uint256 amount0Out = (liquidity * reserve0) / totalSupply[id];

        uint256 amount1Out = (liquidity * reserve1) / totalSupply[id];

        _update(token0, reserve0 - amount0Out, token1, reserve1 - amount1Out);

        totalSupply[id] -= liquidity;
        _burn(msg.sender, id, liquidity);

        SafeTransferLib.safeTransfer(token0, to, amount0Out);
        SafeTransferLib.safeTransfer(token1, to, amount1Out);
    }

    /// @dev swap tokens using constant product formula (x*y=k).
    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOutMin, address to) public {
        (bool isInitialized, uint256 reserve0, uint256 reserve1) = getPoolInfo(tokenIn, tokenOut);
        if (!isInitialized) revert PoolNotExist();
        if (amountIn == 0) revert InvalidAmount();

        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);

        // dy = y.dx / (x+dx)
        uint256 amountOut = ((reserve1 * amountIn * 1e18) / (reserve0 + amountIn)) / 1e18;

        // (x + dx) * (y - dy) >= x.y
        if ((reserve0 + amountIn) * (reserve1 - amountOut) < (reserve0 * reserve1)) revert InsufficientLiquidity();

        // `amountOut` must be greater or equals `amountOutMin`
        if (amountOut < amountOutMin) revert MinAmountIssue();

        SafeTransferLib.safeTransfer(tokenOut, to, amountOut);
        _update(tokenIn, reserve0 + amountIn, tokenOut, reserve1 - amountOut);
    }

    /// @dev Calculate optimal token amount based on reserves to maintain 50:50 ratio
    function getOptimalAmount(uint256 amount0, uint256 reserve0, uint256 reserve1)
        internal
        pure
        returns (uint256 amount1Optimial)
    {
        return (amount0 * reserve0) / reserve1;
    }

    /// @dev Sort token addresses to ensure consistent pool Info
    function sortAddress(address token0, address token1) internal pure returns (address, address) {
        if (uint160(token0) > uint160(token1)) {
            return (token1, token0);
        } else {
            return (token0, token1);
        }
    }

    /// @dev Get pool information from `token0` and `token1`
    function getPoolInfo(address token0, address token1)
        public
        view
        returns (bool isInitialized, uint256 reserve0, uint256 reserve1)
    {
        (address tokenA, address tokenB) = sortAddress(token0, token1);
        assembly {
            mstore(0x00, tokenA)
            mstore(0x20, tokenB)
            let con := eq(token1, tokenA)
            let key := keccak256(0x00, 0x20)
            isInitialized := sload(key)
            reserve0 := sload(add(key, add(1, con)))
            reserve1 := sload(add(key, add(1, iszero(con))))
        }
    }

    /// @dev Initialize pool of `token0` and `token1`.
    function initPool(address token0, address token1) internal {
        (token0, token1) = sortAddress(token0, token1);
        assembly {
            mstore(0x00, token0)
            mstore(0x20, token1)
            let slot := keccak256(0x00, 0x20)
            sstore(slot, 1) // true isInitialized
        }
    }

    /// @dev Updates pool reserve state.
    function _update(address token0, uint256 reserve0, address token1, uint256 reserve1) internal {
        (address tokenA, address tokenB) = sortAddress(token0, token1);
        assembly {
            mstore(0x00, tokenA)
            mstore(0x20, tokenB)
            let con := eq(token1, tokenA)
            let key := keccak256(0x00, 0x20)
            sstore(add(key, add(1, con)), reserve0)
            sstore(add(key, add(1, iszero(con))), reserve1)
        }
    }

    function name(uint256 id) public pure override returns (string memory) {
        id; // supress complier warning
        return "AMM LP Token";
    }

    function symbol(uint256 id) public pure override returns (string memory) {
        id; // supress complier warning
        return "AMM LP Token";
    }

    function tokenURI(uint256 id) public pure override returns (string memory) {
        id; // supress complier warning
        return "";
    }
}
