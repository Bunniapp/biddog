// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import "./ERC20Mock.sol";
import "../../src/AmAmm.sol";

contract AmAmmMock is AmAmm {
    using CurrencyLibrary for Currency;

    ERC20Mock public immutable bidToken;
    ERC20Mock public immutable feeToken0;
    ERC20Mock public immutable feeToken1;

    mapping(PoolId id => bool) public enabled;
    mapping(PoolId id => uint24) public maxSwapFee;

    constructor(ERC20Mock _bidToken, ERC20Mock _feeToken0, ERC20Mock _feeToken1) {
        bidToken = _bidToken;
        feeToken0 = _feeToken0;
        feeToken1 = _feeToken1;
    }

    function setEnabled(PoolId id, bool value) external {
        enabled[id] = value;
    }

    function setMaxSwapFee(PoolId id, uint24 value) external {
        maxSwapFee[id] = value;
    }

    function giveFeeToken0(PoolId id, uint256 amount) external {
        _updateAmAmm(id);
        address manager = _topBids[id].manager;
        feeToken0.mint(address(this), amount);
        _accrueFees(manager, Currency.wrap(address(feeToken0)), amount);
    }

    function giveFeeToken1(PoolId id, uint256 amount) external {
        _updateAmAmm(id);
        address manager = _topBids[id].manager;
        feeToken1.mint(address(this), amount);
        _accrueFees(manager, Currency.wrap(address(feeToken1)), amount);
    }

    /// @dev Returns whether the am-AMM is enabled for a given pool
    function _amAmmEnabled(PoolId id) internal view override returns (bool) {
        return enabled[id];
    }

    /// @dev Validates a bid payload
    function _payloadIsValid(PoolId id, bytes7 payload) internal view override returns (bool) {
        // first 3 bytes of payload are the swap fee
        return uint24(bytes3(payload)) <= maxSwapFee[id];
    }

    /// @dev Burns bid tokens from address(this)
    function _burnBidToken(PoolId, uint256 amount) internal override {
        bidToken.burn(amount);
    }

    /// @dev Transfers bid tokens from an address that's not address(this) to address(this)
    function _pullBidToken(PoolId, address from, uint256 amount) internal override {
        bidToken.transferFrom(from, address(this), amount);
    }

    /// @dev Transfers bid tokens from address(this) to an address that's not address(this)
    function _pushBidToken(PoolId, address to, uint256 amount) internal override {
        bidToken.transfer(to, amount);
    }

    /// @dev Transfers accrued fees from address(this)
    function _transferFeeToken(Currency currency, address to, uint256 amount) internal override {
        currency.transfer(to, amount);
    }
}
