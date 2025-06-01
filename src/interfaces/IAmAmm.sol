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
        PoolId indexed id,
        address indexed manager,
        uint48 indexed blockIdx,
        bytes6 payload,
        uint128 rent,
        uint128 deposit
    );
    event DepositIntoTopBid(PoolId indexed id, address indexed manager, uint128 amount);
    event WithdrawFromTopBid(PoolId indexed id, address indexed manager, address indexed recipient, uint128 amount);
    event DepositIntoNextBid(PoolId indexed id, address indexed manager, uint128 amount);
    event WithdrawFromNextBid(PoolId indexed id, address indexed manager, address indexed recipient, uint128 amount);
    event ClaimRefund(PoolId indexed id, address indexed manager, address indexed recipient, uint256 refund);
    event ClaimFees(Currency indexed currency, address indexed manager, address indexed recipient, uint256 fees);
    event SetBidPayload(PoolId indexed id, address indexed manager, bytes6 payload, bool topBid);
    event IncreaseBidRent(
        PoolId indexed id,
        address indexed manager,
        uint128 additionalRent,
        uint128 updatedDeposit,
        bool topBid,
        address indexed withdrawRecipient,
        uint128 amountDeposited,
        uint128 amountWithdrawn
    );

    struct Bid {
        address manager;
        uint48 blockIdx; // block number (minus contract deployment block) when the bid was created / last charged rent
        bytes6 payload; // payload specifying what parames the manager wants, e.g. swap fee
        uint128 rent; // rent per block
        uint128 deposit; // rent deposit amount
    }

    /// @notice Places a bid to become the manager of a pool
    /// @param id The pool id
    /// @param manager The address of the manager
    /// @param payload The payload specifying what parameters the manager wants, e.g. swap fee
    /// @param rent The rent per block
    /// @param deposit The deposit amount, must be a multiple of rent and cover rent for >=K blocks
    function bid(PoolId id, address manager, bytes6 payload, uint128 rent, uint128 deposit) external;

    /// @notice Adds deposit to the top/next bid. Only callable by topBids[id].manager or nextBids[id].manager (depending on `isTopBid`).
    /// @param id The pool id
    /// @param amount The amount to deposit, must be a multiple of rent
    /// @param isTopBid True if the top bid manager is depositing, false if the next bid manager is depositing
    function depositIntoBid(PoolId id, uint128 amount, bool isTopBid) external;

    /// @notice Withdraws from the deposit of the top/next bid. Only callable by topBids[id].manager or nextBids[id].manager (depending on `isTopBid`). Reverts if D / R < K.
    /// @param id The pool id
    /// @param amount The amount to withdraw, must be a multiple of rent and leave D / R >= K
    /// @param recipient The address of the recipient
    /// @param isTopBid True if the top bid manager is withdrawing, false if the next bid manager is withdrawing
    function withdrawFromBid(PoolId id, uint128 amount, address recipient, bool isTopBid) external;

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

    /// @notice Increases the rent of a bid. Only callable by the manager of the relevant bid. Reverts if D / R < K after the update.
    /// Reverts if updated deposit is not a multiple of the new rent. Noop if additionalRent is 0. Will take/send the difference between the old and new deposits.
    /// @param id The pool id
    /// @param additionalRent The additional rent to add
    /// @param updatedDeposit The updated deposit amount of the bid
    /// @param isTopBid True if the top bid manager is increasing the rent and deposit, false if the next bid manager is increasing the rent and deposit
    /// @param withdrawRecipient The address to withdraw the difference between the old and new deposits to
    /// @return amountDeposited The amount of deposit added, if any
    /// @return amountWithdrawn The amount of deposit withdrawn, if any
    function increaseBidRent(
        PoolId id,
        uint128 additionalRent,
        uint128 updatedDeposit,
        bool isTopBid,
        address withdrawRecipient
    ) external returns (uint128 amountDeposited, uint128 amountWithdrawn);

    /// @notice Sets the payload of a pool. Only callable by the manager of either the top bid or the next bid.
    /// @param id The pool id
    /// @param payload The payload specifying e.g. the swap fee
    /// @param isTopBid True if the top bid manager is setting the fee, false if the next bid manager is setting the fee
    function setBidPayload(PoolId id, bytes6 payload, bool isTopBid) external;

    /// @notice Gets the top/next bid of a pool
    /// @param id The pool id
    /// @param isTopBid True if the top bid is requested, false if the next bid is requested
    function getBid(PoolId id, bool isTopBid) external view returns (Bid memory);

    /// @notice Updates the am-AMM state of a pool and then gets the top/next bid
    /// @param id The pool id
    /// @param isTopBid True if the top bid is requested, false if the next bid is requested
    function getBidWrite(PoolId id, bool isTopBid) external returns (Bid memory);

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
