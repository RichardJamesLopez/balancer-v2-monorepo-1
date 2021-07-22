// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/ReentrancyGuard.sol";
import "@balancer-labs/v2-solidity-utils/contracts/helpers/WordCodec.sol";

import "../BaseWeightedPool.sol";
import "../WeightedPoolUserDataHelpers.sol";
import "./WeightCompression.sol";

/**
 * @dev Weighted Pool with mutable weights, designed to support V2 Liquidity Bootstrapping
 */
contract InvestmentPool is BaseWeightedPool, ReentrancyGuard {
    // The Pause Window and Buffer Period are timestamp-based: they should not be relied upon for sub-minute accuracy.
    // solhint-disable not-rely-on-time

    using FixedPoint for uint256;
    using WordCodec for bytes32;
    using WeightCompression for uint256;
    using WeightedPoolUserDataHelpers for bytes;

    // State variables

    // Store non-token-based values:
    // Start/end timestamps for gradual weight update
    // Cache total tokens
    // Swap enabled flag
    // [ 184 bits |  32 bits  |   32 bits  |    7 bits    |    1 bit     ]
    // [  unused  | end time  | start time | total tokens | swap enabled ]
    // |MSB                                                           LSB|
    bytes32 private _poolState;

    uint256 private constant _SWAP_ENABLED_OFFSET = 0;
    uint256 private constant _TOTAL_TOKENS_OFFSET = 1;
    uint256 private constant _START_TIME_OFFSET = 8;
    uint256 private constant _END_TIME_OFFSET = 40;

    // Store scaling factor and start/end weights for each token
    // Mapping should be more efficient than trying to compress it further
    // into a fixed array of bytes32 or something like that, especially
    // since tokens can be added/removed - and re-ordered in the process
    // For each token, we store:
    // [ 27 bits |  5 bits  | 8 bits | 8 bits | 112 bits  |  32 bits   |   64 bits    |
    // [ unused  | decimals | min R  | max R  | ref Price | end weight | start weight |
    // |MSB                                                                        LSB|
    mapping(IERC20 => bytes32) private _tokenState;

    uint256 private constant _START_WEIGHT_OFFSET = 0;
    uint256 private constant _END_WEIGHT_OFFSET = 64;
    uint256 private constant _INITIAL_BPT_PRICE_OFFSET = 96;
    uint256 private constant _MAX_RATIO_OFFSET = 208;
    uint256 private constant _MIN_RATIO_OFFSET = 216;
    uint256 private constant _DECIMAL_DIFF_OFFSET = 224;
 
    uint256 private constant _MIN_CIRCUIT_BREAKER_RATIO = 0.1e18;
    uint256 private constant _MAX_CIRCUIT_BREAKER_RATIO = 10e18;

    // Event declarations

    event SwapEnabledSet(bool swapEnabled);
    event GradualWeightUpdateScheduled(
        uint256 startTime,
        uint256 endTime,
        uint256[] startWeights,
        uint256[] endWeights
    );
    event CircuitBreakerRatioSet(address indexed token, uint256 minRatio, uint256 maxRatio);

    constructor(
        IVault vault,
        string memory name,
        string memory symbol,
        IERC20[] memory tokens,
        uint256[] memory normalizedWeights,
        uint256 swapFeePercentage,
        uint256 pauseWindowDuration,
        uint256 bufferPeriodDuration,
        address owner,
        bool swapEnabledOnStart
    )
        BaseWeightedPool(
            vault,
            name,
            symbol,
            tokens,
            new address[](tokens.length), // Pass the zero address: Investment Pools can't have asset managers
            swapFeePercentage,
            pauseWindowDuration,
            bufferPeriodDuration,
            owner
        )
    {
        uint256 totalTokens = tokens.length;
        InputHelpers.ensureInputLengthMatch(totalTokens, normalizedWeights.length);

        _poolState = _poolState.insertUint7(totalTokens, _TOTAL_TOKENS_OFFSET);

        uint256 currentTime = block.timestamp;
        _startGradualWeightChange(currentTime, currentTime, normalizedWeights, normalizedWeights, tokens);

        // If false, the pool will start in the disabled state (prevents front-running the enable swaps transaction)
        _setSwapEnabled(swapEnabledOnStart);
    }

    // External functions

    /**
     * @dev Tells whether swaps are enabled or not for the given pool.
     */
    function getSwapEnabled() public view returns (bool) {
        return _poolState.decodeBool(_SWAP_ENABLED_OFFSET);
    }

    /**
     * @dev Return start time, end time, and endWeights as an array.
     * Current weights should be retrieved via `getNormalizedWeights()`.
     */
    function getGradualWeightUpdateParams()
        external
        view
        returns (
            uint256 startTime,
            uint256 endTime,
            uint256[] memory endWeights
        )
    {
        // Load current pool state from storage
        bytes32 poolState = _poolState;

        startTime = poolState.decodeUint32(_START_TIME_OFFSET);
        endTime = poolState.decodeUint32(_END_TIME_OFFSET);

        (IERC20[] memory tokens, , ) = getVault().getPoolTokens(getPoolId());
        uint256 totalTokens = tokens.length;

        endWeights = new uint256[](totalTokens);

        for (uint256 i = 0; i < totalTokens; i++) {
            endWeights[i] = _tokenState[tokens[i]].decodeUint32(_END_WEIGHT_OFFSET).uncompress32();
        }
    }

    function _getMaxTokens() internal pure virtual override returns (uint256) {
        return _MAX_WEIGHTED_TOKENS;
    }

    function _getTotalTokens() internal view virtual override returns (uint256) {
        return _poolState.decodeUint7(_TOTAL_TOKENS_OFFSET);
    }

    /**
     * @dev Can pause/unpause trading
     */
    function setSwapEnabled(bool swapEnabled) external authenticate whenNotPaused nonReentrant {
        _setSwapEnabled(swapEnabled);
    }

    function _setSwapEnabled(bool swapEnabled) private {
        _poolState = _poolState.insertBool(swapEnabled, _SWAP_ENABLED_OFFSET);

        emit SwapEnabledSet(swapEnabled);
    }

    /**
     * @dev Schedule a gradual weight change, from the current weights to the given endWeights,
     * over startTime to endTime
     */
    function updateWeightsGradually(
        uint256 startTime,
        uint256 endTime,
        uint256[] memory endWeights
    ) external authenticate whenNotPaused nonReentrant {
        InputHelpers.ensureInputLengthMatch(_getTotalTokens(), endWeights.length);

        // If the start time is in the past, "fast forward" to start now
        // This avoids discontinuities in the weight curve. Otherwise, if you set the start/end times with
        // only 10% of the period in the future, the weights would immediately jump 90%
        uint256 currentTime = block.timestamp;
        startTime = Math.max(currentTime, startTime);

        _require(startTime <= endTime, Errors.GRADUAL_UPDATE_TIME_TRAVEL);

        (IERC20[] memory tokens, , ) = getVault().getPoolTokens(getPoolId());

        _startGradualWeightChange(startTime, endTime, _getNormalizedWeights(), endWeights, tokens);
    }

    /**
     * @dev Update the circuit breaker ratios
     */
    function setCircuitBreakerRatio(uint256[] memory minRatios, uint256[] memory maxRatios) external authenticate whenNotPaused nonReentrant {
        InputHelpers.ensureInputLengthMatch(_getTotalTokens(), minRatios.length, maxRatios.length);

        uint256 supply = totalSupply();

        (IERC20[] memory tokens, uint256[] memory balances, ) = getVault().getPoolTokens(getPoolId());
        uint256[] memory normalizedWeights = _getNormalizedWeights();

        for (uint256 i = 0; i < tokens.length; i++) {
            // Can we remove? - if so, pass through 0s? - maybe leave it and document that we can't remove it.
            // Or do you have to set it on every token?
            if (minRatios[i] != 0 || maxRatios[i] != 0) {
                // priceOfTokenInBpt = totalSupply / (token.balance / token.weight)
                _setCircuitBreakerRatio(tokens[i], supply.divUp(balances[i].divDown(normalizedWeights[i])), minRatios[i], maxRatios[i]);
            }
        }
    }

    function _scalingFactor(IERC20 token) internal view virtual override returns (uint256) {
        bytes32 tokenData = _tokenState[token];

        // A valid token can't be zero (must have non-zero weights)
        if (tokenData == 0) {
            _revert(Errors.INVALID_TOKEN);
        }

        return _computeScalingFactor(tokenData);
    }

    function _scalingFactors() internal view virtual override returns (uint256[] memory scalingFactors) {
        (IERC20[] memory tokens, , ) = getVault().getPoolTokens(getPoolId());
        uint256 numTokens = tokens.length;

        scalingFactors = new uint256[](numTokens);

        for (uint256 i = 0; i < numTokens; i++) {
            scalingFactors[i] = _computeScalingFactor(_tokenState[tokens[i]]);
        }
    }

    function _getNormalizedWeight(IERC20 token) internal view override returns (uint256) {
        bytes32 tokenData = _tokenState[token];

        // A valid token can't be zero (must have non-zero weights)
        if (tokenData == 0) {
            _revert(Errors.INVALID_TOKEN);
        }

        uint256 startWeight = tokenData.decodeUint64(_START_WEIGHT_OFFSET).uncompress64();
        uint256 endWeight = tokenData.decodeUint32(_END_WEIGHT_OFFSET).uncompress32();

        uint256 pctProgress = _calculateWeightChangeProgress();

        return _interpolateWeight(startWeight, endWeight, pctProgress);
    }

    function _getNormalizedWeights() internal view override returns (uint256[] memory normalizedWeights) {
        (IERC20[] memory tokens, , ) = getVault().getPoolTokens(getPoolId());
        uint256 numTokens = tokens.length;

        normalizedWeights = new uint256[](numTokens);

        uint256 pctProgress = _calculateWeightChangeProgress();

        for (uint256 i = 0; i < numTokens; i++) {
            bytes32 tokenData = _tokenState[tokens[i]];

            uint256 startWeight = tokenData.decodeUint64(_START_WEIGHT_OFFSET).uncompress64();
            uint256 endWeight = tokenData.decodeUint32(_END_WEIGHT_OFFSET).uncompress32();

            normalizedWeights[i] = _interpolateWeight(startWeight, endWeight, pctProgress);
        }
    }

    function _getNormalizedWeightsAndMaxWeightIndex() internal view override returns (uint256[] memory, uint256) {
        uint256[] memory normalizedWeights = _getNormalizedWeights();

        uint256 maxNormalizedWeight = 0;
        uint256 maxWeightTokenIndex;

        // NOTE: could cache this in the _getNormalizedWeights function and avoid double iteratio,
        // but it's a view function
        for (uint256 i = 0; i < normalizedWeights.length; i++) {
            if (normalizedWeights[i] > maxNormalizedWeight) {
                maxWeightTokenIndex = i;
                maxNormalizedWeight = normalizedWeights[i];
            }
        }

        return (normalizedWeights, maxWeightTokenIndex);
    }

    /**
     * @dev When calling updateWeightsGradually again during an update, reset the start weights to the current weights,
     * if necessary. Time travel elements commented out.
     */
    function _startGradualWeightChange(
        uint256 startTime,
        uint256 endTime,
        uint256[] memory startWeights,
        uint256[] memory endWeights,
        IERC20[] memory tokens
    ) internal virtual {
        uint256 normalizedSum = 0;
        bytes32 tokenState;

        for (uint256 i = 0; i < endWeights.length; i++) {
            uint256 endWeight = endWeights[i];
            _require(endWeight >= _MIN_WEIGHT, Errors.MIN_WEIGHT);

            IERC20 token = tokens[i];

            // Tokens with more than 18 decimals are not supported
            // Scaling calculations must be exact/lossless
            // Store decimal difference instead of actual scaling factor
            _tokenState[token] = tokenState
                .insertUint64(startWeights[i].compress64(), _START_WEIGHT_OFFSET)
                .insertUint32(endWeight.compress32(), _END_WEIGHT_OFFSET)
                .insertUint5(uint256(18).sub(ERC20(address(token)).decimals()), _DECIMAL_DIFF_OFFSET);

            normalizedSum = normalizedSum.add(endWeight);
        }
        // Ensure that the normalized weights sum to ONE
        _require(normalizedSum == FixedPoint.ONE, Errors.NORMALIZED_WEIGHT_INVARIANT);

        _poolState = _poolState.insertUint32(startTime, _START_TIME_OFFSET).insertUint32(endTime, _END_TIME_OFFSET);

        emit GradualWeightUpdateScheduled(startTime, endTime, startWeights, endWeights);
    }

    function _computeScalingFactor(bytes32 tokenState) private pure returns (uint256) {
        uint256 decimalsDifference = tokenState.decodeUint5(_DECIMAL_DIFF_OFFSET);

        return FixedPoint.ONE * 10**decimalsDifference;
    }

    // Swap overrides - revert unless swaps are enabled

    function _onSwapGivenIn(
        SwapRequest memory swapRequest,
        uint256 currentBalanceTokenIn,
        uint256 currentBalanceTokenOut
    ) internal view override returns (uint256 tokenOutAmount) {
        _require(getSwapEnabled(), Errors.SWAPS_DISABLED);

        // Check that the final amount in (= currentBalance + swap amount) doesn't trip the breaker
        // Higher balance = lower BPT price
        // Upper Bound check means BptPrice must be >= startPrice/MaxRatio
        _checkCircuitBreakerUpperBound(
            _tokenState[swapRequest.tokenIn],
            currentBalanceTokenIn.add(swapRequest.amount),
            swapRequest.tokenIn
        );

        // Since amountIn is valid, calculate the amount out (price quote), and check
        // that it doesn't trip that token's breaker
        tokenOutAmount = super._onSwapGivenIn(swapRequest, currentBalanceTokenIn, currentBalanceTokenOut);

       // Lower Bound check means BptPrice must be <= startPrice/MinRatio
        _checkCircuitBreakerLowerBound(
            _tokenState[swapRequest.tokenOut],
            currentBalanceTokenOut.sub(tokenOutAmount),
            swapRequest.tokenOut
        );
    }

    function _onSwapGivenOut(
        SwapRequest memory swapRequest,
        uint256 currentBalanceTokenIn,
        uint256 currentBalanceTokenOut
    ) internal view override returns (uint256 amountIn) {
        _require(getSwapEnabled(), Errors.SWAPS_DISABLED);

        // Check that the final amount in (= currentBalance + swap amount) doesn't trip the breaker
        // Higher balance = lower BPT price
        // Upper Bound check means BptPrice must be >= startPrice/MaxRatio
        _checkCircuitBreakerUpperBound(
            _tokenState[swapRequest.tokenOut],
            currentBalanceTokenOut.add(swapRequest.amount),
            swapRequest.tokenOut
        );

        amountIn = super._onSwapGivenOut(swapRequest, currentBalanceTokenIn, currentBalanceTokenOut);

       // Lower Bound check means BptPrice must be <= startPrice/MinRatio
        _checkCircuitBreakerLowerBound(
            _tokenState[swapRequest.tokenIn],
            currentBalanceTokenIn.sub(amountIn),
            swapRequest.tokenIn
        );
    }

    // If the ratio is 0, there is no breaker in this direction on this token
    function _checkCircuitBreakerUpperBound(bytes32 tokenData, uint256 endingBalance, IERC20 token) private view {
        uint256 maxRatio = _decodeRatio(tokenData.decodeUint8(_MAX_RATIO_OFFSET).uncompress8());

        if (maxRatio != 0) {
            uint256 initialPrice = tokenData.decodeUint112(_INITIAL_BPT_PRICE_OFFSET);
            uint256 lowerBound = initialPrice.divUp(maxRatio);

            // Validate that token price is within bounds
            // Can be front run!
            // Once turned on, all need to have values
            // BPT price can be manipulated - but lower bound protects against most of it
            // can snapshot 
            uint256 finalPrice = totalSupply().divDown(endingBalance.divUp(_getNormalizedWeight(token)));
            _require(finalPrice >= lowerBound, Errors.CIRCUIT_BREAKER_TRIPPED_MAX_RATIO);    
        }
    }

    function _checkCircuitBreakerLowerBound(bytes32 tokenData, uint256 endingBalance, IERC20 token) private view {
        uint256 minRatio = _decodeRatio(tokenData.decodeUint8(_MIN_RATIO_OFFSET).uncompress8());

        // If the ratio is 0, there is no breaker in this direction on this token
        if (minRatio != 0) {
            uint256 initialPrice = tokenData.decodeUint112(_INITIAL_BPT_PRICE_OFFSET);
            uint256 upperBound = initialPrice.divDown(minRatio);

            // Validate that token price is within bounds
            uint256 finalPrice = totalSupply().divUp(endingBalance.divDown(_getNormalizedWeight(token)));
            _require(finalPrice <= upperBound, Errors.CIRCUIT_BREAKER_TRIPPED_MIN_RATIO);     
        }
    }

    /**
     * @dev Extend ownerOnly functions to include the LBP control functions
     */
    function _isOwnerOnlyAction(bytes32 actionId) internal view override returns (bool) {
        return
            (actionId == getActionId(InvestmentPool.setSwapEnabled.selector)) ||
            (actionId == getActionId(InvestmentPool.updateWeightsGradually.selector)) ||
            (actionId == getActionId(InvestmentPool.setCircuitBreakerRatio.selector)) ||
            super._isOwnerOnlyAction(actionId);
    }

    function _onJoinPool(
        bytes32 poolId,
        address sender,
        address recipient,
        uint256[] memory balances,
        uint256 lastChangeBlock,
        uint256 protocolSwapFeePercentage,
        uint256[] memory scalingFactors,
        bytes memory userData
    )
        internal
        override
        returns (
            uint256 bptAmountOut,
            uint256[] memory amountsIn,
            uint256[] memory dueProtocolFeeAmounts
        )
    {
        (bptAmountOut, amountsIn, dueProtocolFeeAmounts) = super._onJoinPool(
            poolId,
            sender,
            recipient,
            balances,
            lastChangeBlock,
            protocolSwapFeePercentage,
            scalingFactors,
            userData
        );

        (IERC20[] memory tokens, , ) = getVault().getPoolTokens(getPoolId());

        for (uint256 i = 0; i < _getTotalTokens(); i++) {
            // Check that the final amount in (= currentBalance + swap amount) doesn't trip the breaker
            // Higher balance = lower BPT price
            // Upper Bound check means BptPrice must be >= startPrice/MaxRatio
            IERC20 token = tokens[i];

            _checkCircuitBreakerUpperBound(
                _tokenState[token],
                balances[i].add(amountsIn[i]),
                token
            );
        }
    }

    function _onExitPool(
        bytes32 poolId,
        address sender,
        address recipient,
        uint256[] memory balances,
        uint256 lastChangeBlock,
        uint256 protocolSwapFeePercentage,
        uint256[] memory scalingFactors,
        bytes memory userData
    )
        internal
        virtual
        override
        returns (
            uint256 bptAmountIn,
            uint256[] memory amountsOut,
            uint256[] memory dueProtocolFeeAmounts
        )
    {
        (bptAmountIn, amountsOut, dueProtocolFeeAmounts) = super._onExitPool(
            poolId,
            sender,
            recipient,
            balances,
            lastChangeBlock,
            protocolSwapFeePercentage,
            scalingFactors,
            userData
        );

        // If exit is non-proportional, it has swaps; check circuit breaker bounds
        if (userData.exitKind() != ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT) {
            (IERC20[] memory tokens, , ) = getVault().getPoolTokens(getPoolId());

            for (uint256 i = 0; i < _getTotalTokens(); i++) {
                // Check that the final amount in (= currentBalance + swap amount) doesn't trip the breaker
                // Higher balance = lower BPT price
                // Upper Bound check means BptPrice must be >= startPrice/MaxRatio
                IERC20 token = tokens[i];

                _checkCircuitBreakerLowerBound(
                    _tokenState[token],
                    balances[i].sub(amountsOut[i]),
                    token
                );
            }
        }
    }

    // Private functions

    /**
     * @dev Returns a fixed-point number representing how far along the current weight change is, where 0 means the
     * change has not yet started, and FixedPoint.ONE means it has fully completed.
     */
    function _calculateWeightChangeProgress() private view returns (uint256) {
        uint256 currentTime = block.timestamp;
        bytes32 poolState = _poolState;

        uint256 startTime = poolState.decodeUint32(_START_TIME_OFFSET);
        uint256 endTime = poolState.decodeUint32(_END_TIME_OFFSET);

        if (currentTime > endTime) {
            return FixedPoint.ONE;
        } else if (currentTime < startTime) {
            return 0;
        }

        uint256 totalSeconds = endTime - startTime;
        uint256 secondsElapsed = currentTime - startTime;

        // In the degenerate case of a zero duration change, consider it completed (and avoid division by zero)
        return totalSeconds == 0 ? FixedPoint.ONE : secondsElapsed.divDown(totalSeconds);
    }

    function _interpolateWeight(
        uint256 startWeight,
        uint256 endWeight,
        uint256 pctProgress
    ) private pure returns (uint256 finalWeight) {
        if (pctProgress == 0 || startWeight == endWeight) return startWeight;
        if (pctProgress >= FixedPoint.ONE) return endWeight;

        if (startWeight > endWeight) {
            uint256 weightDelta = pctProgress.mulDown(startWeight - endWeight);
            return startWeight.sub(weightDelta);
        } else {
            uint256 weightDelta = pctProgress.mulDown(endWeight - startWeight);
            return startWeight.add(weightDelta);
        }
    }

    function _setCircuitBreakerRatio(IERC20 token, uint256 initialPrice, uint256 minRatio, uint256 maxRatio) internal {
        _require(minRatio == 0 || minRatio >= _MIN_CIRCUIT_BREAKER_RATIO, Errors.MIN_CIRCUIT_BREAKER_RATIO);
        _require(maxRatio == 0 || maxRatio <= _MAX_CIRCUIT_BREAKER_RATIO, Errors.MAX_CIRCUIT_BREAKER_RATIO);
        _require(maxRatio >= minRatio, Errors.INVALID_CIRCUIT_BREAKER_RATIOS);
 
        bytes32 tokenData = _tokenState[token];
    
        _tokenState[token] = tokenData
            .insertUint112(initialPrice, _INITIAL_BPT_PRICE_OFFSET)
            .insertUint8(_encodeRatio(minRatio).compress8(), _MIN_RATIO_OFFSET)
            .insertUint8(_encodeRatio(maxRatio).compress8(), _MAX_RATIO_OFFSET);

        emit CircuitBreakerRatioSet(address(token), minRatio, maxRatio);
    }

    // Encoded value = (value - MIN)/range
    // e.g., if range is 0.1 - 10, 1.5 = (1.5 - 0.1)/9.9 = 0.1414
    function _encodeRatio(uint256 ratio) private pure returns (uint256) {
        return (ratio - _MIN_CIRCUIT_BREAKER_RATIO) / (_MAX_CIRCUIT_BREAKER_RATIO - _MIN_CIRCUIT_BREAKER_RATIO);
    }

    // Scale back to a numeric ratio
    // 0.1 + 0.1414 * 9.9 ~ 1.5
    function _decodeRatio(uint256 ratio) private pure returns (uint256) {
        return _MIN_CIRCUIT_BREAKER_RATIO + ratio * (_MAX_CIRCUIT_BREAKER_RATIO - _MIN_CIRCUIT_BREAKER_RATIO);
    }
}
