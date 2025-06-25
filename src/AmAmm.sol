// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {LibMulticaller} from "multicaller/LibMulticaller.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IAmAmm} from "./interfaces/IAmAmm.sol";
import {BlockNumberLib} from "./libraries/BlockNumberLib.sol";

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
    /// Modifiers
    /// -----------------------------------------------------------------------

    modifier onlyAmAmmEnabled(PoolId id) {
        _checkAmAmmEnabled(id);
        _;
    }

    /// -----------------------------------------------------------------------
    /// Constants
    /// -----------------------------------------------------------------------

    function K(PoolId) internal view virtual returns (uint48) {
        return 7200;
    }

    function MIN_BID_MULTIPLIER(PoolId) internal view virtual returns (uint256) {
        return 1.1e18;
    }

    function MIN_RENT(PoolId) internal view virtual returns (uint128) {
        return 0;
    }

    /// -----------------------------------------------------------------------
    /// Immutable args
    /// -----------------------------------------------------------------------

    /// @dev The block number at which the contract was deployed
    uint256 internal immutable _deploymentBlockNumber;

    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    mapping(PoolId id => Bid) internal _topBids;
    mapping(PoolId id => Bid) internal _nextBids;
    mapping(PoolId id => uint48) internal _lastUpdatedBlockIdx;
    mapping(Currency currency => uint256) internal _totalFees;
    mapping(address manager => mapping(PoolId id => uint256)) internal _refunds;
    mapping(address manager => mapping(Currency currency => uint256)) internal _fees;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor() {
        _deploymentBlockNumber = BlockNumberLib.getBlockNumber();
    }

    /// -----------------------------------------------------------------------
    /// Bidder actions
    /// -----------------------------------------------------------------------

    /// @inheritdoc IAmAmm
    function bid(PoolId id, address manager, bytes6 payload, uint128 rent, uint128 deposit)
        public
        virtual
        override
        onlyAmAmmEnabled(id)
    {
        address msgSender = LibMulticaller.senderOrSigner();

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // update state machine
        _updateAmAmmWrite(id);

        // ensure bid is valid
        // - manager can't be zero address
        // - bid needs to be greater than the next bid by >10%
        // - deposit needs to cover the rent for K blocks
        // - deposit needs to be a multiple of rent
        // - payload needs to be valid
        // - rent needs to be at least MIN_RENT
        if (
            manager == address(0) || rent <= _nextBids[id].rent.mulWad(MIN_BID_MULTIPLIER(id)) || deposit < rent * K(id)
                || deposit % rent != 0 || !_payloadIsValid(id, payload) || rent < MIN_RENT(id)
        ) {
            revert AmAmm__InvalidBid();
        }

        // refund deposit of the previous next bid
        _refunds[_nextBids[id].manager][id] += _nextBids[id].deposit;

        // update next bid
        uint48 blockIdx = uint48(BlockNumberLib.getBlockNumber() - _deploymentBlockNumber);
        _nextBids[id] = Bid(manager, blockIdx, payload, rent, deposit);

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // transfer deposit from msg.sender to this contract
        _pullBidToken(id, msgSender, deposit);

        emit SubmitBid(id, manager, blockIdx, payload, rent, deposit);
    }

    /// @inheritdoc IAmAmm
    function depositIntoBid(PoolId id, uint128 amount, bool isTopBid) public virtual override onlyAmAmmEnabled(id) {
        address msgSender = LibMulticaller.senderOrSigner();

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // update state machine
        _updateAmAmmWrite(id);

        Bid storage bidStorage = isTopBid ? _topBids[id] : _nextBids[id];
        Bid memory bidMemory = bidStorage;

        // only the top bid manager can deposit into the top bid
        if (msgSender != bidMemory.manager) {
            revert AmAmm__Unauthorized();
        }

        // ensure amount is a multiple of rent
        if (amount % bidMemory.rent != 0) {
            revert AmAmm__InvalidDepositAmount();
        }

        // add amount to top bid deposit
        bidStorage.deposit = bidMemory.deposit + amount;

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // transfer amount from msg.sender to this contract
        _pullBidToken(id, msgSender, amount);

        if (isTopBid) {
            emit DepositIntoTopBid(id, msgSender, amount);
        } else {
            emit DepositIntoNextBid(id, msgSender, amount);
        }
    }

    /// @inheritdoc IAmAmm
    function withdrawFromBid(PoolId id, uint128 amount, address recipient, bool isTopBid)
        public
        virtual
        override
        onlyAmAmmEnabled(id)
    {
        address msgSender = LibMulticaller.senderOrSigner();

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // update state machine
        _updateAmAmmWrite(id);

        Bid storage bidStorage = isTopBid ? _topBids[id] : _nextBids[id];
        Bid memory bidMemory = bidStorage;

        // only the manager of the relevant bid can withdraw from the bid
        if (msgSender != bidMemory.manager) {
            revert AmAmm__Unauthorized();
        }

        // ensure amount is a multiple of rent
        if (amount % bidMemory.rent != 0) {
            revert AmAmm__InvalidDepositAmount();
        }

        // require D / R >= K
        if ((bidMemory.deposit - amount) / bidMemory.rent < K(id)) {
            revert AmAmm__BidLocked();
        }

        // deduct amount from bid deposit
        bidStorage.deposit = bidMemory.deposit - amount;

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // transfer amount to recipient
        _pushBidToken(id, recipient, amount);

        if (isTopBid) {
            emit WithdrawFromTopBid(id, msgSender, recipient, amount);
        } else {
            emit WithdrawFromNextBid(id, msgSender, recipient, amount);
        }
    }

    /// @inheritdoc IAmAmm
    function claimRefund(PoolId id, address recipient)
        public
        virtual
        override
        onlyAmAmmEnabled(id)
        returns (uint256 refund)
    {
        address msgSender = LibMulticaller.senderOrSigner();

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // update state machine
        _updateAmAmmWrite(id);

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

        emit ClaimRefund(id, msgSender, recipient, refund);
    }

    /// @inheritdoc IAmAmm
    function claimFees(Currency currency, address recipient) public virtual override returns (uint256 fees) {
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

        emit ClaimFees(currency, msgSender, recipient, fees);
    }

    /// @inheritdoc IAmAmm
    function increaseBidRent(
        PoolId id,
        uint128 additionalRent,
        uint128 updatedDeposit,
        bool isTopBid,
        address withdrawRecipient
    ) public virtual override onlyAmAmmEnabled(id) returns (uint128 amountDeposited, uint128 amountWithdrawn) {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        address msgSender = LibMulticaller.senderOrSigner();

        // noop if additionalRent is 0
        if (additionalRent == 0) return (0, 0);

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // update state machine
        _updateAmAmmWrite(id);

        Bid storage relevantBidStorage = isTopBid ? _topBids[id] : _nextBids[id];
        Bid memory relevantBid = relevantBidStorage;

        // must be the manager of the relevant bid
        if (msgSender != relevantBid.manager) {
            revert AmAmm__Unauthorized();
        }

        uint128 newRent = relevantBid.rent + additionalRent;

        // ensure that:
        // - updatedDeposit is a multiple of newRent
        // - newRent is >= MIN_RENT(id)
        if (updatedDeposit % newRent != 0 || newRent < MIN_RENT(id)) {
            revert AmAmm__InvalidBid();
        }

        // require D / R >= K
        if (updatedDeposit / newRent < K(id)) {
            revert AmAmm__BidLocked();
        }

        // update relevant bid
        relevantBidStorage.rent = newRent;
        relevantBidStorage.deposit = updatedDeposit;

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        unchecked {
            // explicitly comparing updatedDeposit and relevantBid.deposit so subtractions are always safe
            if (updatedDeposit > relevantBid.deposit) {
                // transfer amount from msg.sender to this contract
                amountDeposited = updatedDeposit - relevantBid.deposit;
                _pullBidToken(id, msgSender, amountDeposited);
            } else if (updatedDeposit < relevantBid.deposit) {
                // transfer amount from this contract to withdrawRecipient
                amountWithdrawn = relevantBid.deposit - updatedDeposit;
                _pushBidToken(id, withdrawRecipient, amountWithdrawn);
            }
        }

        emit IncreaseBidRent(
            id, msgSender, additionalRent, updatedDeposit, isTopBid, withdrawRecipient, amountDeposited, amountWithdrawn
        );
    }

    /// @inheritdoc IAmAmm
    function setBidPayload(PoolId id, bytes6 payload, bool isTopBid) public virtual override onlyAmAmmEnabled(id) {
        address msgSender = LibMulticaller.senderOrSigner();

        // update state machine
        _updateAmAmmWrite(id);

        Bid storage relevantBid = isTopBid ? _topBids[id] : _nextBids[id];

        if (msgSender != relevantBid.manager) {
            revert AmAmm__Unauthorized();
        }

        if (!_payloadIsValid(id, payload)) {
            revert AmAmm__InvalidBid();
        }

        relevantBid.payload = payload;

        emit SetBidPayload(id, msgSender, payload, isTopBid);
    }

    /// @inheritdoc IAmAmm
    function updateStateMachine(PoolId id) external override {
        _updateAmAmmWrite(id);
    }

    /// -----------------------------------------------------------------------
    /// Getters
    /// -----------------------------------------------------------------------

    /// @inheritdoc IAmAmm
    function getBid(PoolId id, bool isTopBid) external view override returns (Bid memory) {
        (Bid memory topBid, Bid memory nextBid) = _updateAmAmmView(id);
        return isTopBid ? topBid : nextBid;
    }

    /// @inheritdoc IAmAmm
    function getBidWrite(PoolId id, bool isTopBid) external override returns (Bid memory) {
        _updateAmAmmWrite(id);
        return isTopBid ? _topBids[id] : _nextBids[id];
    }

    /// @inheritdoc IAmAmm
    function getRefund(address manager, PoolId id) external view override returns (uint256) {
        return _refunds[manager][id];
    }

    /// @inheritdoc IAmAmm
    function getRefundWrite(address manager, PoolId id) external override returns (uint256) {
        _updateAmAmmWrite(id);
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

    /// @dev Validates a bid payload, e.g. ensure the swap fee is below a certain threshold
    function _payloadIsValid(PoolId id, bytes6 payload) internal view virtual returns (bool);

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

    function _checkAmAmmEnabled(PoolId id) internal view {
        if (!_amAmmEnabled(id)) {
            revert AmAmm__NotEnabled();
        }
    }

    /// @dev Charges rent and updates the top and next bids for a given pool
    function _updateAmAmmWrite(PoolId id) internal virtual {
        uint48 currentBlockIdx = uint48(BlockNumberLib.getBlockNumber() - _deploymentBlockNumber);

        // early return if the pool has already been updated in this block
        // condition is also true if no update has occurred for type(uint48).max blocks
        // which is extremely unlikely
        if (_lastUpdatedBlockIdx[id] == currentBlockIdx) {
            return;
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
            address stepRefundManager;
            uint256 stepRefundAmount;
            while (true) {
                (
                    topBid,
                    nextBid,
                    stepHasUpdatedTopBid,
                    stepHasUpdatedNextBid,
                    stepRentCharged,
                    stepRefundManager,
                    stepRefundAmount
                ) = _stateTransition(currentBlockIdx, id, topBid, nextBid);

                if (!stepHasUpdatedTopBid && !stepHasUpdatedNextBid) {
                    break;
                }

                updatedTopBid = updatedTopBid || stepHasUpdatedTopBid;
                updatedNextBid = updatedNextBid || stepHasUpdatedNextBid;
                rentCharged += stepRentCharged;
                if (stepRefundManager != address(0)) {
                    _refunds[stepRefundManager][id] += stepRefundAmount;
                }
            }
        }

        // update top and next bids
        if (updatedTopBid) {
            _topBids[id] = topBid;
        }
        if (updatedNextBid) {
            _nextBids[id] = nextBid;
        }

        // update last updated blockIdx
        _lastUpdatedBlockIdx[id] = currentBlockIdx;

        // burn rent charged
        if (rentCharged != 0) {
            _burnBidToken(id, rentCharged);
        }
    }

    /// @dev View version of _updateAmAmmWrite()
    function _updateAmAmmView(PoolId id) internal view virtual returns (Bid memory topBid, Bid memory nextBid) {
        uint48 currentBlockIdx = uint48(BlockNumberLib.getBlockNumber() - _deploymentBlockNumber);

        topBid = _topBids[id];
        nextBid = _nextBids[id];

        // early return if the pool has already been updated in this block
        // condition is also true if no update has occurred for type(uint48).max blocks
        // which is extremely unlikely
        if (_lastUpdatedBlockIdx[id] == currentBlockIdx) {
            return (topBid, nextBid);
        }

        // run state machine
        {
            bool stepHasUpdatedTopBid;
            bool stepHasUpdatedNextBid;
            while (true) {
                (topBid, nextBid, stepHasUpdatedTopBid, stepHasUpdatedNextBid,,,) =
                    _stateTransition(currentBlockIdx, id, topBid, nextBid);

                if (!stepHasUpdatedTopBid && !stepHasUpdatedNextBid) {
                    break;
                }
            }
        }
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
    ///                 │                        │                         │              │
    ///              bid(r)                  after K                    bid(r)         after K
    ///                 │                     blocks                       │           blocks
    ///                 │                        │                         │              │
    ///                 │                        │                         │              │
    ///                 │                        │   after                 │              │
    ///                 ├────────────────────────┼──deposit ───────────────┼──────────────┤
    ///                 │                        │  depletes               │              │
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
    function _stateTransition(uint48 currentBlockIdx, PoolId id, Bid memory topBid, Bid memory nextBid)
        internal
        view
        virtual
        returns (
            Bid memory,
            Bid memory,
            bool updatedTopBid,
            bool updatedNextBid,
            uint256 rentCharged,
            address refundManager,
            uint256 refundAmount
        )
    {
        uint48 k = K(id);
        if (nextBid.manager == address(0)) {
            if (topBid.manager != address(0)) {
                // State B
                // charge rent from top bid
                uint48 blocksPassed;
                unchecked {
                    // unchecked so that if blockIdx ever overflows, we simply wrap around
                    // could be 0 if no update has occurred for type(uint48).max blocks
                    // which is extremely unlikely
                    blocksPassed = currentBlockIdx - topBid.blockIdx;
                }
                uint256 rentOwed = blocksPassed * topBid.rent;
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
                    topBid.blockIdx = currentBlockIdx;

                    updatedTopBid = true;
                }
            }
        } else {
            if (topBid.manager == address(0)) {
                // State C
                // check if K blocks have passed since the next bid was submitted
                // if so, promote next bid to top bid
                uint48 nextBidStartBlockIdx;
                unchecked {
                    // unchecked so that if blockIdx ever overflows, we simply wrap around
                    nextBidStartBlockIdx = nextBid.blockIdx + k;
                }
                if (currentBlockIdx >= nextBidStartBlockIdx) {
                    // State C -> State B
                    // promote next bid to top bid
                    topBid = nextBid;
                    topBid.blockIdx = nextBidStartBlockIdx;
                    nextBid = Bid(address(0), 0, 0, 0, 0);

                    updatedTopBid = true;
                    updatedNextBid = true;
                }
            } else {
                // State D
                // we charge rent from the top bid only until K blocks after the next bid was submitted
                // assuming the next bid's rent is greater than the top bid's rent + 10%, otherwise we don't care about
                // the next bid
                bool nextBidIsBetter = nextBid.rent > topBid.rent.mulWad(MIN_BID_MULTIPLIER(id));
                uint48 blocksPassed;
                unchecked {
                    // unchecked so that if blockIdx ever overflows, we simply wrap around
                    blocksPassed = nextBidIsBetter
                        ? uint48(
                            FixedPointMathLib.min(currentBlockIdx - topBid.blockIdx, nextBid.blockIdx + k - topBid.blockIdx)
                        )
                        : currentBlockIdx - topBid.blockIdx;
                }
                uint256 rentOwed = blocksPassed * topBid.rent;
                if (rentOwed >= topBid.deposit) {
                    // State D -> State C
                    // top bid has insufficient deposit
                    // clear the top bid and make sure the next bid starts >= the latest processed blockIdx
                    rentCharged = topBid.deposit;

                    topBid = Bid(address(0), 0, 0, 0, 0);
                    unchecked {
                        // unchecked so that if blockIdx ever underflows, we simply wrap around
                        uint48 latestProcessedBlockIdx = nextBidIsBetter
                            ? uint48(FixedPointMathLib.min(currentBlockIdx, nextBid.blockIdx + k))
                            : currentBlockIdx;
                        nextBid.blockIdx = uint48(FixedPointMathLib.max(nextBid.blockIdx, latestProcessedBlockIdx - k));
                    }

                    updatedTopBid = true;
                    updatedNextBid = true;
                } else {
                    // State D
                    // top bid has sufficient deposit
                    // charge rent from top bid
                    if (rentOwed != 0) {
                        rentCharged = rentOwed;

                        topBid.deposit -= rentOwed.toUint128();
                        topBid.blockIdx = currentBlockIdx;

                        updatedTopBid = true;
                    }

                    // check if K blocks have passed since the next bid was submitted
                    // and that the next bid's rent is greater than the top bid's rent + 10%
                    // if so, promote next bid to top bid
                    uint48 nextBidStartBlockIdx;
                    unchecked {
                        // unchecked so that if blockIdx ever overflows, we simply wrap around
                        nextBidStartBlockIdx = nextBid.blockIdx + k;
                    }
                    if (currentBlockIdx >= nextBidStartBlockIdx && nextBidIsBetter) {
                        // State D -> State B
                        // refund remaining deposit to top bid manager
                        (refundManager, refundAmount) = (topBid.manager, topBid.deposit);

                        // promote next bid to top bid
                        topBid = nextBid;
                        topBid.blockIdx = nextBidStartBlockIdx;
                        nextBid = Bid(address(0), 0, 0, 0, 0);

                        updatedTopBid = true;
                        updatedNextBid = true;
                    }
                }
            }
        }

        return (topBid, nextBid, updatedTopBid, updatedNextBid, rentCharged, refundManager, refundAmount);
    }
}
