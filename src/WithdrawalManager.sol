// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.7;

import { ERC20Helper } from "../lib/erc20-helper/src/ERC20Helper.sol";

import { ICashManagerLike, IPoolV2Like } from "./interfaces/Interfaces.sol";
import { IWithdrawalManager }            from "./interfaces/IWithdrawalManager.sol";

/// @title Manages withdrawal requests of a liquidity pool.
contract WithdrawalManager is IWithdrawalManager {

    struct WithdrawalRequest {
        uint256 lockedShares;      // Amount of shares that have been locked by an account.
        uint256 withdrawalPeriod;  // Index of the pending withdrawal period.
    }

    struct WithdrawalPeriodState {
        uint256 totalShares;         // Total amount of shares that have been locked into this withdrawal period.
                                     // This value does not change after shares are redeemed for funds.
        uint256 pendingWithdrawals;  // Number of accounts that have yet to withdraw from this withdrawal period. Used to collect dust on the last withdrawal.
        uint256 availableFunds;      // Current amount of funds available for withdrawal. Decreases after an account performs a withdrawal.
        uint256 leftoverShares;      // Current amount of shares available for unlocking. Decreases after an account unlocks them.
        bool    isProcessed;         // Defines if the shares belonging to this withdrawal period have already been processed.
    }

    // Contract dependencies.
    address public override immutable pool;        // Instance of a v2 pool.
    address public override immutable fundsAsset;  // Type of liquidity asset.

    // TODO: Allow updates of period / cooldown.
    uint256 public override immutable periodStart;      // Beginning of the first withdrawal period.
    uint256 public override immutable periodDuration;   // Duration of each withdrawal period.
    uint256 public override immutable periodFrequency;  // How frequently a withdrawal period occurs.
    uint256 public override immutable periodCooldown;   // Amount of time before shares become elligible for withdrawal. TODO: Remove in a separate PR.
    
    mapping(address => WithdrawalRequest) internal _requests;

    // The mapping key is the index of the withdrawal period (starting from 0).
    // TODO: Replace period keys with timestamp keys.
    mapping(uint256 => WithdrawalPeriodState) internal _periodStates;

    constructor(address pool_, address asset_, uint256 periodStart_, uint256 periodDuration_, uint256 periodFrequency_, uint256 cooldownMultiplier_) {
        // TODO: Add other needed require checks.
        require(periodDuration_ <= periodFrequency_, "WM:C:OUT_OF_BOUNDS");
        require(cooldownMultiplier_ != 0,            "WM:C:COOLDOWN_ZERO");

        pool       = pool_;
        fundsAsset = asset_;
        
        periodStart     = periodStart_;
        periodDuration  = periodDuration_;
        periodFrequency = periodFrequency_;
        periodCooldown  = periodFrequency_ * cooldownMultiplier_;
    }

    /**************************/
    /*** External Functions ***/
    /**************************/

    // TODO: Add permissioning and only allow the pool to call external functions. Add `account_` parameter and perform operations on behalf of the account.
    // TODO: Consider renaming lockShares/unlockShares to depositShares/withdrawShares.

    function lockShares(uint256 sharesToLock_) external override returns (uint256 totalShares_) {
        // Transfer the requested amount of shares from the account.
        totalShares_ = _lockShares(msg.sender, sharesToLock_);

        // Get the current and next available withdrawal period.
        ( uint256 currentPeriod, uint256 nextPeriod ) = _getWithdrawalPeriods(msg.sender);

        // Update the request and all affected period states.
        _updateRequest(msg.sender, totalShares_, nextPeriod);
        _updatePeriodState(totalShares_ - sharesToLock_, totalShares_, currentPeriod, nextPeriod);
    }

    // TODO: Check if ACL should be used here.
    function processPeriod() external override {
        // Check if the current period has already been processed.
        uint256 period = _getPeriod(block.timestamp);
        require(!_periodStates[period].isProcessed, "WM:PP:DOUBLE_PROCESS");

        ( , uint256 periodEnd ) = _getWithdrawalPeriodBounds(period);
        _processPeriod(period, periodEnd);
    }

    function redeemPosition(uint256 sharesToReclaim_) external override returns (uint256 withdrawnFunds_, uint256 redeemedShares_, uint256 reclaimedShares_) {
        // Check if a withdrawal request was made.
        uint256 personalShares = _requests[msg.sender].lockedShares;
        require(personalShares != 0, "WM:RP:NO_REQUEST");

        // Get the current and next available withdrawal period.
        ( uint256 currentPeriod, uint256 nextPeriod ) = _getWithdrawalPeriods(msg.sender);

        // Get the start and end of the current withdrawal period.
        ( uint256 periodStart_, uint256 periodEnd ) = _getWithdrawalPeriodBounds(currentPeriod);

        require(block.timestamp >= periodStart_, "WM:RP:EARLY_WITHDRAW");

        // If the period has not been processed yet, do so before the withdrawal.
        if (!_periodStates[currentPeriod].isProcessed) {
            _processPeriod(currentPeriod, periodEnd);
        }

        ( withdrawnFunds_, redeemedShares_, reclaimedShares_ ) = _withdrawAndUnlock(msg.sender, sharesToReclaim_, personalShares, currentPeriod);

        // Update the request and the state of all affected withdrawal periods.
        uint256 remainingShares = personalShares - redeemedShares_ - reclaimedShares_;
        _updateRequest(msg.sender, remainingShares, nextPeriod);
        _updatePeriodState(personalShares, remainingShares, currentPeriod, nextPeriod);
    }

    function unlockShares(uint256 sharesToReclaim_) external override returns (uint256 remainingShares_) {
        // Transfer the requested amount of shares to the account.
        remainingShares_ = _unlockShares(msg.sender, sharesToReclaim_);

        // Get the current and next available withdrawal period.
        ( uint256 currentPeriod, uint256 nextPeriod ) = _getWithdrawalPeriods(msg.sender);

        // Update the request and all affected period states.
        _updateRequest(msg.sender, remainingShares_, nextPeriod);
        _updatePeriodState(remainingShares_ + sharesToReclaim_, remainingShares_, currentPeriod, nextPeriod);
    }

    /**************************/
    /*** Internal Functions ***/
    /**************************/

    function _lockShares(address account_, uint256 sharesToLock_) internal returns (uint256 totalShares_) {
        require(sharesToLock_ != 0, "WM:LS:ZERO_AMOUNT");

        // If a withdrawal is due no shares can be locked.
        uint256 previousShares = _requests[account_].lockedShares;
        require(previousShares == 0 || _isWithinCooldown(account_), "WM:LS:WITHDRAW_DUE");

        // Transfer the shares into the withdrawal manager.
        require(ERC20Helper.transferFrom(pool, account_, address(this), sharesToLock_), "WM:LS:TRANSFER_FAIL");

        // Calculate the total amount of shares.
        totalShares_ = previousShares + sharesToLock_;

        emit SharesLocked(account_, sharesToLock_);
    }

    function _movePeriodShares(uint256 period_, uint256 nextPeriod_, uint256 currentShares_, uint256 nextShares_) internal {
        // If the account already has locked shares, remove them from the current period.
        if (currentShares_ != 0) {
            _periodStates[period_].totalShares        -= currentShares_;
            _periodStates[period_].pendingWithdrawals -= 1;
        }

        // Add shares into the next period if necessary.
        if (nextShares_ != 0) {
            _periodStates[nextPeriod_].totalShares        += nextShares_;
            _periodStates[nextPeriod_].pendingWithdrawals += 1;
        }
    }

    function _processPeriod(uint256 period_, uint256 periodEnd) internal {
        WithdrawalPeriodState storage periodState = _periodStates[period_];

        // If the withdrawal period elapsed, perform no redemption of shares.
        if (block.timestamp >= periodEnd) {
            periodState.leftoverShares = periodState.totalShares;
            periodState.isProcessed = true;
            return;
        }

        // Calculate maximum amount of shares that can be redeemed.
        IPoolV2Like poolV2 = IPoolV2Like(pool);

        uint256 totalFunds       = ICashManagerLike(poolV2.cashManager()).unlockedBalance();  // Total amount of currently available funds.
        uint256 totalShares_     = poolV2.previewWithdraw(totalFunds);
        uint256 periodShares     = periodState.totalShares;
        uint256 redeemableShares = totalShares_ > periodShares ? periodShares : totalShares_;

        // Calculate amount of available funds and leftover shares.
        uint256 availableFunds_ = redeemableShares > 0 ? poolV2.redeem(redeemableShares) : 0;
        uint256 leftoverShares_ = periodShares - redeemableShares;

        // Update the withdrawal period state.
        periodState.availableFunds = availableFunds_;
        periodState.leftoverShares = leftoverShares_;
        periodState.isProcessed    = true;

        emit PeriodProcessed(period_, availableFunds_, leftoverShares_);
    }

    function _unlockShares(address account_, uint256 sharesToReclaim_) internal returns (uint256 remainingShares_) {
        require(sharesToReclaim_ != 0, "WM:US:ZERO_AMOUNT");

        // If a withdrawal is due no shares can be unlocked.
        require(_isWithinCooldown(account_), "WM:US:WITHDRAW_DUE");

        // Transfer shares from the withdrawal manager to the account.
        require(ERC20Helper.transfer(pool, account_, sharesToReclaim_), "WM:US:TRANSFER_FAIL");

        // Calculate the amount of remaining shares.
        remainingShares_ = _requests[account_].lockedShares - sharesToReclaim_;

        emit SharesUnlocked(account_, sharesToReclaim_);
    }

    // TODO: Investigate using int256 for updating the period state more easily.
    function _updatePeriodShares(uint256 period_, uint256 currentShares_, uint256 nextShares_) internal {
        // If additional shares were locked, increase the amount of total shares locked in the period.
        if (nextShares_ > currentShares_) {
            _periodStates[period_].totalShares += nextShares_ - currentShares_;
        }
        // If shares were unlocked, decrease the amount of total shares locked in the period.
        else {
            _periodStates[period_].totalShares -= currentShares_ - nextShares_;
        }

        // If the account has no remaining shares, decrease the number of withdrawal requests.
        if (nextShares_ == 0) {
            _periodStates[period_].pendingWithdrawals -= 1;
        }
    }

    function _updatePeriodState(uint256 currentShares_, uint256 nextShares_, uint256 currentPeriod_, uint256 nextPeriod_) internal {
        // If shares do not need to be moved across withdrawal periods, just update the amount of shares.
        if (currentPeriod_ == nextPeriod_) {
            _updatePeriodShares(nextPeriod_, currentShares_, nextShares_);
        }
        // If the next period is different, move all the shares from the current period to the new one.
        else {
            _movePeriodShares(currentPeriod_, nextPeriod_, currentShares_, nextShares_);
        }
    }

    function _updateRequest(address account_, uint256 shares_, uint256 period_) internal {
        // If any shares are remaining, perform the update.
        if (shares_ != 0) {
            _requests[account_] = WithdrawalRequest({ lockedShares: shares_, withdrawalPeriod: period_ });
            emit WithdrawalPending(account_, period_);
        }
        // Otherwise, clean up the request.
        else {
            delete _requests[account_];
            emit WithdrawalCancelled(account_);
        }
    }

    function _withdrawAndUnlock(
        address account_,
        uint256 sharesToReclaim_,
        uint256 personalShares_,
        uint256 period_
    )
        internal returns (uint256 withdrawnFunds_, uint256 redeemedShares_, uint256 reclaimedShares_)
    {
        // Cache variables.
        WithdrawalPeriodState storage periodState = _periodStates[period_];
        uint256 activeShares    = periodState.totalShares;
        uint256 availableFunds_ = periodState.availableFunds;
        uint256 leftoverShares_ = periodState.leftoverShares;
        uint256 accountCount    = periodState.pendingWithdrawals;

        // [personalShares / activeShares] is the percentage of the funds / shares in the withdrawal period that the account is entitled to claim.
        // Multiplying this amount by the amount of leftover shares and available funds calculates his "fair share".
        withdrawnFunds_           = accountCount > 1 ? availableFunds_ * personalShares_ / activeShares : availableFunds_;
        uint256 reclaimableShares = accountCount > 1 ? leftoverShares_ * personalShares_ / activeShares : leftoverShares_;

        // Remove the entitled funds and shares from the withdrawal period.
        periodState.availableFunds -= withdrawnFunds_;
        periodState.leftoverShares -= reclaimableShares;

        // Calculate how many shares have been redeemed, and how many shares will be reclaimed.
        redeemedShares_  = personalShares_ - reclaimableShares;
        reclaimedShares_ = sharesToReclaim_ < reclaimableShares ? sharesToReclaim_ : reclaimableShares;  // TODO: Revert if `sharesToReclaim_` is too large?

        // Transfer the funds to the account.
        if (withdrawnFunds_ != 0) {
            require(ERC20Helper.transfer(fundsAsset, account_, withdrawnFunds_), "WM:WAU:TRANSFER_FAIL");
            emit FundsWithdrawn(account_, withdrawnFunds_);
        }

        // Transfer the shares to the account.
        if (reclaimedShares_ != 0) {
            require(ERC20Helper.transfer(pool, account_, reclaimedShares_), "WM:WAU:TRANSFER_FAIL");
            emit SharesUnlocked(account_, reclaimedShares_);
        }
    }

    /*************************/
    /*** Utility Functions ***/
    /*************************/

    // TODO: Use timestamps instead of periods for measuring time.

    function _getPeriod(uint256 time_) internal view returns (uint256) {
        if (time_ <= periodStart) return 0;
        return (time_ - periodStart) / periodFrequency;
    }

    function _getWithdrawalPeriodBounds(uint256 period_) internal view returns (uint256 start_, uint256 end_) {
        start_ = periodStart + period_ * periodFrequency;
        end_   = start_ + periodDuration;
    }

    function _getWithdrawalPeriods(address account_) internal view returns (uint256 currentPeriod_, uint256 nextPeriod_) {
        // Fetch the current withdrawal period for the account, and calculate the next available one.
        currentPeriod_ = _requests[account_].withdrawalPeriod;
        nextPeriod_    = _getPeriod(block.timestamp + periodCooldown);
    }

    function _isWithinCooldown(address account_) internal view returns (bool) {
        return _getPeriod(block.timestamp) < _requests[account_].withdrawalPeriod;
    }

    /**********************/
    /*** View Functions ***/
    /**********************/

    // TODO: Check if all these view functions are needed, or can return structs directly.
    // TODO: Discuss what naming convention to use for fixing duplicate names of local variabes and function names.

    function lockedShares(address account_) external override view returns (uint256 lockedShares_) {
        lockedShares_ = _requests[account_].lockedShares;
    }

    function withdrawalPeriod(address account_) external override view returns (uint256 withdrawalPeriod_) {
        withdrawalPeriod_ = _requests[account_].withdrawalPeriod;
    }

    function totalShares(uint256 period_) external override view returns (uint256 totalShares_) {
        totalShares_ = _periodStates[period_].totalShares;
    }

    function pendingWithdrawals(uint256 period_) external override view returns (uint256 pendingWithdrawals_) {
        pendingWithdrawals_ = _periodStates[period_].pendingWithdrawals;
    }

    function availableFunds(uint256 period_) external override view returns (uint256 availableFunds_) {
        availableFunds_ = _periodStates[period_].availableFunds;
    }

    function leftoverShares(uint256 period_) external override view returns (uint256 leftoverShares_) {
        leftoverShares_ = _periodStates[period_].leftoverShares;
    }

    function isProcessed(uint256 period_) external override view returns (bool isProcessed_) {
        isProcessed_ = _periodStates[period_].isProcessed;
    }
    
}

// TODO: Reduce error message lengths / use custom errors.
// TODO: Optimize storage use, investigate struct assignment.
// TODO: Check gas usage and contract size.