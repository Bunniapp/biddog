// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {LibMulticaller} from "multicaller/LibMulticaller.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import "./Constants.sol";
import {IAmAmm} from "../interfaces/IAmAmm.sol";

/// @title AmAmm
/// @author zefram.eth
/// @notice Implements the auction mechanism from the am-AMM paper (https://arxiv.org/abs/2403.03367)
abstract contract AmAmm is IAmAmm {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SafeCastLib for *;
    using FixedPointMathLib for *;

    /// -----------------------------------------------------------------------
    /// Constants
    /// -----------------------------------------------------------------------

    uint72 internal constant K = 24; // 24 windows (hours)
    uint256 internal constant EPOCH_SIZE = 1 hours;
    uint256 internal constant MIN_BID_MULTIPLIER = 1.1e18; // 10%

    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    mapping(PoolId id => Bid) internal _topBids;
    mapping(PoolId id => Bid) internal _nextBids;
    mapping(PoolId id => uint72) internal _lastUpdatedEpoch;
    mapping(Currency currency => uint256) internal _totalFees;
    mapping(address manager => mapping(PoolId id => uint256)) internal _refunds;
    mapping(address manager => mapping(Currency currency => uint256)) internal _fees;

    /// -----------------------------------------------------------------------
    /// Bidder actions
    /// -----------------------------------------------------------------------

    /// @inheritdoc IAmAmm
    function bid(PoolId id, address manager, uint24 swapFee, uint128 rent, uint128 deposit) external virtual override {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        address msgSender = LibMulticaller.senderOrSigner();

        if (!_amAmmEnabled(id)) {
            revert AmAmm__NotEnabled();
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // update state machine
        _updateAmAmm(id);

        // ensure bid is valid
        // - manager can't be zero address
        // - bid needs to be greater than top bid and next bid by >10%
        // - deposit needs to cover the rent for K hours
        // - deposit needs to be a multiple of rent
        // - swap fee needs to be <= _maxSwapFee(id)
        if (
            manager == address(0) || rent <= _topBids[id].rent.mulWad(MIN_BID_MULTIPLIER)
                || rent <= _nextBids[id].rent.mulWad(MIN_BID_MULTIPLIER) || deposit < rent * K || deposit % rent != 0
                || swapFee > _maxSwapFee(id)
        ) {
            revert AmAmm__InvalidBid();
        }

        // refund deposit of the previous next bid
        _refunds[_nextBids[id].manager][id] += _nextBids[id].deposit;

        // update next bid
        _nextBids[id] = Bid(manager, _getEpoch(block.timestamp), swapFee, rent, deposit);

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // transfer deposit from msg.sender to this contract
        _pullBidToken(id, msgSender, deposit);
    }

    /// @inheritdoc IAmAmm
    function withdrawFromTopBid(PoolId id, uint128 amount, address recipient) external virtual override {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        address msgSender = LibMulticaller.senderOrSigner();

        if (!_amAmmEnabled(id)) {
            revert AmAmm__NotEnabled();
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // update state machine
        _updateAmAmm(id);

        Bid memory topBid = _topBids[id];

        // only the top bid manager can withdraw from the top bid
        if (msgSender != topBid.manager) {
            revert AmAmm__Unauthorized();
        }

        // ensure amount is a multiple of rent
        if (amount % topBid.rent != 0) {
            revert AmAmm__InvalidDepositAmount();
        }

        // require D_top / R_top >= K
        if ((topBid.deposit - amount) / topBid.rent < K) {
            revert AmAmm__BidLocked();
        }

        // deduct amount from top bid deposit
        _topBids[id].deposit = topBid.deposit - amount;

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // transfer amount to recipient
        _pushBidToken(id, recipient, amount);
    }

    /// @inheritdoc IAmAmm
    function withdrawFromNextBid(PoolId id, uint128 amount, address recipient) external virtual override {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        address msgSender = LibMulticaller.senderOrSigner();

        if (!_amAmmEnabled(id)) {
            revert AmAmm__NotEnabled();
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // update state machine
        _updateAmAmm(id);

        Bid memory nextBid = _nextBids[id];

        // only the next bid manager can withdraw from the next bid
        if (msgSender != nextBid.manager) {
            revert AmAmm__Unauthorized();
        }

        // ensure amount is a multiple of rent
        if (amount % nextBid.rent != 0) {
            revert AmAmm__InvalidDepositAmount();
        }

        // require D_next / R_next >= K
        if ((nextBid.deposit - amount) / nextBid.rent < K) {
            revert AmAmm__BidLocked();
        }

        // deduct amount from next bid deposit
        _nextBids[id].deposit = nextBid.deposit - amount;

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // transfer amount to recipient
        _pushBidToken(id, recipient, amount);
    }

    /// @inheritdoc IAmAmm
    function cancelNextBid(PoolId id, address recipient) external virtual override returns (uint256 refund) {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        address msgSender = LibMulticaller.senderOrSigner();

        if (!_amAmmEnabled(id)) {
            revert AmAmm__NotEnabled();
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // update state machine
        _updateAmAmm(id);

        Bid memory nextBid = _nextBids[id];

        // only the next bid manager can withdraw from the next bid
        if (msgSender != nextBid.manager) {
            revert AmAmm__Unauthorized();
        }

        Bid memory topBid = _topBids[id];

        // require D_top / R_top >= K
        if (topBid.manager != address(0) && topBid.deposit / topBid.rent < K) {
            revert AmAmm__BidLocked();
        }

        // delete next bid from storage
        delete _nextBids[id];

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // transfer nextBid.deposit to recipient
        _pushBidToken(id, recipient, nextBid.deposit);

        return nextBid.deposit;
    }

    /// @inheritdoc IAmAmm
    function claimRefund(PoolId id, address recipient) external virtual override returns (uint256 refund) {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        address msgSender = LibMulticaller.senderOrSigner();

        if (!_amAmmEnabled(id)) {
            revert AmAmm__NotEnabled();
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // update state machine
        _updateAmAmm(id);

        refund = _refunds[msgSender][id];
        if (refund == 0) {
            return 0;
        }
        delete _refunds[msgSender][id];

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // transfer refund to recipient
        _pushBidToken(id, recipient, refund);
    }

    /// @inheritdoc IAmAmm
    function claimFees(Currency currency, address recipient) external virtual override returns (uint256 fees) {
        address msgSender = LibMulticaller.senderOrSigner();

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // update manager fees
        fees = _fees[msgSender][currency];
        if (fees == 0) {
            return 0;
        }
        delete _fees[msgSender][currency];

        // update total fees
        unchecked {
            // safe because _totalFees[currency] is the sum of all managers' fees
            _totalFees[currency] -= fees;
        }

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // transfer fees to recipient
        _transferFeeToken(currency, recipient, fees);
    }

    /// @inheritdoc IAmAmm
    function setBidSwapFee(PoolId id, uint24 swapFee, bool topBid) external virtual override {
        address msgSender = LibMulticaller.senderOrSigner();

        if (!_amAmmEnabled(id)) {
            revert AmAmm__NotEnabled();
        }

        // update state machine
        _updateAmAmm(id);

        Bid storage relevantBid = topBid ? _topBids[id] : _nextBids[id];

        if (msgSender != relevantBid.manager) {
            revert AmAmm__Unauthorized();
        }

        if (swapFee > _maxSwapFee(id)) {
            revert AmAmm__InvalidBid();
        }

        relevantBid.swapFee = swapFee;
    }

    /// -----------------------------------------------------------------------
    /// Getters
    /// -----------------------------------------------------------------------

    /// @inheritdoc IAmAmm
    function getTopBid(PoolId id) external view override returns (Bid memory) {
        return _topBids[id];
    }

    /// @inheritdoc IAmAmm
    function getTopBidWrite(PoolId id) external override returns (Bid memory) {
        _updateAmAmm(id);
        return _topBids[id];
    }

    /// @inheritdoc IAmAmm
    function getNextBid(PoolId id) external view override returns (Bid memory) {
        return _nextBids[id];
    }

    /// @inheritdoc IAmAmm
    function getNextBidWrite(PoolId id) external override returns (Bid memory) {
        _updateAmAmm(id);
        return _nextBids[id];
    }

    /// @inheritdoc IAmAmm
    function getRefund(address manager, PoolId id) external view override returns (uint256) {
        return _refunds[manager][id];
    }

    /// @inheritdoc IAmAmm
    function getRefundWrite(address manager, PoolId id) external override returns (uint256) {
        _updateAmAmm(id);
        return _refunds[manager][id];
    }

    /// @inheritdoc IAmAmm
    function getFees(address manager, Currency currency) external view override returns (uint256) {
        return _fees[manager][currency];
    }

    /// -----------------------------------------------------------------------
    /// Virtual functions
    /// -----------------------------------------------------------------------

    /// @dev Returns whether the am-AMM is enabled for a given pool
    function _amAmmEnabled(PoolId id) internal view virtual returns (bool);

    /// @dev Returns the maximum swap fee for a given pool
    function _maxSwapFee(PoolId id) internal view virtual returns (uint24);

    /// @dev Burns bid tokens from address(this)
    function _burnBidToken(PoolId id, uint256 amount) internal virtual;

    /// @dev Transfers bid tokens from an address that's not address(this) to address(this)
    function _pullBidToken(PoolId id, address from, uint256 amount) internal virtual;

    /// @dev Transfers bid tokens from address(this) to an address that's not address(this)
    function _pushBidToken(PoolId id, address to, uint256 amount) internal virtual;

    /// @dev Transfers accrued fees from address(this)
    function _transferFeeToken(Currency currency, address to, uint256 amount) internal virtual;

    /// @dev Accrues swap fees to the manager
    function _accrueFees(address manager, Currency currency, uint256 amount) internal virtual {
        _fees[manager][currency] += amount;
        _totalFees[currency] += amount;
    }

    /// -----------------------------------------------------------------------
    /// Internal helpers
    /// -----------------------------------------------------------------------

    /// @dev Charges rent and updates the top and next bids for a given pool
    function _updateAmAmm(PoolId id) internal virtual returns (address manager, uint24 swapFee) {
        uint72 currentEpoch = _getEpoch(block.timestamp);

        // early return if the pool has already been updated in this epoch
        if (_lastUpdatedEpoch[id] == currentEpoch) {
            return (_topBids[id].manager, _topBids[id].swapFee);
        }

        Bid memory topBid = _topBids[id];
        Bid memory nextBid = _nextBids[id];
        bool updatedTopBid;
        bool updatedNextBid;
        uint256 rentCharged;

        // run state machine
        {
            bool stepHasUpdatedTopBid;
            bool stepHasUpdatedNextBid;
            uint256 stepRentCharged;
            while (true) {
                (topBid, nextBid, stepHasUpdatedTopBid, stepHasUpdatedNextBid, stepRentCharged) =
                    _stateTransition(currentEpoch, id, topBid, nextBid);

                if (!stepHasUpdatedTopBid && !stepHasUpdatedNextBid) {
                    break;
                }

                updatedTopBid = updatedTopBid || stepHasUpdatedTopBid;
                updatedNextBid = updatedNextBid || stepHasUpdatedNextBid;
                rentCharged += stepRentCharged;
            }
        }

        // update top and next bids
        if (updatedTopBid) {
            _topBids[id] = topBid;
        }
        if (updatedNextBid) {
            _nextBids[id] = nextBid;
        }

        // update last updated epoch
        _lastUpdatedEpoch[id] = currentEpoch;

        // burn rent charged
        if (rentCharged != 0) {
            _burnBidToken(id, rentCharged);
        }

        return (topBid.manager, topBid.swapFee);
    }

    /// @dev Returns the updated top and next bids after a single state transition
    /// State diagram is as follows:
    ///                                          after
    ///                 ┌───────────────────────deposit ───────────────────┐
    ///                 │                       depletes                   │
    ///                 ▼                                                  │
    ///    ┌────────────────────────┐                         ┌────────────────────────┐
    ///    │                        │                         │                        │
    ///    │        State A         │                         │        State B         │
    ///    │      Manager: nil      │            ┌───────────▶│      Manager: r0       │◀─┐
    ///    │       Next: nil        │            │            │       Next: nil        │  │
    ///    │                        │            │            │                        │  │
    ///    └────────────────────────┘            │            └────────────────────────┘  │
    ///                 │                        │                         │              │
    ///                 │                        │                         │              │
    ///                 │                        │                         │              │
    ///                 │                        │                         │           after K
    ///              bid(r)                  after K                    bid(r)        epochs or
    ///                 │                     epochs                       │            after
    ///                 │                        │                         │           deposit
    ///                 │                        │                         │          depletes
    ///                 │                        │                         │              │
    ///                 │                        │                         │              │
    ///                 │                        │                         │              │
    ///                 ▼                        │                         ▼              │
    ///    ┌────────────────────────┐            │            ┌────────────────────────┐  │
    ///    │                        │            │            │                        │  │
    ///    │        State C         │            │            │        State D         │  │
    /// ┌─▶│      Manager: nil      │────────────┘         ┌─▶│      Manager: r0       │──┘
    /// │  │        Next: r         │                      │  │        Next: r         │
    /// │  │                        │                      │  │                        │
    /// │  └────────────────────────┘                      │  └────────────────────────┘
    /// │               │                                  │               │
    /// │               │                                  │               │
    /// └─────bid(r)────┘                                  └─────bid(r)────┘
    function _stateTransition(uint72 currentEpoch, PoolId id, Bid memory topBid, Bid memory nextBid)
        internal
        virtual
        returns (Bid memory, Bid memory, bool updatedTopBid, bool updatedNextBid, uint256 rentCharged)
    {
        if (nextBid.manager == address(0)) {
            if (topBid.manager != address(0)) {
                // State B
                // charge rent from top bid
                uint72 epochsPassed;
                unchecked {
                    // unchecked so that if epoch ever overflows, we simply wrap around
                    epochsPassed = currentEpoch - topBid.epoch;
                }
                uint256 rentOwed = epochsPassed * topBid.rent;
                if (rentOwed >= topBid.deposit) {
                    // State B -> State A
                    // the top bid's deposit has been depleted
                    rentCharged = topBid.deposit;

                    topBid = Bid(address(0), 0, 0, 0, 0);

                    updatedTopBid = true;
                } else if (rentOwed != 0) {
                    // State B
                    // charge rent from top bid
                    rentCharged = rentOwed;

                    topBid.deposit -= rentOwed.toUint128();
                    topBid.epoch = uint72(currentEpoch);

                    updatedTopBid = true;
                }
            }
        } else {
            if (topBid.manager == address(0)) {
                // State C
                // check if K epochs have passed since the next bid was submitted
                // if so, promote next bid to top bid
                uint72 nextBidStartEpoch;
                unchecked {
                    // unchecked so that if epoch ever overflows, we simply wrap around
                    nextBidStartEpoch = nextBid.epoch + K;
                }
                if (currentEpoch >= nextBidStartEpoch) {
                    // State C -> State B
                    // promote next bid to top bid
                    topBid = nextBid;
                    topBid.epoch = nextBidStartEpoch;
                    nextBid = Bid(address(0), 0, 0, 0, 0);

                    updatedTopBid = true;
                    updatedNextBid = true;
                }
            } else {
                // State D
                // we charge rent from the top bid only until K epochs after the next bid was submitted
                uint72 epochsPassed;
                unchecked {
                    // unchecked so that if epoch ever overflows, we simply wrap around
                    epochsPassed =
                        uint72(FixedPointMathLib.min(currentEpoch - topBid.epoch, nextBid.epoch + K - topBid.epoch));
                }
                uint256 rentOwed = epochsPassed * topBid.rent;
                if (rentOwed >= topBid.deposit) {
                    // State D -> State B
                    // top bid has insufficient deposit
                    // next bid becomes active after top bid depletes its deposit
                    rentCharged = topBid.deposit;

                    uint72 nextBidStartEpoch;
                    unchecked {
                        // unchecked so that if epoch ever overflows, we simply wrap around
                        nextBidStartEpoch = uint72(topBid.deposit / topBid.rent) + topBid.epoch;
                    }
                    topBid = nextBid;
                    topBid.epoch = nextBidStartEpoch;
                    nextBid = Bid(address(0), 0, 0, 0, 0);

                    updatedTopBid = true;
                    updatedNextBid = true;
                } else {
                    // State D
                    // top bid has sufficient deposit
                    // charge rent from top bid
                    if (rentOwed != 0) {
                        rentCharged = rentOwed;

                        topBid.deposit -= rentOwed.toUint128();
                        topBid.epoch = currentEpoch;

                        updatedTopBid = true;
                    }

                    // check if K epochs have passed since the next bid was submitted
                    // if so, promote next bid to top bid
                    uint72 nextBidStartEpoch;
                    unchecked {
                        // unchecked so that if epoch ever overflows, we simply wrap around
                        nextBidStartEpoch = nextBid.epoch + K;
                    }
                    if (currentEpoch >= nextBidStartEpoch) {
                        // State D -> State B
                        // refund remaining deposit to top bid manager
                        _refunds[topBid.manager][id] += topBid.deposit;

                        // promote next bid to top bid
                        topBid = nextBid;
                        topBid.epoch = nextBidStartEpoch;
                        nextBid = Bid(address(0), 0, 0, 0, 0);

                        updatedTopBid = true;
                        updatedNextBid = true;
                    }
                }
            }
        }

        return (topBid, nextBid, updatedTopBid, updatedNextBid, rentCharged);
    }

    function _getEpoch(uint256 timestamp) internal pure returns (uint72) {
        return uint72(timestamp / EPOCH_SIZE);
    }
}
