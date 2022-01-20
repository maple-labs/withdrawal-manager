// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.7;

import { ERC20 }       from "../lib/erc20/src/ERC20.sol";
import { ERC20Helper } from "../lib/erc20-helper/src/ERC20Helper.sol";

import { ICashManagerLike, IPrincipalManagerLike } from "./interfaces/Interfaces.sol";

import { CashManager }      from "./CashManager.sol";
import { PrincipalManager } from "./PrincipalManager.sol";

contract PoolV2 is ERC20 {

    address immutable fundsAsset;

    uint256 immutable BASE_UNIT;

    address public poolDelegate;

    address public cashManager;
    address public principalManager;

    uint256 public principalOut;

    constructor(address fundsAsset_, address poolDelegate_) ERC20("Maple Pool", "MPL-LP", ERC20(fundsAsset_).decimals()) {
        fundsAsset   = fundsAsset_;
        poolDelegate = poolDelegate_;

        BASE_UNIT = 10 ** ERC20(fundsAsset_).decimals();  // NOTE: Should the LP tokens always be 18 decimals, or should they match the fundsAsset

        cashManager      = address(new CashManager());
        principalManager = address(new PrincipalManager());
    }

    /********************/
    /*** LP Functions ***/
    /********************/

    function deposit(uint256 amount) external {
        require(amount != 0, "P:D:ZERO_AMT");
        _mint(msg.sender, amount * BASE_UNIT / exchangeRate());
        ICashManagerLike(cashManager).collectPrincipal(fundsAsset, msg.sender, amount);
        ICashManagerLike(cashManager).deployFunds();
    }

    function withdraw(uint256 fundsAssetAmount) external {
        require(fundsAssetAmount != 0, "P:D:ZERO_AMT");
        _burn(msg.sender, fundsAssetAmount * BASE_UNIT / exchangeRate());
        ICashManagerLike(cashManager).moveFunds(fundsAsset, msg.sender, fundsAssetAmount);
    }

    function redeem(uint256 poolTokenAmount) external {
        require(poolTokenAmount != 0, "P:D:ZERO_AMT");
        uint256 fundsAssetAmount = poolTokenAmount * exchangeRate() / BASE_UNIT;
        _burn(msg.sender, poolTokenAmount);
        ICashManagerLike(cashManager).moveFunds(fundsAsset, msg.sender, fundsAssetAmount);
    }

    /**************************************/
    /*** Liquidity Management Functions ***/
    /**************************************/

    function deployFunds(address recipient, uint256 amount) external {
        require(msg.sender == poolDelegate, "P:DF:NOT_PD");
        principalOut += amount;
        ICashManagerLike(cashManager).moveFunds(fundsAsset, recipient, amount);
    }

    function claimPrincipal() public {
        uint256 principalAmount = ERC20(fundsAsset).balanceOf(principalManager);
        principalOut -= principalAmount;
        IPrincipalManagerLike(principalManager).registerPrincipal(fundsAsset, cashManager, principalAmount);
    }

    /**********************/
    /*** View Functions ***/
    /**********************/

    function exchangeRate() public view returns (uint256) {
        uint256 poolTokenSupply = totalSupply;
        if (poolTokenSupply == 0) return BASE_UNIT;
        return totalHoldings() * BASE_UNIT / poolTokenSupply;
    }

    function totalHoldings() public view returns (uint256) {
        return principalOut + ICashManagerLike(cashManager).unlockedBalance();
    }

    function balanceOfUnderlying(address account) external view returns (uint256) {
        return balanceOf[account] * exchangeRate() / BASE_UNIT;
    }

}