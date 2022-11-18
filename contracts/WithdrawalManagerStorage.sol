// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import { IWithdrawalManagerEvents }  from "./interfaces/IWithdrawalManagerEvents.sol";
import { IWithdrawalManagerStorage } from "./interfaces/IWithdrawalManagerStorage.sol";

abstract contract WithdrawalManagerStorage is IWithdrawalManagerStorage, IWithdrawalManagerEvents {

    address public override pool;
    address public override poolManager;

    uint256 public override latestConfigId;

    mapping(address => uint256) public override exitCycleId;
    mapping(address => uint256) public override lockedShares;

    mapping(uint256 => uint256) public override totalCycleShares;

    mapping(uint256 => CycleConfig) public override cycleConfigs;

}
