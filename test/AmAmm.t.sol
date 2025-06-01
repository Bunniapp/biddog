// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import "./mocks/AmAmmMock.sol";
import "./mocks/ERC20Mock.sol";
import "../src/interfaces/IAmAmm.sol";

contract AmAmmTest is Test {
    PoolId constant POOL_0 = PoolId.wrap(bytes32(0));

    uint128 internal constant K = 7200; // 7200 blocks
    uint256 internal constant MIN_BID_MULTIPLIER = 1.1e18; // 10%

    AmAmmMock amAmm;
    uint256 internal deployBlockNumber;

    function setUp() external {
        deployBlockNumber = vm.getBlockNumber();
        amAmm = new AmAmmMock(new ERC20Mock(), new ERC20Mock(), new ERC20Mock());
        amAmm.bidToken().approve(address(amAmm), type(uint256).max);
        amAmm.setEnabled(POOL_0, true);
        amAmm.setMaxSwapFee(POOL_0, 0.1e6);
    }

    function _swapFeeToPayload(uint24 swapFee) internal pure returns (bytes6) {
        return bytes6(bytes3(swapFee));
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
        IAmAmm.Bid memory bid = amAmm.getBid(POOL_0, false);
        assertEq(amAmm.bidToken().balanceOf(address(this)), 0, "didn't take bid tokens");
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), K * 1e18, "didn't give bid tokens");
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, K * 1e18, "deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "blockIdx incorrect");
    }

    function test_stateTransition_CC() external {
        // mint bid tokens
        amAmm.bidToken().mint(address(this), K * 1e18 + K * 1.2e18);

        // make first bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });

        // make second bid
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1.2e18,
            deposit: K * 1.2e18
        });

        // verify state
        IAmAmm.Bid memory bid = amAmm.getBid(POOL_0, false);
        assertEq(amAmm.bidToken().balanceOf(address(this)), 0, "didn't take bid tokens");
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), K * 1e18 + K * 1.2e18, "didn't give bid tokens");
        assertEq(amAmm.getRefund(address(this), POOL_0), K * 1e18, "didn't refund first bid");
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1.2e18, "rent incorrect");
        assertEq(bid.deposit, K * 1.2e18, "deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "blockIdx incorrect");
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

        // wait K blocks
        skipBlocks(K);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getBidWrite(POOL_0, true);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, K * 1e18, "deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "blockIdx incorrect");
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

        // wait K + 3 blocks
        skipBlocks(K + 3);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getBidWrite(POOL_0, true);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, (K - 3) * 1e18, "deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "blockIdx incorrect");
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

        // wait 2K blocks
        skipBlocks(2 * K);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getBidWrite(POOL_0, true);
        assertEq(bid.manager, address(0), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0), "swapFee incorrect");
        assertEq(bid.rent, 0, "rent incorrect");
        assertEq(bid.deposit, 0, "deposit incorrect");
        assertEq(bid.blockIdx, 0, "blockIdx incorrect");
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

        // wait K blocks
        skipBlocks(K);

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
        IAmAmm.Bid memory bid = amAmm.getBid(POOL_0, true);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, K * 1e18, "deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "blockIdx incorrect");

        // verify next bid state
        bid = amAmm.getBid(POOL_0, false);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 2e18, "rent incorrect");
        assertEq(bid.deposit, 2 * K * 1e18, "deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "blockIdx incorrect");
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

        // wait K blocks
        skipBlocks(K);

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

        // wait 3 blocks
        skipBlocks(3);

        // verify top bid state
        IAmAmm.Bid memory bid = amAmm.getBidWrite(POOL_0, true);
        assertEq(bid.manager, address(this), "top bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "top bid swapFee incorrect");
        assertEq(bid.rent, 1e18, "top bid rent incorrect");
        assertEq(bid.deposit, (K - 3) * 1e18, "top bid deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "top bid blockIdx incorrect");

        // verify next bid state
        bid = amAmm.getBid(POOL_0, false);
        assertEq(bid.manager, address(this), "next bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "next bid swapFee incorrect");
        assertEq(bid.rent, 3e18, "next bid rent incorrect");
        assertEq(bid.deposit, 3 * K * 1e18, "next bid deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx() - 3, "next bid blockIdx incorrect");

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

        // wait K blocks
        skipBlocks(K);

        // mint bid tokens
        amAmm.bidToken().mint(address(this), K * 1e18);

        // make lower bid
        uint48 nextBidBlockIdx = _getBlockIdx();
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.02e6),
            rent: 0.5e18,
            deposit: K * 1e18
        });

        // wait 2K blocks
        // because the bid is lower than the top bid (plus minimum increment), it should be ignored
        skipBlocks(2 * K);

        // verify top bid state
        IAmAmm.Bid memory bid = amAmm.getBidWrite(POOL_0, true);
        assertEq(bid.manager, address(this), "top bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "top bid swapFee incorrect");
        assertEq(bid.rent, 1e18, "top bid rent incorrect");
        assertEq(bid.deposit, 8 * K * 1e18, "top bid deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "top bid blockIdx incorrect");

        // verify next bid state
        bid = amAmm.getBid(POOL_0, false);
        assertEq(bid.manager, address(this), "next bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.02e6), "next bid swapFee incorrect");
        assertEq(bid.rent, 0.5e18, "next bid rent incorrect");
        assertEq(bid.deposit, K * 1e18, "next bid deposit incorrect");
        assertEq(bid.blockIdx, nextBidBlockIdx, "next bid blockIdx incorrect");

        // verify bid token balance
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), 9 * K * 1e18, "bid token balance incorrect");
    }

    function test_stateTransition_DB_afterKBlocks() external {
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

        // wait K blocks
        skipBlocks(K);

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

        // wait K blocks
        skipBlocks(K);

        // verify top bid state
        IAmAmm.Bid memory bid = amAmm.getBidWrite(POOL_0, true);
        assertEq(bid.manager, address(this), "top bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.05e6), "top bid swapFee incorrect");
        assertEq(bid.rent, 2e18, "top bid rent incorrect");
        assertEq(bid.deposit, 2 * K * 1e18, "top bid deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "top bid blockIdx incorrect");

        // verify next bid state
        bid = amAmm.getBid(POOL_0, false);
        assertEq(bid.manager, address(0), "next bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0), "next bid swapFee incorrect");
        assertEq(bid.rent, 0, "next bid rent incorrect");
        assertEq(bid.deposit, 0, "next bid deposit incorrect");
        assertEq(bid.blockIdx, 0, "next bid blockIdx incorrect");

        // verify bid token balance
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), 3 * K * 1e18, "bid token balance incorrect");

        // verify refund
        assertEq(amAmm.getRefund(address(this), POOL_0), K * 1e18, "refund incorrect");
    }

    function test_stateTransition_DC() external {
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

        // wait 2 * K - 3 blocks
        skipBlocks((2 * K - 3));

        // mint bid tokens
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);

        // make next bid
        uint48 nextBidBlockIdx = _getBlockIdx();
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.05e6),
            rent: 2e18,
            deposit: 2 * K * 1e18
        });

        // wait 3 blocks
        skipBlocks(3);

        // verify top bid state
        IAmAmm.Bid memory bid = amAmm.getBidWrite(POOL_0, true);
        assertEq(bid.manager, address(0), "top bid manager incorrect");
        assertEq(bid.payload, 0, "top bid swapFee incorrect");
        assertEq(bid.rent, 0, "top bid rent incorrect");
        assertEq(bid.deposit, 0, "top bid deposit incorrect");
        assertEq(bid.blockIdx, 0, "top bid blockIdx incorrect");

        // verify next bid state
        bid = amAmm.getBid(POOL_0, false);
        assertEq(bid.manager, address(this), "next bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.05e6), "next bid swapFee incorrect");
        assertEq(bid.rent, 2e18, "next bid rent incorrect");
        assertEq(bid.deposit, 2 * K * 1e18, "next bid deposit incorrect");
        assertEq(bid.blockIdx, nextBidBlockIdx, "next bid blockIdx incorrect");

        // verify bid token balance
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), 2 * K * 1e18, "bid token balance incorrect");
    }

    function test_stateTransition_DC_lowNextBidRent() external {
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

        // wait K blocks
        // top bid will last 2K blocks from now
        skipBlocks(K);

        // mint bid tokens
        amAmm.bidToken().mint(address(this), 2 * K * 1e18);

        // make lower bid
        uint48 nextBidBlockIdx = _getBlockIdx();
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.05e6),
            rent: 0.5e18,
            deposit: 2 * K * 1e18
        });

        // wait K blocks
        // top bid should last another K blocks and next bid doesn't activate
        // since the rent is lower than the top bid
        skipBlocks(K);

        // verify top bid state
        IAmAmm.Bid memory bid = amAmm.getBidWrite(POOL_0, true);
        assertEq(bid.manager, address(this), "top bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "top bid swapFee incorrect");
        assertEq(bid.rent, 1e18, "top bid rent incorrect");
        assertEq(bid.deposit, K * 1e18, "top bid deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "top bid blockIdx incorrect");

        // verify next bid state
        bid = amAmm.getBid(POOL_0, false);
        assertEq(bid.manager, address(this), "next bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.05e6), "next bid swapFee incorrect");
        assertEq(bid.rent, 0.5e18, "next bid rent incorrect");
        assertEq(bid.deposit, 2 * K * 1e18, "next bid deposit incorrect");
        assertEq(bid.blockIdx, nextBidBlockIdx, "next bid blockIdx incorrect");

        // verify bid token balance
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), 3 * K * 1e18, "bid token balance incorrect");

        // wait K blocks
        // top bid's deposit is now depleted so next bid should activate
        skipBlocks(K);

        // verify top bid state
        bid = amAmm.getBidWrite(POOL_0, true);
        assertEq(bid.manager, address(this), "later top bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.05e6), "later top bid swapFee incorrect");
        assertEq(bid.rent, 0.5e18, "later top bid rent incorrect");
        assertEq(bid.deposit, 2 * K * 1e18, "later top bid deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "later top bid blockIdx incorrect");

        // verify next bid state
        bid = amAmm.getBid(POOL_0, false);
        assertEq(bid.manager, address(0), "later next bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0), "later next bid swapFee incorrect");
        assertEq(bid.rent, 0, "later next bid rent incorrect");
        assertEq(bid.deposit, 0, "later next bid deposit incorrect");
        assertEq(bid.blockIdx, 0, "later next bid blockIdx incorrect");
    }

    function test_stateTransition_DBA_afterKBlocks() external {
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

        // wait K blocks
        skipBlocks(K);

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

        // wait 2K blocks
        skipBlocks(2 * K);

        // verify top bid state
        IAmAmm.Bid memory bid = amAmm.getBidWrite(POOL_0, true);
        assertEq(bid.manager, address(0), "top bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0), "top bid swapFee incorrect");
        assertEq(bid.rent, 0, "top bid rent incorrect");
        assertEq(bid.deposit, 0, "top bid deposit incorrect");
        assertEq(bid.blockIdx, 0, "top bid blockIdx incorrect");

        // verify next bid state
        bid = amAmm.getBid(POOL_0, false);
        assertEq(bid.manager, address(0), "next bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0), "next bid swapFee incorrect");
        assertEq(bid.rent, 0, "next bid rent incorrect");
        assertEq(bid.deposit, 0, "next bid deposit incorrect");
        assertEq(bid.blockIdx, 0, "next bid blockIdx incorrect");

        // verify bid token balance
        assertEq(amAmm.bidToken().balanceOf(address(amAmm)), K * 1e18, "bid token balance incorrect");

        // verify refund
        assertEq(amAmm.getRefund(address(this), POOL_0), K * 1e18, "refund incorrect");
    }

    function test_stateTransition_DCBA() external {
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

        // wait 2 * K - 3 blocks
        skipBlocks((2 * K - 3));

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

        // wait 2 * K blocks
        skipBlocks((2 * K));

        // verify top bid state
        IAmAmm.Bid memory bid = amAmm.getBidWrite(POOL_0, true);
        assertEq(bid.manager, address(0), "top bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0), "top bid swapFee incorrect");
        assertEq(bid.rent, 0, "top bid rent incorrect");
        assertEq(bid.deposit, 0, "top bid deposit incorrect");
        assertEq(bid.blockIdx, 0, "top bid blockIdx incorrect");

        // verify next bid state
        bid = amAmm.getBid(POOL_0, false);
        assertEq(bid.manager, address(0), "next bid manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0), "next bid swapFee incorrect");
        assertEq(bid.rent, 0, "next bid rent incorrect");
        assertEq(bid.deposit, 0, "next bid deposit incorrect");
        assertEq(bid.blockIdx, 0, "next bid blockIdx incorrect");

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
        skipBlocks(K);
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

        // rent needs to be >= MIN_RENT(id)
        amAmm.setMinRent(POOL_0, 1e18);
        vm.expectRevert(IAmAmm.AmAmm__InvalidBid.selector);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 0.5e18,
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
        skipBlocks(K);

        amAmm.bidToken().mint(address(this), K * 1e18);
        amAmm.depositIntoBid(POOL_0, K * 1e18, true);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getBid(POOL_0, true);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, 3 * K * 1e18, "deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "blockIdx incorrect");

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
        skipBlocks(K);

        amAmm.bidToken().mint(address(this), K * 1e18);
        amAmm.setEnabled(POOL_0, false);
        vm.expectRevert(IAmAmm.AmAmm__NotEnabled.selector);
        amAmm.depositIntoBid(POOL_0, K * 1e18, true);
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
        skipBlocks(K);

        amAmm.bidToken().mint(address(this), K * 1e18);
        vm.startPrank(address(0x42));
        vm.expectRevert(IAmAmm.AmAmm__Unauthorized.selector);
        amAmm.depositIntoBid(POOL_0, K * 1e18, true);
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
        skipBlocks(K);

        amAmm.bidToken().mint(address(this), K * 1e18);
        vm.expectRevert(IAmAmm.AmAmm__InvalidDepositAmount.selector);
        amAmm.depositIntoBid(POOL_0, K * 1e18 - 1, true);
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
        skipBlocks(K);

        address recipient = address(0x42);
        amAmm.withdrawFromBid(POOL_0, K * 1e18, recipient, true);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getBid(POOL_0, true);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, K * 1e18, "deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "blockIdx incorrect");

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
        skipBlocks(K);

        amAmm.setEnabled(POOL_0, false);
        vm.expectRevert(IAmAmm.AmAmm__NotEnabled.selector);
        amAmm.withdrawFromBid(POOL_0, K * 1e18, address(this), true);
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
        skipBlocks(K);

        address recipient = address(0x42);
        vm.startPrank(recipient);
        vm.expectRevert(IAmAmm.AmAmm__Unauthorized.selector);
        amAmm.withdrawFromBid(POOL_0, K * 1e18, recipient, true);
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
        skipBlocks(K);

        vm.expectRevert(IAmAmm.AmAmm__InvalidDepositAmount.selector);
        amAmm.withdrawFromBid(POOL_0, K * 1e18 - 1, address(this), true);
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
        skipBlocks(K);

        vm.expectRevert(IAmAmm.AmAmm__BidLocked.selector);
        amAmm.withdrawFromBid(POOL_0, 2 * K * 1e18, address(this), true);
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
        amAmm.depositIntoBid(POOL_0, K * 1e18, false);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getBid(POOL_0, false);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, 3 * K * 1e18, "deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "blockIdx incorrect");

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
        amAmm.depositIntoBid(POOL_0, K * 1e18, false);
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
        amAmm.depositIntoBid(POOL_0, K * 1e18, false);
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
        amAmm.depositIntoBid(POOL_0, K * 1e18 - 1, false);
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
        amAmm.withdrawFromBid(POOL_0, K * 1e18, recipient, false);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getBid(POOL_0, false);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, K * 1e18, "deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "blockIdx incorrect");

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
        amAmm.withdrawFromBid(POOL_0, K * 1e18, address(this), false);
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
        amAmm.withdrawFromBid(POOL_0, K * 1e18, recipient, false);
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
        amAmm.withdrawFromBid(POOL_0, K * 1e18 - 1, address(this), false);
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
        amAmm.withdrawFromBid(POOL_0, 2 * K * 1e18, address(this), false);
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
        skipBlocks(K);
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
        skipBlocks(K);
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
        skipBlocks(K);
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

    function test_increaseBidRent_topBid_addDeposit() external {
        uint128 additionalRent = 1e18;
        uint128 additionalDeposit = 2e18;

        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18 + additionalDeposit);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skipBlocks(K);

        uint256 beforeUserBalance = amAmm.bidToken().balanceOf(address(this));
        uint256 beforeAmAmmBalance = amAmm.bidToken().balanceOf(address(amAmm));
        (uint128 amountDeposited, uint128 amountWithdrawn) =
            amAmm.increaseBidRent(POOL_0, additionalRent, 2 * K * 1e18 + additionalDeposit, true, address(this));

        // verify state
        IAmAmm.Bid memory bid = amAmm.getBid(POOL_0, true);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18 + additionalRent, "rent incorrect");
        assertEq(bid.deposit, 2 * K * 1e18 + additionalDeposit, "deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "blockIdx incorrect");

        // verify balances
        assertEq(
            amAmm.bidToken().balanceOf(address(this)), beforeUserBalance - additionalDeposit, "user balance incorrect"
        );
        assertEq(
            amAmm.bidToken().balanceOf(address(amAmm)),
            beforeAmAmmBalance + additionalDeposit,
            "amAmm balance incorrect"
        );
        assertEq(amountDeposited, additionalDeposit, "amountDeposited incorrect");
        assertEq(amountWithdrawn, 0, "amountWithdrawn incorrect");
    }

    function test_increaseBidRent_topBid_withdrawDeposit() external {
        uint128 additionalRent = 1e18;
        uint128 withdrawAmount = K * 1e18;

        // start in state B
        amAmm.bidToken().mint(address(this), 3 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 3 * K * 1e18
        });
        skipBlocks(K);

        uint256 beforeUserBalance = amAmm.bidToken().balanceOf(address(this));
        uint256 beforeAmAmmBalance = amAmm.bidToken().balanceOf(address(amAmm));
        (uint128 amountDeposited, uint128 amountWithdrawn) =
            amAmm.increaseBidRent(POOL_0, additionalRent, 3 * K * 1e18 - withdrawAmount, true, address(this));

        // verify state
        IAmAmm.Bid memory bid = amAmm.getBid(POOL_0, true);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.01e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18 + additionalRent, "rent incorrect");
        assertEq(bid.deposit, 3 * K * 1e18 - withdrawAmount, "deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "blockIdx incorrect");

        // verify balances
        assertEq(
            amAmm.bidToken().balanceOf(address(this)), beforeUserBalance + withdrawAmount, "user balance incorrect"
        );
        assertEq(
            amAmm.bidToken().balanceOf(address(amAmm)), beforeAmAmmBalance - withdrawAmount, "amAmm balance incorrect"
        );
        assertEq(amountDeposited, 0, "amountDeposited incorrect");
        assertEq(amountWithdrawn, withdrawAmount, "amountWithdrawn incorrect");
    }

    function test_increaseBidRent_nextBid_addDeposit() external {
        uint128 additionalRent = 1e18;
        uint128 additionalDeposit = K * 1e18;

        // start in state D
        amAmm.bidToken().mint(address(this), K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });
        skipBlocks(K);
        amAmm.bidToken().mint(address(this), 2 * K * 1e18 + additionalDeposit);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.02e6),
            rent: 2e18,
            deposit: 2 * K * 1e18
        });

        uint256 beforeUserBalance = amAmm.bidToken().balanceOf(address(this));
        uint256 beforeAmAmmBalance = amAmm.bidToken().balanceOf(address(amAmm));
        amAmm.increaseBidRent(POOL_0, additionalRent, 2 * K * 1e18 + additionalDeposit, false, address(this));

        // verify state
        IAmAmm.Bid memory bid = amAmm.getBid(POOL_0, false);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.02e6), "swapFee incorrect");
        assertEq(bid.rent, 2e18 + additionalRent, "rent incorrect");
        assertEq(bid.deposit, 2 * K * 1e18 + additionalDeposit, "deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "blockIdx incorrect");

        // verify balances
        assertEq(
            amAmm.bidToken().balanceOf(address(this)), beforeUserBalance - additionalDeposit, "user balance incorrect"
        );
        assertEq(
            amAmm.bidToken().balanceOf(address(amAmm)),
            beforeAmAmmBalance + additionalDeposit,
            "amAmm balance incorrect"
        );
    }

    function test_increaseBidRent_nextBid_withdrawDeposit() external {
        uint128 additionalRent = 1e18;
        uint128 withdrawAmount = K * 1e18;

        // start in state D
        amAmm.bidToken().mint(address(this), K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: K * 1e18
        });
        skipBlocks(K);
        amAmm.bidToken().mint(address(this), 4 * K * 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.02e6),
            rent: 2e18,
            deposit: 4 * K * 1e18
        });

        uint256 beforeUserBalance = amAmm.bidToken().balanceOf(address(this));
        uint256 beforeAmAmmBalance = amAmm.bidToken().balanceOf(address(amAmm));
        (uint128 amountDeposited, uint128 amountWithdrawn) =
            amAmm.increaseBidRent(POOL_0, additionalRent, 4 * K * 1e18 - withdrawAmount, false, address(this));

        // verify state
        IAmAmm.Bid memory bid = amAmm.getBid(POOL_0, false);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.02e6), "swapFee incorrect");
        assertEq(bid.rent, 2e18 + additionalRent, "rent incorrect");
        assertEq(bid.deposit, 4 * K * 1e18 - withdrawAmount, "deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "blockIdx incorrect");

        // verify balances
        assertEq(
            amAmm.bidToken().balanceOf(address(this)), beforeUserBalance + withdrawAmount, "user balance incorrect"
        );
        assertEq(
            amAmm.bidToken().balanceOf(address(amAmm)), beforeAmAmmBalance - withdrawAmount, "amAmm balance incorrect"
        );
        assertEq(amountDeposited, 0, "amountDeposited incorrect");
        assertEq(amountWithdrawn, withdrawAmount, "amountWithdrawn incorrect");
    }

    function test_increaseBidRent_fail_notEnabled() external {
        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18 + 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skipBlocks(K);

        amAmm.setEnabled(POOL_0, false);
        vm.expectRevert(IAmAmm.AmAmm__NotEnabled.selector);
        amAmm.increaseBidRent(POOL_0, 1e18, 1e18, true, address(this));
    }

    function test_increaseBidRent_fail_unauthorized() external {
        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18 + 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skipBlocks(K);

        address eve = address(0x42);
        vm.startPrank(eve);
        vm.expectRevert(IAmAmm.AmAmm__Unauthorized.selector);
        amAmm.increaseBidRent(POOL_0, 1e18, 1e18, true, address(this));
        vm.stopPrank();
    }

    function test_increaseBidRent_fail_invalidBid() external {
        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18 + 1);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skipBlocks(K);

        // updated deposit not a multiple of rent
        vm.expectRevert(IAmAmm.AmAmm__InvalidBid.selector);
        amAmm.increaseBidRent(POOL_0, 1e18, 1, true, address(this));

        // rent too low
        amAmm.setMinRent(POOL_0, 10e18);
        vm.expectRevert(IAmAmm.AmAmm__InvalidBid.selector);
        amAmm.increaseBidRent(POOL_0, 1e18, 2 * K * 1e18, true, address(this));
    }

    function test_increaseBidRent_fail_bidLocked() external {
        // start in state B
        amAmm.bidToken().mint(address(this), 2 * K * 1e18 + 1e18);
        amAmm.bid({
            id: POOL_0,
            manager: address(this),
            payload: _swapFeeToPayload(0.01e6),
            rent: 1e18,
            deposit: 2 * K * 1e18
        });
        skipBlocks(K);

        vm.expectRevert(IAmAmm.AmAmm__BidLocked.selector);
        amAmm.increaseBidRent(POOL_0, K * 1e18 - 1e18, 2 * K * 1e18, true, address(this));
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
        skipBlocks(K);

        amAmm.setBidPayload(POOL_0, _swapFeeToPayload(0.02e6), true);

        // verify state
        IAmAmm.Bid memory bid = amAmm.getBid(POOL_0, true);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.02e6), "swapFee incorrect");
        assertEq(bid.rent, 1e18, "rent incorrect");
        assertEq(bid.deposit, 2 * K * 1e18, "deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "blockIdx incorrect");
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
        skipBlocks(K);
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
        IAmAmm.Bid memory bid = amAmm.getBid(POOL_0, false);
        assertEq(bid.manager, address(this), "manager incorrect");
        assertEq(bid.payload, _swapFeeToPayload(0.02e6), "swapFee incorrect");
        assertEq(bid.rent, 2e18, "rent incorrect");
        assertEq(bid.deposit, 2 * K * 1e18, "deposit incorrect");
        assertEq(bid.blockIdx, _getBlockIdx(), "blockIdx incorrect");
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
        skipBlocks(K);

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
        skipBlocks(K);

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
        skipBlocks(K);

        vm.expectRevert(IAmAmm.AmAmm__InvalidBid.selector);
        amAmm.setBidPayload(POOL_0, _swapFeeToPayload(0.5e6), true);
    }

    function _getBlockIdx() internal view returns (uint48) {
        return uint48(vm.getBlockNumber() - deployBlockNumber);
    }

    function skipBlocks(uint256 numBlocks) internal {
        vm.roll(vm.getBlockNumber() + numBlocks);
    }
}
