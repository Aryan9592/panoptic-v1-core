// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Interfaces
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
// Panoptic's modified Uniswap libraries
import {LiquidityAmounts} from "@univ3-libraries/LiquidityAmounts.sol";
import {TickMath} from "@univ3-libraries/TickMath.sol";
//Libraries
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
// Custom types
import {LeftRight} from "@types/LeftRight.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {TokenId} from "@types/TokenId.sol";

/// @title Library for Fee Calculations.
/// @notice Some options positions involve moving liquidity chunks to the AMM/Uniswap. Those chunks can then earn AMM swap fees.
/// @dev
/// @dev          When price tick moves within
/// @dev          this liquidity chunk == an option leg within a `tokenId` option position:
/// @dev          Fees accumulate.
/// @dev                ◄────────────►
/// @dev     liquidity  ┌───┼────────┐
/// @dev          ▲     │   │        │
/// @dev          │     │   :        ◄──────Liquidity chunk
/// @dev          │     │   │        │      (an option position leg)
/// @dev          │   ┌─┴───┼────────┴─┐
/// @dev          │   │     │          │
/// @dev          │   │     :          │
/// @dev          │   │     │          │
/// @dev          │   │     :          │
/// @dev          │   │     │          │
/// @dev          └───┴─────┴──────────┴────► price
/// @dev                    ▲
/// @dev                    │
/// @dev            Current price tick
/// @dev              of the AMM
/// @dev
/// @dev Collect fees accumulated within option position legs (a leg is a liquidity chunk)
/// @author Axicon Labs Limited
library FeesCalc {
    // enables packing of types within int128|int128 or uint128|uint128 containers.
    using LeftRight for int256;
    using LeftRight for uint256;
    // represents a single liquidity chunk in Uniswap. Contains tickLower, tickUpper, and amount of liquidity
    using LiquidityChunk for uint256;
    // represents an option position of up to four legs as a sinlge ERC1155 tokenId
    using TokenId for uint256;

    /// @notice Calculate NAV of user's option portfolio at a given tick.
    /// @param univ3pool the pair the positions are on
    /// @param atTick the tick to calculate the value at
    /// @param userBalance the position balances of the user
    /// @param positionIdList a list of all positions the user holds on that pool
    /// @return value0 the amount of token0 owned by portfolio
    /// @return value1 the amount of token1 owned by portfolio
    function getPortfolioValue(
        IUniswapV3Pool univ3pool,
        int24 atTick,
        mapping(uint256 tokenId => uint256 balance) storage userBalance,
        uint256[] calldata positionIdList
    ) external view returns (int256 value0, int256 value1) {
        uint160 sqrtPriceAtTick = TickMath.getSqrtRatioAtTick(atTick);
        int24 ts = univ3pool.tickSpacing();
        for (uint256 k = 0; k < positionIdList.length; ) {
            uint256 tokenId = positionIdList[k];
            uint128 positionSize = userBalance[tokenId].rightSlot();
            uint256 numLegs = tokenId.countLegs();
            for (uint256 leg = 0; leg < numLegs; ) {
                uint256 liquidityChunk = PanopticMath.getLiquidityChunk(
                    tokenId,
                    leg,
                    positionSize,
                    ts
                );

                (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                    sqrtPriceAtTick,
                    TickMath.getSqrtRatioAtTick(liquidityChunk.tickLower()),
                    TickMath.getSqrtRatioAtTick(liquidityChunk.tickUpper()),
                    liquidityChunk.liquidity()
                );

                if (tokenId.isLong(leg) == 0) {
                    unchecked {
                        value0 += int256(amount0);
                        value1 += int256(amount1);
                    }
                } else {
                    unchecked {
                        value0 -= int256(amount0);
                        value1 -= int256(amount1);
                    }
                }

                unchecked {
                    ++leg;
                }
            }
            unchecked {
                ++k;
            }
        }
    }

    /// @notice Calculate the AMM Swap/Trading Fees for the incoming position (and leg `index` within that position)
    /// This is what defines the option price/premium
    /// @dev calculate the base (aka AMM swap trading) fees by looking at feeGrowth in the Uniswap v3 pool.
    /// @param univ3pool the AMM/Uniswap pool where premia is collected in
    /// @param currentTick the current price tick in the AMM
    /// @param tokenId the option position
    /// @param index the leg index to compute position fees for - this identifies a liquidity chunk in the AMM
    /// @param positionSize the size of the option position
    /// @return liquidityChunk the liquidity chunk in question representing the leg of the position
    /// @return feesPerToken the fees collected (LeftRight-packed) per token0 (right slot) and token1 (left slot)
    function calculateAMMSwapFees(
        IUniswapV3Pool univ3pool,
        int24 currentTick,
        uint256 tokenId,
        uint256 index,
        uint128 positionSize
    ) public view returns (uint256 liquidityChunk, int256 feesPerToken) {
        // extract the liquidity chunk representing the leg `index` of the option position `tokenId`
        liquidityChunk = PanopticMath.getLiquidityChunk(
            tokenId,
            index,
            positionSize,
            univ3pool.tickSpacing()
        );

        // Extract the AMM swap/trading fees collected by this option leg (liquidity chunk)
        // packed as LeftRight with token0 fees in the right slot and token1 fees in the left slot
        feesPerToken = calculateAMMSwapFeesLiquidityChunk(
            univ3pool,
            currentTick,
            liquidityChunk.liquidity(),
            liquidityChunk
        );
    }

    /// @notice Calculate the AMM Swap/trading fees for a `liquidityChunk` of each token.
    /// @dev read from the uniswap pool and compute the accumulated fees from swapping activity.
    /// @param univ3pool the AMM/Uniswap pool where fees are collected from
    /// @param currentTick the current price tick
    /// @param startingLiquidity the liquidity of the option position leg deployed in the AMM
    /// @param liquidityChunk the chunk of liquidity of the option position leg deployed in the AMM
    /// @return feesEachToken the fees collected from the AMM for each token (LeftRight-packed) with token0 in the right slot and token1 in the left slot
    function calculateAMMSwapFeesLiquidityChunk(
        IUniswapV3Pool univ3pool,
        int24 currentTick,
        uint128 startingLiquidity,
        uint256 liquidityChunk
    ) public view returns (int256 feesEachToken) {
        // extract the amount of AMM fees collected within the liquidity chunk`
        // note: the fee variables are *per unit of liquidity*; so more "rate" variables
        (
            uint256 ammFeesPerLiqToken0X128,
            uint256 ammFeesPerLiqToken1X128
        ) = _getAMMSwapFeesPerLiquidityCollected(
                univ3pool,
                currentTick,
                liquidityChunk.tickLower(),
                liquidityChunk.tickUpper()
            );

        // Use the fee growth (rate) variable to compute the absolute fees accumulated within the chunk:
        //   ammFeesToken0X128 * liquidity / (2**128)
        // to store the (absolute) fees as int128:
        feesEachToken = feesEachToken
            .toRightSlot(int128(int256(Math.mulDiv128(ammFeesPerLiqToken0X128, startingLiquidity))))
            .toLeftSlot(int128(int256(Math.mulDiv128(ammFeesPerLiqToken1X128, startingLiquidity))));
    }

    /// @notice Calculate the fee growth that has occurred (per unit of liquidity) in the AMM/Uniswap for an
    /// option position's `liquidity chunk` within its tick range given.
    /// @dev extract the feeGrowth from the uniswap v3 pool.
    /// @param univ3pool the AMM pool where the leg is deployed
    /// @param currentTick the current price tick in the AMM
    /// @param tickLower the lower tick of the option position leg (a liquidity chunk)
    /// @param tickUpper the upper tick of the option position leg (a liquidity chunk)
    /// @return feeGrowthInside0X128 the fee growth in the AMM of token0
    /// @return feeGrowthInside1X128 the fee growth in the AMM of token1
    function _getAMMSwapFeesPerLiquidityCollected(
        IUniswapV3Pool univ3pool,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        // Get feesGrowths from the option position's lower+upper ticks
        // lowerOut0: For token0: fee growth per unit of liquidity on the _other_ side of tickLower (relative to currentTick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        // (...)
        // upperOut1: For token1: fee growth on the _other_ side of tickUpper (again: relative to currentTick)
        // the point is: the range covered by lowerOut0 changes depending on where currentTick is.
        (, , uint256 lowerOut0, uint256 lowerOut1, , , , ) = univ3pool.ticks(tickLower);
        (, , uint256 upperOut0, uint256 upperOut1, , , , ) = univ3pool.ticks(tickUpper);

        // compute the effective feeGrowth, depending on whether price is above/below/within range
        unchecked {
            if (currentTick < tickLower) {
                /**
                  Diagrams shown for token0, and applies for token1 the same
                  L = lowerTick, U = upperTick

                    liquidity         lowerOut0 (all fees collected in this price tick range for token0)
                        ▲            ◄──────────────^v───► (to MAX_TICK)
                        │
                        │                      upperOut0
                        │                     ◄─────^v───►
                        │           ┌────────┐
                        │           │ chunk  │
                        │           │        │
                        └─────▲─────┴────────┴────────► price tick
                              │     L        U
                              │
                           current
                            tick
                */
                feeGrowthInside0X128 = lowerOut0 - upperOut0; // fee growth inside the chunk
                feeGrowthInside1X128 = lowerOut1 - upperOut1;
            } else if (currentTick >= tickUpper) {
                /**
                    liquidity
                        ▲           upperOut0
                        │◄─^v─────────────────────►
                        │     
                        │     lowerOut0  ┌────────┐
                        │◄─^v───────────►│ chunk  │
                        │                │        │
                        └────────────────┴────────┴─▲─────► price tick
                                         L        U │
                                                    │
                                                 current
                                                  tick
                 */
                feeGrowthInside0X128 = upperOut0 - lowerOut0;
                feeGrowthInside1X128 = upperOut1 - lowerOut1;
            } else {
                /**
                  current AMM tick is within the option position range (within the chunk)

                     liquidity
                        ▲        feeGrowthGlobal0X128 = global fee growth
                        │                             = (all fees collected for the entire price range for token 0)
                        │
                        │                        
                        │     lowerOut0  ┌──────────────┐ upperOut0
                        │◄─^v───────────►│              │◄─────^v───►
                        │                │     chunk    │
                        │                │              │
                        └────────────────┴───────▲──────┴─────► price tick
                                         L       │      U
                                                 │
                                              current
                                               tick
                */
                feeGrowthInside0X128 = univ3pool.feeGrowthGlobal0X128() - lowerOut0 - upperOut0;
                feeGrowthInside1X128 = univ3pool.feeGrowthGlobal1X128() - lowerOut1 - upperOut1;
            }
        }
    }
}
