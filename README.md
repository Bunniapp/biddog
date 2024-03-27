# BidDog

<img src="./biddog.png" alt="BidDog logo" align="right" width="120" />

BidDog is an open-source implementation of am-AMM ([Auction-Managed Automated Market Maker](http://arxiv.org/abs/2403.03367v1)), an add-on to decentralized exchanges that minimizes losses to arbitrage.

## Concepts

- **Epoch**: The smallest unit of time used by BidDog, set to 1 hour long by default.
- **K**: The delay (in epochs) of a bid being submitted and the bidder becoming the manager of a pool. Set to 24 by default.
- **`MIN_BID_MULTIPLIER`**: Specifies the minimum bid increment. Set to (1 + 10%) by default.
- **Manager**: The manager of a pool pays rent (in the bid token) each epoch for the privilege of receiving all swap fee revenue and setting the swap fee.
- **Bid**: Each bid in the auction specifies its rent (amount of bid tokens paid per epoch) and deposit (used to pay rent, >= rent \* K). The bid with the highest rent wins the auction.
- **Bid token**: The token used for bidding in the auction, usually the LP token of a DEX pool. Burnt over time by the manager to pay the rent to the remaining LPs.
- **Fee token**: Token collected as swap fee revenue. There are usually 2 fee tokens for each DEX pool.
- **Refund**: If you currently own the next bid and someone else makes a higher bid, your deposit is refunded to you, which you will need to claim.

## Developer usage

Import `biddog/AmAmm.sol` and inherit from `AmAmm`, then implement the following functions based on the specifics of your DEX:

```solidity
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
```

When you need to query the current manager & swap fee value, use:

```solidity
/// @dev Charges rent and updates the top and next bids for a given pool
function _updateAmAmm(PoolId id) internal virtual returns (address manager, uint24 swapFee);
```

When your DEX needs to accrue swap fees to a manager, use:

```solidity
/// @dev Accrues swap fees to the manager
function _accrueFees(address manager, Currency currency, uint256 amount) internal virtual;
```

Optionally, you can override the constants used by am-AMM:

```solidity
function K(PoolId) internal view virtual returns (uint72) {
    return 24;
}

function EPOCH_SIZE(PoolId) internal view virtual returns (uint256) {
    return 1 hours;
}

function MIN_BID_MULTIPLIER(PoolId) internal view virtual returns (uint256) {
    return 1.1e18;
}
```

## Manager usage

```solidity
/// @notice Places a bid to become the manager of a pool
/// @param id The pool id
/// @param manager The address of the manager
/// @param rent The rent per epoch
/// @param deposit The deposit amount, must be a multiple of rent and cover rent for >=K epochs
function bid(PoolId id, address manager, uint24 swapFee, uint128 rent, uint128 deposit) external;

/// @notice Withdraws from the deposit of the top bid. Only callable by topBids[id].manager. Reverts if D_top / R_top < K.
/// @param id The pool id
/// @param amount The amount to withdraw, must be a multiple of rent and leave D_top / R_top >= K
/// @param recipient The address of the recipient
function withdrawFromTopBid(PoolId id, uint128 amount, address recipient) external;

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

/// @notice Sets the swap fee of a pool. Only callable by the manager of either the top bid or the next bid.
/// @param id The pool id
/// @param swapFee The new swap fee
/// @param topBid True if the top bid manager is setting the fee, false if the next bid manager is setting the fee
function setBidSwapFee(PoolId id, uint24 swapFee, bool topBid) external;
```

## Design

BidDog was built as a state machine with the following state transitions:

```
                                          after
                 ┌───────────────────────deposit ───────────────────┐
                 │                       depletes                   │
                 ▼                                                  │
    ┌────────────────────────┐                         ┌────────────────────────┐
    │                        │                         │                        │
    │        State A         │                         │        State B         │
    │      Manager: nil      │            ┌───────────▶│      Manager: r0       │◀─┐
    │       Next: nil        │            │            │       Next: nil        │  │
    │                        │            │            │                        │  │
    └────────────────────────┘            │            └────────────────────────┘  │
                 │                        │                         │              │
                 │                        │                         │              │
                 │                        │                         │              │
                 │                        │                         │           after K
              bid(r)                  after K                    bid(r)        epochs or
                 │                     epochs                       │            after
                 │                        │                         │           deposit
                 │                        │                         │          depletes
                 │                        │                         │              │
                 │                        │                         │              │
                 │                        │                         │              │
                 ▼                        │                         ▼              │
    ┌────────────────────────┐            │            ┌────────────────────────┐  │
    │                        │            │            │                        │  │
    │        State C         │            │            │        State D         │  │
 ┌─▶│      Manager: nil      │────────────┘         ┌─▶│      Manager: r0       │──┘
 │  │        Next: r         │                      │  │        Next: r         │
 │  │                        │                      │  │                        │
 │  └────────────────────────┘                      │  └────────────────────────┘
 │               │                                  │               │
 │               │                                  │               │
 └─────bid(r)────┘                                  └─────bid(r)────┘
```

## Modifications

Several modifications were made on the original am-AMM design to improve UX.

- The auction period `K` is denominated in epochs instead of blocks, where each epoch is an amount of time in seconds. In `AmAmm.sol` this value is set to 1 hour.
  - This change was made to better support different networks with different block times (e.g. L2s).
- When withdrawing from the deposit of the next bid, we enforce `D_next / R_next >= K` instead of `D_top / R_top + D_next / R_next >= K` to ensure that the deposit of a bid cannot go below `R * K` before the bid becomes active.

## Installation

To install with [Foundry](https://github.com/gakonst/foundry):

```
forge install bunniapp/biddog
```

## Local development

This project uses [Foundry](https://github.com/gakonst/foundry) as the development framework.

### Dependencies

```
forge install
```

### Compilation

```
forge build
```

### Testing

```
forge test
```
