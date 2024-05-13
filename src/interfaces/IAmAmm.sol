// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface IAmAmm {
    error AmAmm__BidLocked();
    error AmAmm__InvalidBid();
    error AmAmm__NotEnabled();
    error AmAmm__Unauthorized();
    error AmAmm__InvalidDepositAmount();

    event SubmitBid(
        PoolId indexed id, address indexed manager, uint40 indexed epoch, bytes7 payload, uint128 rent, uint128 deposit
    );
    event DepositIntoTopBid(PoolId indexed id, address indexed manager, uint128 amount);
    event WithdrawFromTopBid(PoolId indexed id, address indexed manager, address indexed recipient, uint128 amount);
    event DepositIntoNextBid(PoolId indexed id, address indexed manager, uint128 amount);
    event WithdrawFromNextBid(PoolId indexed id, address indexed manager, address indexed recipient, uint128 amount);
    event CancelNextBid(PoolId indexed id, address indexed manager, address indexed recipient, uint256 refund);
    event ClaimRefund(PoolId indexed id, address indexed manager, address indexed recipient, uint256 refund);
    event ClaimFees(Currency indexed currency, address indexed manager, address indexed recipient, uint256 fees);
    event SetBidPayload(PoolId indexed id, address indexed manager, bytes7 payload, bool topBid);

    struct Bid {
        address manager;
        uint40 epoch; // epoch when the bid was created / last charged rent
        bytes7 payload; // payload specifying what parames the manager wants, e.g. swap fee
        uint128 rent; // rent per hour
        uint128 deposit; // rent deposit amount
    }

    /// @notice Places a bid to become the manager of a pool
    /// @param id The pool id
    /// @param manager The address of the manager
    /// @param payload The payload specifying what parameters the manager wants, e.g. swap fee
    /// @param rent The rent per epoch
    /// @param deposit The deposit amount, must be a multiple of rent and cover rent for >=K epochs
    function bid(PoolId id, address manager, bytes7 payload, uint128 rent, uint128 deposit) external;

    /// @notice Adds deposit to the top bid. Only callable by topBids[id].manager.
    /// @param id The pool id
    /// @param amount The amount to deposit, must be a multiple of rent
    function depositIntoTopBid(PoolId id, uint128 amount) external;

    /// @notice Withdraws from the deposit of the top bid. Only callable by topBids[id].manager. Reverts if D_top / R_top < K.
    /// @param id The pool id
    /// @param amount The amount to withdraw, must be a multiple of rent and leave D_top / R_top >= K
    /// @param recipient The address of the recipient
    function withdrawFromTopBid(PoolId id, uint128 amount, address recipient) external;

    /// @notice Adds deposit to the next bid. Only callable by nextBids[id].manager.
    /// @param id The pool id
    /// @param amount The amount to deposit, must be a multiple of rent
    function depositIntoNextBid(PoolId id, uint128 amount) external;

    /// @notice Withdraws from the deposit of the next bid. Only callable by nextBids[id].manager. Reverts if D_next / R_next < K.
    /// @param id The pool id
    /// @param amount The amount to withdraw, must be a multiple of rent and leave D_next / R_next >= K
    /// @param recipient The address of the recipient
    function withdrawFromNextBid(PoolId id, uint128 amount, address recipient) external;

    /// @notice Cancels the next bid. Only callable by nextBids[id].manager. Reverts if D_top / R_top < K.
    /// @param id The pool id
    /// @param recipient The address of the recipient
    /// @return refund The amount of refund claimed
    function cancelNextBid(PoolId id, address recipient) external returns (uint256 refund);

    /// @notice Claims the refundable deposit of a pool owed to msg.sender.
    /// @param id The pool id
    /// @param recipient The address of the manager
    /// @return refund The amount of refund claimed
    function claimRefund(PoolId id, address recipient) external returns (uint256 refund);

    /// @notice Claims the accrued fees of msg.sender.
    /// @param currency The currency of the fees
    /// @param recipient The address of the recipient
    /// @return fees The amount of fees claimed
    function claimFees(Currency currency, address recipient) external returns (uint256 fees);

    /// @notice Sets the payload of a pool. Only callable by the manager of either the top bid or the next bid.
    /// @param id The pool id
    /// @param payload The payload specifying e.g. the swap fee
    /// @param topBid True if the top bid manager is setting the fee, false if the next bid manager is setting the fee
    function setBidPayload(PoolId id, bytes7 payload, bool topBid) external;

    /// @notice Gets the top bid of a pool
    function getTopBid(PoolId id) external view returns (Bid memory);

    /// @notice Updates the am-AMM state of a pool and then gets the top bid
    function getTopBidWrite(PoolId id) external returns (Bid memory);

    /// @notice Gets the next bid of a pool
    function getNextBid(PoolId id) external view returns (Bid memory);

    /// @notice Updates the am-AMM state of a pool and then gets the next bid
    function getNextBidWrite(PoolId id) external returns (Bid memory);

    /// @notice Gets the refundable deposit of a pool
    /// @param manager The address of the manager
    /// @param id The pool id
    function getRefund(address manager, PoolId id) external view returns (uint256);

    /// @notice Updates the am-AMM state of a pool and then gets the refundable deposit owed to a manager in that pool
    /// @param manager The address of the manager
    /// @param id The pool id
    function getRefundWrite(address manager, PoolId id) external returns (uint256);

    /// @notice Gets the fees accrued by a manager
    /// @param manager The address of the manager
    /// @param currency The currency of the fees
    function getFees(address manager, Currency currency) external view returns (uint256);

    /// @notice Triggers a state machine update for the given pool
    /// @param id The pool id
    function updateStateMachine(PoolId id) external;
}
