// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import "./mocks/AmAmmMock.sol";
import "./mocks/ERC20Mock.sol";
import "../src/interfaces/IAmAmm.sol";

contract AmAmmTest is Test {
    PoolId constant POOL_0 = PoolId.wrap(bytes32(0));

    uint128 internal constant K = 24; // 24 windows (hours)
    uint256 internal constant EPOCH_SIZE = 1 hours;
    uint256 internal constant MIN_BID_MULTIPLIER = 1.1e18; // 10%

    AmAmmMock amAmm;

    function setUp() external {
        amAmm = new AmAmmMock(new ERC20Mock(), new ERC20Mock(), new ERC20Mock());
        amAmm.bidToken().approve(address(amAmm), type(uint256).max);
        amAmm.setEnabled(POOL_0, true);
        amAmm.setMaxSwapFee(POOL_0, 0.1e6);
    }

    function _swapFeeToPayload(uint24 swapFee) internal pure returns (bytes7) {
        return bytes7(bytes3(swapFee));
    }

    function test_stateTransition_AC() external {
        // mint bid tokens
        amAmm.bidToken().mint(address(this), K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });

        // verify state
        IAmAmm.Bid memory bid = amAmm.getNextBid(POOL_0);
        assertEq(amAmm.bidToken().balanceOf(address(this)), 0, "didn't take bid tokens");
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), K * 1e18, "didn't give bid tokens");
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, K * 1e18, "deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "epoch incorrect");
    }

    function test_stateTransition_CC() external {
        // mint bid tokens
        amAmm.bidToken().mint(address(this), K * 1e18 + 30e18);

        // make first bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });

        // make second bid
        amAmm.bid({id: POOL_0, manager: address(this), payload: _swapFeeToPayload(0.01e6), rent: 1.2e18, deposit: 30e18});

        // verify state
        IAmAmm.Bid memory bid = amAmm.getNextBid(POOL_0);
        assertEq(amAmm.bidToken().balanceOf(address(this)), 0, "didn't take bid tokens");
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), K * 1e18 + 30e18, "didn't give bid tokens");
        assertEq(amAmm.getRefund(address(this), POOL_0), K * 1e18, "didn't refund first bid");
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1.2e18, "rent incorrect");
        assertEq(bid.deposit, 30e18, "deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "epoch incorrect");
    }

    function test_stateTransition_CB() external {
        // mint bid tokens
        amAmm.bidToken().mint(address(this), K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });

        // wait K epochs
        skip(K * EPOCH_SIZE);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getTopBidWrite(POOL_0);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, K * 1e18, "deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "epoch incorrect");
    }

    function test_stateTransition_BB() external {
        // mint bid tokens
        amAmm.bidToken().mint(address(this), K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });

        // wait K + 3 epochs
        skip((K + 3) * EPOCH_SIZE);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getTopBidWrite(POOL_0);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, (K - 3) * 1e18, "deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "epoch incorrect");
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), bid.deposit, "didn't burn rent");
    }

    function test_stateTransition_BA() external {
        // mint bid tokens
        amAmm.bidToken().mint(address(this), K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });

        // wait 2K epochs
        skip(2 * K * EPOCH_SIZE);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getTopBidWrite(POOL_0);
        assertEq(bid.manager, address(0), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0), "swapFee incorrect");
        assertEq(bid.rent, 0, "rent incorrect");
        assertEq(bid.deposit, 0, "deposit incorrect");
        assertEq(bid.epoch, 0, "epoch incorrect");
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), bid.deposit, "didn't burn rent");
    }

    function test_stateTransition_BD() external {
        // mint bid tokens
        amAmm.bidToken().mint(address(this), K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });

        // wait K epochs
        skip(K * EPOCH_SIZE);

        // mint bid tokens
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 2e18,
            deposit: 2 * K * 1e18
        });

        // verify top bid state
        IAmAmm.Bid memory bid = amAmm.getTopBid(POOL_0);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, K * 1e18, "deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "epoch incorrect");

        // verify next bid state
        bid = amAmm.getNextBid(POOL_0);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 2e18, "rent incorrect");
        assertEq(bid.deposit, 2 * K * 1e18, "deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "epoch incorrect");
    }

    function test_stateTransition_DD() external {
        // mint bid tokens
        amAmm.bidToken().mint(address(this), K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });

        // wait K epochs
        skip(K * EPOCH_SIZE);

        // mint bid tokens
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 2e18,
            deposit: 2 * K * 1e18
        });

        // mint bid tokens
        amAmm.bidToken().mint(address(this), 3 * K * 1e18);

        // make higher bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 3e18,
            deposit: 3 * K * 1e18
        });

        // wait 3 epochs
        skip(3 * EPOCH_SIZE);

        // verify top bid state
        IAmAmm.Bid memory bid = amAmm.getTopBidWrite(POOL_0);
        assertEq(bid.manager, address(this), "top bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "top bid swapFee incorrect");
        assertEq(bid.rent, 1e18, "top bid rent incorrect");
        assertEq(bid.deposit, (K - 3) * 1e18, "top bid deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "top bid epoch incorrect");

        // verify next bid state
        bid = amAmm.getNextBid(POOL_0);
        assertEq(bid.manager, address(this), "next bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "next bid swapFee incorrect");
        assertEq(bid.rent, 3e18, "next bid rent incorrect");
        assertEq(bid.deposit, 3 * K * 1e18, "next bid deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()) - 3, "next bid epoch incorrect");

        // verify bid token balance
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), (6 * K - 3) * 1e18, "bid token balance incorrect");
    }

    function test_stateTransition_DD_lowNextBidRent() external {
        // mint bid tokens
        amAmm.bidToken().mint(address(this), 10 * K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 10 * K * 1e18
        });

        // wait K epochs
        skip(K * EPOCH_SIZE);

        // mint bid tokens
        amAmm.bidToken().mint(address(this), K * 1e18);

        // make lower bid
        uint40 nextBidEpoch = _getEpoch(vm.getBlockTimestamp());
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.02e6),
            rent: 0.5e18,
            deposit: K * 1e18
        });

        // wait 2K epochs
        // because the bid is lower than the top bid (plus minimum increment), it should be ignored
        skip(2 * K * EPOCH_SIZE);

        // verify top bid state
        IAmAmm.Bid memory bid = amAmm.getTopBidWrite(POOL_0);
        assertEq(bid.manager, address(this), "top bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "top bid swapFee incorrect");
        assertEq(bid.rent, 1e18, "top bid rent incorrect");
        assertEq(bid.deposit, 8 * K * 1e18, "top bid deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "top bid epoch incorrect");

        // verify next bid state
        bid = amAmm.getNextBid(POOL_0);
        assertEq(bid.manager, address(this), "next bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.02e6), "next bid swapFee incorrect");
        assertEq(bid.rent, 0.5e18, "next bid rent incorrect");
        assertEq(bid.deposit, K * 1e18, "next bid deposit incorrect");
        assertEq(bid.epoch, nextBidEpoch, "next bid epoch incorrect");

        // verify bid token balance
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), 9 * K * 1e18, "bid token balance incorrect");
    }

    function test_stateTransition_DB_afterKEpochs() external {
        // mint bid tokens
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });

        // wait K epochs
        skip(K * EPOCH_SIZE);

        // mint bid tokens
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.05e6),
            rent: 2e18,
            deposit: 2 * K * 1e18
        });

        // wait K epochs
        skip(K * EPOCH_SIZE);

        // verify top bid state
        IAmAmm.Bid memory bid = amAmm.getTopBidWrite(POOL_0);
        assertEq(bid.manager, address(this), "top bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.05e6), "top bid swapFee incorrect");
        assertEq(bid.rent, 2e18, "top bid rent incorrect");
        assertEq(bid.deposit, 2 * K * 1e18, "top bid deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "top bid epoch incorrect");

        // verify next bid state
        bid = amAmm.getNextBid(POOL_0);
        assertEq(bid.manager, address(0), "next bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0), "next bid swapFee incorrect");
        assertEq(bid.rent, 0, "next bid rent incorrect");
        assertEq(bid.deposit, 0, "next bid deposit incorrect");
        assertEq(bid.epoch, 0, "next bid epoch incorrect");

        // verify bid token balance
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), 3 * K * 1e18, "bid token balance incorrect");

        // verify refund
        assertEq(amAmm.getRefund(address(this), POOL_0), K * 1e18, "refund incorrect");
    }

    function test_stateTransition_DB_afterDepositDepletes() external {
        // mint bid tokens
        amAmm.bidToken().mint(address(this), K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });

        // wait 2 * K - 3 epochs
        skip((2 * K - 3) * EPOCH_SIZE);

        // mint bid tokens
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.05e6),
            rent: 2e18,
            deposit: 2 * K * 1e18
        });

        // wait 3 epochs
        skip(3 * EPOCH_SIZE);

        // verify top bid state
        IAmAmm.Bid memory bid = amAmm.getTopBidWrite(POOL_0);
        assertEq(bid.manager, address(this), "top bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.05e6), "top bid swapFee incorrect");
        assertEq(bid.rent, 2e18, "top bid rent incorrect");
        assertEq(bid.deposit, 2 * K * 1e18, "top bid deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "top bid epoch incorrect");

        // verify next bid state
        bid = amAmm.getNextBid(POOL_0);
        assertEq(bid.manager, address(0), "next bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0), "next bid swapFee incorrect");
        assertEq(bid.rent, 0, "next bid rent incorrect");
        assertEq(bid.deposit, 0, "next bid deposit incorrect");
        assertEq(bid.epoch, 0, "next bid epoch incorrect");

        // verify bid token balance
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), 2 * K * 1e18, "bid token balance incorrect");
    }

    function test_stateTransition_DB_afterDepositDepletes_lowNextBidRent() external {
        // mint bid tokens
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });

        // wait K epochs
        // top bid will last 2K epochs from now
        skip(K * EPOCH_SIZE);

        // mint bid tokens
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);

        // make lower bid
        uint40 nextBidEpoch = _getEpoch(vm.getBlockTimestamp());
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.05e6),
            rent: 0.5e18,
            deposit: 2 * K * 1e18
        });

        // wait K epochs
        // top bid should last another K epochs and next bid doesn't activate
        // since the rent is lower than the top bid
        skip(K * EPOCH_SIZE);

        // verify top bid state
        IAmAmm.Bid memory bid = amAmm.getTopBidWrite(POOL_0);
        assertEq(bid.manager, address(this), "top bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "top bid swapFee incorrect");
        assertEq(bid.rent, 1e18, "top bid rent incorrect");
        assertEq(bid.deposit, K * 1e18, "top bid deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "top bid epoch incorrect");

        // verify next bid state
        bid = amAmm.getNextBid(POOL_0);
        assertEq(bid.manager, address(this), "next bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.05e6), "next bid swapFee incorrect");
        assertEq(bid.rent, 0.5e18, "next bid rent incorrect");
        assertEq(bid.deposit, 2 * K * 1e18, "next bid deposit incorrect");
        assertEq(bid.epoch, nextBidEpoch, "next bid epoch incorrect");

        // verify bid token balance
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), 3 * K * 1e18, "bid token balance incorrect");

        // wait K epochs
        // top bid's deposit is now depleted so next bid should activate
        skip(K * EPOCH_SIZE);

        // verify top bid state
        bid = amAmm.getTopBidWrite(POOL_0);
        assertEq(bid.manager, address(this), "later top bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.05e6), "later top bid swapFee incorrect");
        assertEq(bid.rent, 0.5e18, "later top bid rent incorrect");
        assertEq(bid.deposit, 2 * K * 1e18, "later top bid deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "later top bid epoch incorrect");

        // verify next bid state
        bid = amAmm.getNextBid(POOL_0);
        assertEq(bid.manager, address(0), "later next bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0), "later next bid swapFee incorrect");
        assertEq(bid.rent, 0, "later next bid rent incorrect");
        assertEq(bid.deposit, 0, "later next bid deposit incorrect");
        assertEq(bid.epoch, 0, "later next bid epoch incorrect");
    }

    function test_stateTransition_DBA_afterKEpochs() external {
        // mint bid tokens
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });

        // wait K epochs
        skip(K * EPOCH_SIZE);

        // mint bid tokens
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.05e6),
            rent: 2e18,
            deposit: 2 * K * 1e18
        });

        // wait 2K epochs
        skip(2 * K * EPOCH_SIZE);

        // verify top bid state
        IAmAmm.Bid memory bid = amAmm.getTopBidWrite(POOL_0);
        assertEq(bid.manager, address(0), "top bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0), "top bid swapFee incorrect");
        assertEq(bid.rent, 0, "top bid rent incorrect");
        assertEq(bid.deposit, 0, "top bid deposit incorrect");
        assertEq(bid.epoch, 0, "top bid epoch incorrect");

        // verify next bid state
        bid = amAmm.getNextBid(POOL_0);
        assertEq(bid.manager, address(0), "next bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0), "next bid swapFee incorrect");
        assertEq(bid.rent, 0, "next bid rent incorrect");
        assertEq(bid.deposit, 0, "next bid deposit incorrect");
        assertEq(bid.epoch, 0, "next bid epoch incorrect");

        // verify bid token balance
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), K * 1e18, "bid token balance incorrect");

        // verify refund
        assertEq(amAmm.getRefund(address(this), POOL_0), K * 1e18, "refund incorrect");
    }

    function test_stateTransition_DBA_afterDepositDepletes() external {
        // mint bid tokens
        amAmm.bidToken().mint(address(this), K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });

        // wait 2 * K - 3 epochs
        skip((2 * K - 3) * EPOCH_SIZE);

        // mint bid tokens
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);

        // make bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.05e6),
            rent: 2e18,
            deposit: 2 * K * 1e18
        });

        // wait K + 3 epochs
        skip((K + 3) * EPOCH_SIZE);

        // verify top bid state
        IAmAmm.Bid memory bid = amAmm.getTopBidWrite(POOL_0);
        assertEq(bid.manager, address(0), "top bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0), "top bid swapFee incorrect");
        assertEq(bid.rent, 0, "top bid rent incorrect");
        assertEq(bid.deposit, 0, "top bid deposit incorrect");
        assertEq(bid.epoch, 0, "top bid epoch incorrect");

        // verify next bid state
        bid = amAmm.getNextBid(POOL_0);
        assertEq(bid.manager, address(0), "next bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0), "next bid swapFee incorrect");
        assertEq(bid.rent, 0, "next bid rent incorrect");
        assertEq(bid.deposit, 0, "next bid deposit incorrect");
        assertEq(bid.epoch, 0, "next bid epoch incorrect");

        // verify bid token balance
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), 0, "bid token balance incorrect");
    }

    function test_bid_fail_notEnabled() external {
        amAmm.setEnabled(POOL_0, false);
        amAmm.bidToken().mint(address(this), K * 1e18);
        vm.expectRevert(IAmAmm.AmAmm__NotEnabled.selector);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });
    }

    function test_bid_fail_invalidBid() external {
        // start in state D
        amAmm.bidToken().mint(address(this), K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });
        skip(K * EPOCH_SIZE);
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 2e18,
            deposit: 2 * K * 1e18
        });

        amAmm.bidToken().mint(address(this), 3 * K * 1e18);

        // manager can't be zero address
        vm.expectRevert(IAmAmm.AmAmm__InvalidBid.selector);
        amAmm.bid({
            id: POOL_0,
            manager: address(0),
            payload: _swapFeeToPayload(0.01e6),
            rent: 3e18,
            deposit: 3 * K * 1e18
        });

        // bid needs to be greater than top bid and next bid by >10%
        vm.expectRevert(IAmAmm.AmAmm__InvalidBid.selector);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 3 * K * 1e18
        });
        vm.expectRevert(IAmAmm.AmAmm__InvalidBid.selector);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1.1e18,
            deposit: 3 * K * 1e18
        });
        vm.expectRevert(IAmAmm.AmAmm__InvalidBid.selector);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 2.2e18,
            deposit: 3 * K * 1e18
        });

        // deposit needs to cover the rent for K hours
        vm.expectRevert(IAmAmm.AmAmm__InvalidBid.selector);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 3e18,
            deposit: 2 * K * 1e18
        });

        // deposit needs to be a multiple of rent
        vm.expectRevert(IAmAmm.AmAmm__InvalidBid.selector);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 3e18,
            deposit: 3 * K * 1e18 + 1
        });

        // swap fee needs to be <= _maxSwapFee(id)
        vm.expectRevert(IAmAmm.AmAmm__InvalidBid.selector);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.5e6),
            rent: 3e18,
            deposit: 3 * K * 1e18
        });
    }

    function test_depositIntoTopBid() external {
        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skip(K * EPOCH_SIZE);

        amAmm.bidToken().mint(address(this), K * 1e18);
        amAmm.depositIntoTopBid(POOL_0, K * 1e18);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getTopBid(POOL_0);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, 3 * K * 1e18, "deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "epoch incorrect");

        // verify token balances
        assertEq(amAmm.bidToken().balanceOf(address(this)), 0, "manager balance incorrect");
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), 3 * K * 1e18, "contract balance incorrect");
    }

    function test_depositIntoTopBid_fail_notEnabled() external {
        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skip(K * EPOCH_SIZE);

        amAmm.bidToken().mint(address(this), K * 1e18);
        amAmm.setEnabled(POOL_0, false);
        vm.expectRevert(IAmAmm.AmAmm__NotEnabled.selector);
        amAmm.depositIntoTopBid(POOL_0, K * 1e18);
    }

    function test_depositIntoTopBid_fail_unauthorized() external {
        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skip(K * EPOCH_SIZE);

        amAmm.bidToken().mint(address(this), K * 1e18);
        vm.startPrank(address(0x42));
        vm.expectRevert(IAmAmm.AmAmm__Unauthorized.selector);
        amAmm.depositIntoTopBid(POOL_0, K * 1e18);
        vm.stopPrank();
    }

    function test_depositIntoTopBid_fail_invalidDepositAmount() external {
        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skip(K * EPOCH_SIZE);

        amAmm.bidToken().mint(address(this), K * 1e18);
        vm.expectRevert(IAmAmm.AmAmm__InvalidDepositAmount.selector);
        amAmm.depositIntoTopBid(POOL_0, K * 1e18 - 1);
    }

    function test_withdrawFromTopBid() external {
        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skip(K * EPOCH_SIZE);

        address recipient = address(0x42);
        amAmm.withdrawFromTopBid(POOL_0, K * 1e18, recipient);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getTopBid(POOL_0);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, K * 1e18, "deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "epoch incorrect");

        // verify token balances
        assertEq(amAmm.bidToken().balanceOf(recipient), K * 1e18, "recipient balance incorrect");
    }

    function test_withdrawFromTopBid_fail_notEnabled() external {
        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skip(K * EPOCH_SIZE);

        amAmm.setEnabled(POOL_0, false);
        vm.expectRevert(IAmAmm.AmAmm__NotEnabled.selector);
        amAmm.withdrawFromTopBid(POOL_0, K * 1e18, address(this));
    }

    function test_withdrawFromTopBid_fail_unauthorized() external {
        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skip(K * EPOCH_SIZE);

        address recipient = address(0x42);
        vm.startPrank(recipient);
        vm.expectRevert(IAmAmm.AmAmm__Unauthorized.selector);
        amAmm.withdrawFromTopBid(POOL_0, K * 1e18, recipient);
        vm.stopPrank();
    }

    function test_withdrawFromTopBid_fail_invalidDepositAmount() external {
        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skip(K * EPOCH_SIZE);

        vm.expectRevert(IAmAmm.AmAmm__InvalidDepositAmount.selector);
        amAmm.withdrawFromTopBid(POOL_0, K * 1e18 - 1, address(this));
    }

    function test_withdrawFromTopBid_bidLocked() external {
        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skip(K * EPOCH_SIZE);

        vm.expectRevert(IAmAmm.AmAmm__BidLocked.selector);
        amAmm.withdrawFromTopBid(POOL_0, 2 * K * 1e18, address(this));
    }

    function test_depositIntoNextBid() external {
        // start in state C
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });

        amAmm.bidToken().mint(address(this), K * 1e18);
        amAmm.depositIntoNextBid(POOL_0, K * 1e18);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getNextBid(POOL_0);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, 3 * K * 1e18, "deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "epoch incorrect");

        // verify token balances
        assertEq(amAmm.bidToken().balanceOf(address(this)), 0, "manager balance incorrect");
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), 3 * K * 1e18, "contract balance incorrect");
    }

    function test_depositIntoNextBid_fail_notEnabled() external {
        // start in state C
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });

        amAmm.bidToken().mint(address(this), K * 1e18);
        amAmm.setEnabled(POOL_0, false);
        vm.expectRevert(IAmAmm.AmAmm__NotEnabled.selector);
        amAmm.depositIntoNextBid(POOL_0, K * 1e18);
    }

    function test_depositIntoNextBid_fail_unauthorized() external {
        // start in state C
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });

        amAmm.bidToken().mint(address(this), K * 1e18);
        vm.startPrank(address(0x42));
        vm.expectRevert(IAmAmm.AmAmm__Unauthorized.selector);
        amAmm.depositIntoNextBid(POOL_0, K * 1e18);
        vm.stopPrank();
    }

    function test_depositIntoNextBid_fail_invalidDepositAmount() external {
        // start in state C
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });

        amAmm.bidToken().mint(address(this), K * 1e18);
        vm.expectRevert(IAmAmm.AmAmm__InvalidDepositAmount.selector);
        amAmm.depositIntoNextBid(POOL_0, K * 1e18 - 1);
    }

    function test_withdrawFromNextBid() external {
        // start in state C
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });

        address recipient = address(0x42);
        amAmm.withdrawFromNextBid(POOL_0, K * 1e18, recipient);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getNextBid(POOL_0);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, K * 1e18, "deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "epoch incorrect");

        // verify token balances
        assertEq(amAmm.bidToken().balanceOf(recipient), K * 1e18, "recipient balance incorrect");
    }

    function test_withdrawFromNextBid_fail_notEnabled() external {
        // start in state C
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });

        amAmm.setEnabled(POOL_0, false);
        vm.expectRevert(IAmAmm.AmAmm__NotEnabled.selector);
        amAmm.withdrawFromNextBid(POOL_0, K * 1e18, address(this));
    }

    function test_withdrawFromNextBid_fail_unauthorized() external {
        // start in state C
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });

        address recipient = address(0x42);
        vm.startPrank(recipient);
        vm.expectRevert(IAmAmm.AmAmm__Unauthorized.selector);
        amAmm.withdrawFromNextBid(POOL_0, K * 1e18, recipient);
        vm.stopPrank();
    }

    function test_withdrawFromNextBid_fail_invalidDepositAmount() external {
        // start in state C
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });

        vm.expectRevert(IAmAmm.AmAmm__InvalidDepositAmount.selector);
        amAmm.withdrawFromNextBid(POOL_0, K * 1e18 - 1, address(this));
    }

    function test_withdrawFromNextBid_fail_bidLocked() external {
        // start in state C
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });

        vm.expectRevert(IAmAmm.AmAmm__BidLocked.selector);
        amAmm.withdrawFromNextBid(POOL_0, 2 * K * 1e18, address(this));
    }

    function test_cancelNextBid() external {
        // start in state C
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });

        address recipient = address(0x42);
        amAmm.cancelNextBid(POOL_0, recipient);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getNextBid(POOL_0);
        assertEq(bid.manager, address(0), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0), "swapFee incorrect");
        assertEq(bid.rent, 0, "rent incorrect");
        assertEq(bid.deposit, 0, "deposit incorrect");
        assertEq(bid.epoch, 0, "epoch incorrect");

        // verify token balances
        assertEq(amAmm.bidToken().balanceOf(recipient), 2 * K * 1e18, "recipient balance incorrect");
    }

    function test_cancelNextBid_fail_notEnabled() external {
        // start in state C
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });

        amAmm.setEnabled(POOL_0, false);
        vm.expectRevert(IAmAmm.AmAmm__NotEnabled.selector);
        amAmm.cancelNextBid(POOL_0, address(this));
    }

    function test_cancelNextBid_fail_unauthorized() external {
        // start in state C
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });

        address recipient = address(0x42);
        vm.startPrank(recipient);
        vm.expectRevert(IAmAmm.AmAmm__Unauthorized.selector);
        amAmm.cancelNextBid(POOL_0, recipient);
        vm.stopPrank();
    }

    function test_cancelNextBid_fail_bidLocked() external {
        // start in state D
        amAmm.bidToken().mint(address(this), K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });
        skip(K * EPOCH_SIZE);
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 2e18,
            deposit: 2 * K * 1e18
        });

        skip(EPOCH_SIZE);
        vm.expectRevert(IAmAmm.AmAmm__BidLocked.selector);
        amAmm.cancelNextBid(POOL_0, address(this));
    }

    function test_claimRefund() external {
        // start in state D
        amAmm.bidToken().mint(address(this), K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });
        skip(K * EPOCH_SIZE);
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 2e18,
            deposit: 2 * K * 1e18
        });

        // make higher bid
        amAmm.bidToken().mint(address(this), 3 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 3e18,
            deposit: 3 * K * 1e18
        });

        assertEq(amAmm.getRefund(address(this), POOL_0), 2 * K * 1e18, "get refund incorrect");

        // claim refund
        address recipient = address(0x42);
        uint256 refundAmount = amAmm.claimRefund(POOL_0, recipient);

        assertEq(refundAmount, 2 * K * 1e18, "refund amount incorrect");
        assertEq(amAmm.bidToken().balanceOf(recipient), 2 * K * 1e18, "recipient balance incorrect");
    }

    function test_claimRefund_fail_notEnabled() external {
        // start in state D
        amAmm.bidToken().mint(address(this), K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });
        skip(K * EPOCH_SIZE);
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 2e18,
            deposit: 2 * K * 1e18
        });

        // make higher bid
        amAmm.bidToken().mint(address(this), 3 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 3e18,
            deposit: 3 * K * 1e18
        });

        amAmm.setEnabled(POOL_0, false);
        vm.expectRevert(IAmAmm.AmAmm__NotEnabled.selector);
        amAmm.claimRefund(POOL_0, address(this));
    }

    function test_claimFees() external {
        // start in state D
        amAmm.bidToken().mint(address(this), K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });
        skip(K * EPOCH_SIZE);
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(0x69),
            payload: _swapFeeToPayload(0.01e6),
            rent: 2e18,
            deposit: 2 * K * 1e18
        });

        // give fees
        amAmm.giveFeeToken0(POOL_0, 1 ether);
        amAmm.giveFeeToken1(POOL_0, 2 ether);

        // claim fees
        address recipient = address(0x42);
        uint256 feeAmount0 = amAmm.claimFees(Currency.wrap(address(amAmm.feeToken0())), recipient);
        uint256 feeAmount1 = amAmm.claimFees(Currency.wrap(address(amAmm.feeToken1())), recipient);

        // check results
        assertEq(feeAmount0, 1 ether, "feeAmount0 incorrect");
        assertEq(feeAmount1, 2 ether, "feeAmount1 incorrect");
        assertEq(amAmm.feeToken0().balanceOf(recipient), 1 ether, "recipient balance0 incorrect");
        assertEq(amAmm.feeToken1().balanceOf(recipient), 2 ether, "recipient balance1 incorrect");
    }

    function test_setBidPayload_topBid() external {
        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skip(K * EPOCH_SIZE);

        amAmm.setBidPayload(POOL_0, _swapFeeToPayload(0.02e6), true);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getTopBid(POOL_0);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.02e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, 2 * K * 1e18, "deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "epoch incorrect");
    }

    function test_setBidPayload_nextBid() external {
        // start in state D
        amAmm.bidToken().mint(address(this), K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });
        skip(K * EPOCH_SIZE);
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 2e18,
            deposit: 2 * K * 1e18
        });

        amAmm.setBidPayload(POOL_0, _swapFeeToPayload(0.02e6), false);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getNextBid(POOL_0);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.02e6), "swapFee incorrect");
        assertEq(bid.rent, 2e18, "rent incorrect");
        assertEq(bid.deposit, 2 * K * 1e18, "deposit incorrect");
        assertEq(bid.epoch, _getEpoch(vm.getBlockTimestamp()), "epoch incorrect");
    }

    function test_setBidPayload_fail_notEnabled() external {
        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skip(K * EPOCH_SIZE);

        amAmm.setEnabled(POOL_0, false);
        vm.expectRevert(IAmAmm.AmAmm__NotEnabled.selector);
        amAmm.setBidPayload(POOL_0, _swapFeeToPayload(0.02e6), true);
    }

    function test_setBidPayload_fail_unauthorized() external {
        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skip(K * EPOCH_SIZE);

        address eve = address(0x42);
        vm.startPrank(eve);
        vm.expectRevert(IAmAmm.AmAmm__Unauthorized.selector);
        amAmm.setBidPayload(POOL_0, _swapFeeToPayload(0.02e6), true);
        vm.stopPrank();
    }

    function test_setBidPayload_fail_invalidSwapFee() external {
        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skip(K * EPOCH_SIZE);

        vm.expectRevert(IAmAmm.AmAmm__InvalidBid.selector);
        amAmm.setBidPayload(POOL_0, _swapFeeToPayload(0.5e6), true);
    }

    function _getEpoch(uint256 timestamp) internal pure returns (uint40) {
        return uint40(timestamp / EPOCH_SIZE);
    }
}
