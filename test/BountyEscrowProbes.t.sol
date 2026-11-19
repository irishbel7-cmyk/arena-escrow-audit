// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BountyEscrow} from "../src/BountyEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {Actor} from "./Actor.sol";

/**
 * @notice Security probes for the BountyEscrow contract (Base Sepolia 0xB552A7…560C).
 *         Each test PASSES when the contract behaves as documented; a FAILING test is a
 *         reportable deviation. Uses Actor proxies instead of forge-std cheatcodes, so no
 *         external dependency beyond the published sources is required.
 */
contract BountyEscrowProbes {
    MockUSDC usdc;
    BountyEscrow esc;
    address treasury = address(0xDDD4);
    uint256 actorNonce;

    function _setUp() internal {
        usdc = new MockUSDC();
        esc = new BountyEscrow(IERC20(address(usdc)), treasury, 500, 1_000_000, 100_000_000, 10, 500_000_000);
        actorNonce = 0;
    }

    function _actor() internal returns (Actor a) {
        actorNonce++;
        a = new Actor(address(uint160(0x100000 + actorNonce * 7919)), usdc, address(esc));
        usdc.mint(address(a), 1_000_000_000);
    }

    // ── $25 timing: a stranger must not force payment inside the 3-day review window ──
    function testA_StrangerCannotCompleteInsideReviewWindow() public {
        _setUp();
        Actor p = _actor();
        Actor ag = _actor();
        uint256 id = p.fundAg(address(ag), 10_000_000, block.timestamp + 1 days);
        ag.submit(id, keccak256("w"));
        (bool ok,) = address(esc).call(abi.encodeWithSignature("complete(uint256)", id));
        require(!ok, "BUG: stranger completed inside the review window");
    }

    // ── $25 timing: a poster must not reclaim before the deadline ──
    function testB_PosterCannotReclaimBeforeDeadline() public {
        _setUp();
        Actor p = _actor();
        Actor ag = _actor();
        uint256 id = p.fundAg(address(ag), 10_000_000, block.timestamp + 5 days);
        (bool expired,) = address(esc).call(abi.encodeWithSignature("refundExpired(uint256)", id));
        require(!expired, "BUG: refundExpired succeeded before the deadline");
        require(!p.tryReject(id), "BUG: reject succeeded while the job was still Funded");
    }

    // ── $25 limits: the 11th open job must be refused from the start ──
    function testC_EleventhOpenJobRejected() public {
        _setUp();
        Actor p = _actor();
        for (uint256 i = 0; i < 10; i++) {
            Actor a = _actor();
            p.fundAg(address(a), 1_000_000, block.timestamp + 2 days);
        }
        require(esc.openJobs() == 10, "setup: 10 open jobs expected");
        Actor e = _actor();
        require(!p.tryFund(address(e), 1_000_000, block.timestamp + 2 days), "BUG: 11th open job accepted");
    }

    // ── $100 double pay: one job may only ever pay once ──
    function testD_NoDoublePay() public {
        _setUp();
        Actor p = _actor();
        Actor ag = _actor();
        uint256 id = p.fundAg(address(ag), 50_000_000, block.timestamp + 1 days);
        ag.submit(id, keccak256("w"));
        uint256 before = usdc.balanceOf(address(ag));
        p.complete(id);
        uint256 mid = usdc.balanceOf(address(ag));
        (bool second,) = address(esc).call(abi.encodeWithSignature("complete(uint256)", id));
        uint256 afterBal = usdc.balanceOf(address(ag));
        require(mid - before == 47_500_000, "agent should receive 95%");
        require(!second, "BUG: complete() paid a second time");
        require(afterBal == mid, "BUG: balance changed on the second call");
    }

    // ── $50 lockup: one job's failure must not strand another job's money ──
    function testE_NoCrossJobInterference() public {
        _setUp();
        Actor p1 = _actor();
        Actor a1 = _actor();
        Actor p2 = _actor();
        Actor a2 = _actor();
        uint256 j1 = p1.fundAg(address(a1), 10_000_000, block.timestamp + 1 days);
        uint256 j2 = p2.fundAg(address(a2), 10_000_000, block.timestamp + 1 days);
        a2.submit(j2, keccak256("w2"));
        a1.abandon(j1);
        require(esc.held() == 10_000_000, "held should drop to 10 USDC after the abandon");
        uint256 before = usdc.balanceOf(address(a2));
        p2.complete(j2);
        require(usdc.balanceOf(address(a2)) - before == 9_500_000, "BUG: second job's payout was affected");
    }

    // ── $50 wrong address: no third party may receive a job's money ──
    function testF_PayoutCannotReachThirdParty() public {
        _setUp();
        Actor p = _actor();
        Actor ag = _actor();
        Actor thief = _actor();
        uint256 id = p.fundAg(address(ag), 20_000_000, block.timestamp + 1 days);
        ag.submit(id, keccak256("w"));
        uint256 thiefBefore = usdc.balanceOf(address(thief));
        p.complete(id);
        require(usdc.balanceOf(address(thief)) == thiefBefore, "BUG: a third party received escrowed USDC");
    }

    // ── $50 wrong fee: the split must be exactly feeBps, even on awkward amounts ──
    function testG_FeeIsExact() public {
        _setUp();
        Actor p = _actor();
        Actor ag = _actor();
        uint256 amount = 33_333_333;
        uint256 id = p.fundAg(address(ag), amount, block.timestamp + 1 days);
        ag.submit(id, keccak256("w"));
        uint256 agBefore = usdc.balanceOf(address(ag));
        uint256 trBefore = usdc.balanceOf(treasury);
        p.complete(id);
        uint256 paid = usdc.balanceOf(address(ag)) - agBefore;
        uint256 fee = usdc.balanceOf(treasury) - trBefore;
        require(paid == amount - (amount * 500) / 10_000, "BUG: agent payout is not amount minus the fee");
        require(fee == (amount * 500) / 10_000, "BUG: treasury fee is not feeBps");
        require(paid + fee == amount, "BUG: the split does not conserve the job amount");
    }

    // ── $50 lockup: after settlement the contract keeps no money of its own ──
    function testH_NoTrappedFundsAfterSettlement() public {
        _setUp();
        Actor p = _actor();
        Actor ag = _actor();
        uint256 id = p.fundAg(address(ag), 10_000_000, block.timestamp + 1 days);
        ag.submit(id, keccak256("w"));
        p.complete(id);
        require(usdc.balanceOf(address(esc)) == esc.held(), "BUG: contract holds funds beyond the held total");
        require(esc.held() == 0, "held should be zero after settlement");
        require(esc.totalCredit() == 0, "no credit should remain after a clean payout");
    }

    // ── $25 limits: the total-held cap must hold across jobs ──
    function testI_MaxHeldEnforced() public {
        _setUp();
        Actor p = _actor();
        // $100 max per job; 5 x $100 = $500 cap
        for (uint256 i = 0; i < 5; i++) {
            Actor a = _actor();
            p.fundAg(address(a), 100_000_000, block.timestamp + 2 days);
        }
        require(esc.held() == 500_000_000, "setup: 500 USDC held");
        Actor a2 = _actor();
        require(!p.tryFund(address(a2), 100_000_000, block.timestamp + 2 days), "BUG: held cap exceeded");
    }

    // ── $25 limits: a per-job amount above maxAmount must be refused ──
    function testJ_MaxAmountEnforced() public {
        _setUp();
        Actor p = _actor();
        Actor a = _actor();
        require(!p.tryFund(address(a), 100_000_001, block.timestamp + 2 days), "BUG: amount above maxAmount accepted");
        require(!p.tryFund(address(a), 999_999, block.timestamp + 2 days), "BUG: amount below minAmount accepted");
    }

    // ── $25 timing: fund() must reject deadlines outside [1h, 30d] ──
    function testK_DeadlineBoundsEnforced() public {
        _setUp();
        Actor p = _actor();
        Actor a = _actor();
        require(!p.tryFund(address(a), 10_000_000, block.timestamp + 59 minutes), "BUG: deadline under MIN_DURATION accepted");
        require(!p.tryFund(address(a), 10_000_000, block.timestamp + 31 days), "BUG: deadline over MAX_DURATION accepted");
    }

    // ── $50 lockup: agent abandoning after submitting must not be allowed ──
    function testL_AbandonOnlyWhileFunded() public {
        _setUp();
        Actor p = _actor();
        Actor ag = _actor();
        uint256 id = p.fundAg(address(ag), 10_000_000, block.timestamp + 1 days);
        ag.submit(id, keccak256("w"));
        (bool ok,) = address(ag).call(abi.encodeWithSignature("abandon(uint256)", id));
        require(!ok, "BUG: abandon succeeded in the Submitted state");
    }

    // ── $25 timing: the review window cannot be reopened by re-submitting ──
    function testM_CannotResubmitAfterSubmit() public {
        _setUp();
        Actor p = _actor();
        Actor ag = _actor();
        uint256 id = p.fundAg(address(ag), 10_000_000, block.timestamp + 1 days);
        ag.submit(id, keccak256("w1"));
        (bool ok,) = address(ag).call(abi.encodeWithSignature("submit(uint256,bytes32)", id, keccak256("w2")));
        require(!ok, "BUG: the agent re-submitted, restarting the review window");
    }
}
