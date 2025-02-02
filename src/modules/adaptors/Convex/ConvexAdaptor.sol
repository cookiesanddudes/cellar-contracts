// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.16;

import { BaseAdaptor, ERC20, SafeERC20, Cellar, PriceRouter, Registry, Math } from "src/modules/adaptors/BaseAdaptor.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IBooster } from "src/interfaces/external/IBooster.sol";
import { IRewardPool } from "src/interfaces/external/IRewardPool.sol";
import { ICurvePool } from "src/interfaces/external/ICurvePool.sol";

/**
 * @title Convex Adaptor
 * @notice Allows Cellars to interact with Convex Positions.
 * @author cookiesanddudes, federava
 */
contract ConvexAdaptor is BaseAdaptor {
    using SafeERC20 for ERC20;
    using Math for uint256;
    using SafeCast for uint256;
    using Address for address;

    //==================== Adaptor Data Specification ====================
    // adaptorData = abi.encode(uint256 pid, ERC20 lpToken, ICurvePool pool)
    // Where:
    // - pid is the pool id of the convex pool
    // - lpToken is the lp token concerned by the pool
    // - ICurvePool is the curve pool where the lp token was minted
    //====================================================================

    //============================================ Global Functions ===========================================
    /**
     * @dev Identifier unique to this adaptor for a shared registry.
     * Normally the identifier would just be the address of this contract, but this
     * Identifier is needed during Cellar Delegate Call Operations, so getting the address
     * of the adaptor is more difficult.
     */
    function identifier() public pure override returns (bytes32) {
        return keccak256(abi.encode("Convex Adaptor V 0.0"));
    }

    /**
     * @notice The Booster contract on Ethereum Mainnet where all deposits happen in Convex
     */
    function booster() internal pure returns (IBooster) {
        return IBooster(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
    }

    //============================================ Implement Base Functions ===========================================

    /**
     * @notice User deposits are NOT allowed into this position.
     */
    function deposit(
        uint256,
        bytes memory,
        bytes memory
    ) public pure override {
        revert BaseAdaptor__UserDepositsNotAllowed();
    }

    /**
     * @notice User withdraws are NOT allowed from this position.
     */
    function withdraw(
        uint256,
        address,
        bytes memory,
        bytes memory
    ) public pure override {
        revert BaseAdaptor__UserWithdrawsNotAllowed();
    }

    /**
     * @notice User withdraws are not allowed so this position must return 0 for withdrawableFrom.
     */
    function withdrawableFrom(bytes memory, bytes memory) public pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Calculates this positions LP tokens underlying worth in terms of `token0`.
     * @dev Takes into account Cellar LP balance and also staked LP balance
     * @dev The unit is the token0 of the curve pool where the LP was minted. See `assetOf()`
     */
    function balanceOf(bytes memory adaptorData) public view override returns (uint256) {
        (uint256 pid, ERC20 lpToken, ICurvePool pool) = abi.decode(adaptorData, (uint256, ERC20, ICurvePool));

        // get reward pool where the LP are staked
        (, , , address rewardPool, , ) = (booster()).poolInfo(pid);
        uint256 stakedLpBalance = IRewardPool(rewardPool).balanceOf(msg.sender);

        // get amount of LP owned
        uint256 lpBalance = lpToken.balanceOf(msg.sender);

        // calculate lp owned value
        uint256 lpValue;
        if (lpBalance != 0) {
            lpValue = pool.calc_withdraw_one_coin(lpBalance, 0);
        }

        // calculate stakedLp Value
        if (stakedLpBalance == 0) return lpValue;
        uint256 stakedValue = pool.calc_withdraw_one_coin(stakedLpBalance, 0);

        return stakedValue + lpValue;
    }

    /**
     * @notice Returns `coins(0)`
     */
    function assetOf(bytes memory adaptorData) public view override returns (ERC20) {
        (, , ICurvePool pool) = abi.decode(adaptorData, (uint256, ERC20, ICurvePool));
        return ERC20(pool.coins(0));
    }

    //============================================ Strategist Functions ===========================================

    /**
     @notice Attempted to deposit into convex but failed
     */
    error ConvexAdaptor_DepositFailed();

    /**
     * @notice Allows strategist to open a Convex position.
     * @param pid convex pool id
     * @param amount of LP to stake
     * @param lpToken the corresponding LP token
     */
    function openPosition(
        uint256 pid,
        uint256 amount,
        ERC20 lpToken
    ) public {
        _addToPosition(pid, amount, lpToken);
    }

    /**
     * @notice Allows strategist to add liquidity to a Convex position.
     * @param pid convex pool id
     * @param amount of LP to stake
     * @param lpToken the corresponding LP token
     */
    function addToPosition(
        uint256 pid,
        uint256 amount,
        ERC20 lpToken
    ) public {
        _addToPosition(pid, amount, lpToken);
    }

    function _addToPosition(
        uint256 pid,
        uint256 amount,
        ERC20 lpToken
    ) internal {
        lpToken.safeApprove(address(booster()), amount);

        // always assume we are staking
        if (!(booster()).deposit(pid, amount, true)) {
            revert ConvexAdaptor_DepositFailed();
        }
    }

    /**
     * @notice Strategist attempted to remove all of a positions liquidity using `takeFromPosition`,
     *         but they need to use `closePosition`.
     */
    error ConvexAdaptor__CallClosePosition();

    /**
     * @notice Allows strategist to remove liquidity from a position
     * @param pid convex pool id
     * @param amount of LP to stake
     * @param claim true if rewards should be claimed when withdrawing
     */
    function takeFromPosition(
        uint256 pid,
        uint256 amount,
        bool claim
    ) public {
        (, , , address rewardPool, , ) = (booster()).poolInfo(pid);

        if (IRewardPool(rewardPool).balanceOf(msg.sender) == amount) revert ConvexAdaptor__CallClosePosition();

        IRewardPool(rewardPool).withdrawAndUnwrap(amount, claim);
    }

    /**
     * @notice Allows strategist to close a position
     * @param pid convex pool id
     * @param claim true if rewards should be claimed when withdrawing
     */
    function closePosition(uint256 pid, bool claim) public {
        (, , , address rewardPool, , ) = (booster()).poolInfo(pid);

        IRewardPool(rewardPool).withdrawAllAndUnwrap(claim);
    }

    /**
     * @notice Attempted to take from convex position but failed
     */
    error ConvexAdaptor_CouldNotClaimRewards();

    /**
     * @notice Allows strategist to claim rewards and extras from convex
     * @param pid convex pool id
     * TODO: distribute these rewards to timelockERC20 adaptor in feat/timelockERC20 branch (out of scope for the hackathon)
     */
    function claimRewards(uint256 pid) public {
        (, , , address rewardPool, , ) = (booster()).poolInfo(pid);

        if (!IRewardPool(rewardPool).getReward()) {
            revert ConvexAdaptor_CouldNotClaimRewards();
        }
    }
}
