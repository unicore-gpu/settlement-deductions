// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SettlementDeductionPolicy} from "../src/SettlementDeductionPolicy.sol";
import {ISettlementDeductions, ISettlementCredit} from "../src/interfaces/ISettlementDeductions.sol";
import {ISettlementDeductionPolicy} from "../src/interfaces/ISettlementDeductionPolicy.sol";
import {ITaxSchedule} from "../src/interfaces/ITaxSchedule.sol";
import {ExampleEscrow} from "../src/examples/ExampleEscrow.sol";

contract USD {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external virtual returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

/// A token that calls back into the policy when it pays the policy.
contract CallbackUSD is USD {
    address public target;
    bytes public callData;
    function arm(address t, bytes calldata d) external { target = t; callData = d; }
    function transfer(address to, uint256 a) external override returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a;
        if (to == target) {
            (bool ok, ) = target.call(callData);
            require(ok, "callback failed");
        }
        return true;
    }
}

contract Schedule is ITaxSchedule {
    address public treasury;
    uint16 public bps;
    function set(address t, uint16 b) external { treasury = t; bps = b; }
    function taxOf(address) external view returns (address, uint16) { return (treasury, bps); }
}

contract RevertingPolicy {
    function onTaskCreated(uint256, address, uint256) external {}
    function deductions(uint256, uint256, address, uint256) external pure returns (uint256) { revert("boom"); }
}

contract LoudPolicy {
    function onTaskCreated(uint256, address, uint256) external {}
    function deductions(uint256, uint256, address, uint256) external pure returns (uint256) {
        assembly { revert(0, 300000) } // revert with ~300 KB of return data
    }
}

contract GreedyPolicy {
    function onTaskCreated(uint256, address, uint256) external {}
    function deductions(uint256, uint256, address, uint256 a) external pure returns (uint256) { return a + 1; }
}

contract SettlementDeductionPolicyTest is Test {
    USD usd;
    Schedule schedule;
    SettlementDeductionPolicy p;
    ExampleEscrow escrow;

    address creator  = address(0xC4EA);
    address worker   = address(0xCAFE);
    address treasury = address(0x7EA5);
    address insurer  = address(0x1A5);
    address lender   = address(0x10A1);
    address rando    = address(0xBAD);
    uint256 constant U = 1e6;

    function setUp() public {
        usd = new USD();
        schedule = new Schedule();
        schedule.set(treasury, 100); // 1%
        (p, escrow) = _deploy(schedule, 5000);
        usd.mint(creator, 10_000 * U);
        vm.deal(creator, 10 ether);
    }

    /// Policy and escrow name each other: deploy the policy at the escrow's future address.
    function _deploy(ITaxSchedule s, uint16 cap) internal returns (SettlementDeductionPolicy pp, ExampleEscrow ee) {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        pp = new SettlementDeductionPolicy(next, s, cap);
        ee = new ExampleEscrow(pp);
        assertEq(address(ee), next);
    }

    function _task(uint256 amount) internal returns (uint256 id) {
        vm.startPrank(creator);
        usd.approve(address(escrow), amount);
        id = escrow.createTask(address(usd), amount);
        vm.stopPrank();
    }

    function _pay(uint256 id) internal {
        vm.prank(creator);
        escrow.pay(id, worker);
    }

    // ------------------------------------------------ the design example: 1 / 2 / 30 / 67
    function test_design_example() public {
        uint256 id = _task(100 * U);
        vm.startPrank(worker);
        p.assignPayment(id, insurer, 200, 0);    // premium 2%
        p.assignPayment(id, lender, 0, 30 * U);  // repay 30
        vm.stopPrank();
        _pay(id);

        assertEq(usd.balanceOf(worker), 67 * U);
        assertEq(escrow.creditOf(id, address(p)), 33 * U, "one total credited to the policy");
        assertEq(p.owedOf(id, treasury), 1 * U);
        assertEq(p.owedOf(id, insurer), 2 * U);
        assertEq(p.owedOf(id, lender), 30 * U);

        vm.startPrank(rando); // anyone may trigger; money goes to the recipient
        p.claim(id, treasury);
        p.claim(id, insurer);
        p.claim(id, lender);
        vm.stopPrank();
        assertEq(usd.balanceOf(treasury), 1 * U);
        assertEq(usd.balanceOf(insurer), 2 * U);
        assertEq(usd.balanceOf(lender), 30 * U);
        assertEq(usd.balanceOf(address(p)), 0, "policy keeps nothing");
        assertEq(usd.balanceOf(address(escrow)), 0);
    }

    // ------------------------------------------------ tax is locked at creation
    function test_rate_change_does_not_reach_existing_task() public {
        uint256 id = _task(100 * U);
        schedule.set(treasury, 900);
        _pay(id);
        assertEq(p.owedOf(id, treasury), 1 * U);
        (, uint16 newRate) = p.lockedTaxOf(_task(100 * U));
        assertEq(newRate, 900, "a new task sees the new rate");
    }

    function test_tax_above_cap_blocks_creation() public {
        schedule.set(treasury, 6000);
        vm.startPrank(creator);
        usd.approve(address(escrow), 1 * U);
        vm.expectRevert("Deductions: tax above cap");
        escrow.createTask(address(usd), 1 * U);
        vm.stopPrank();
    }

    function test_no_schedule_no_tax() public {
        (SettlementDeductionPolicy pp, ExampleEscrow ee) = _deploy(ITaxSchedule(address(0)), 5000);
        vm.startPrank(creator);
        usd.approve(address(ee), 100 * U);
        uint256 id = ee.createTask(address(usd), 100 * U);
        ee.pay(id, worker);
        vm.stopPrank();
        assertEq(usd.balanceOf(worker), 100 * U);
        assertEq(pp.owedOf(id, treasury), 0);
    }

    // ------------------------------------------------ cap and carry-over (called as the escrow)
    function test_cap_carries_repayment_to_next_payment() public {
        (SettlementDeductionPolicy pp, ExampleEscrow ee) = _deploy(schedule, 3000); // cap 30%
        vm.startPrank(creator);
        usd.approve(address(ee), 100 * U);
        uint256 id = ee.createTask(address(usd), 100 * U);
        vm.stopPrank();
        vm.prank(worker);
        pp.assignPayment(id, lender, 0, 50 * U);

        vm.startPrank(address(ee));
        assertEq(pp.deductions(id, 1, worker, 100 * U), 30 * U, "tax 1 + repay 29, capped");
        assertEq(pp.deductions(id, 2, worker, 100 * U), 22 * U, "tax 1 + repay the last 21");
        assertEq(pp.deductions(id, 3, worker, 100 * U), 1 * U, "loan done, tax only");
        vm.stopPrank();
        assertEq(pp.owedOf(id, lender), 50 * U);
        assertEq(pp.assignmentsOf(id, worker)[0].remaining, 0);
    }

    // ------------------------------------------------ withdrawal by anyone, accounting per task
    function test_claim_after_someone_else_withdrew_the_credit() public {
        uint256 id = _task(100 * U);
        vm.prank(worker);
        p.assignPayment(id, lender, 0, 30 * U);
        _pay(id);
        vm.prank(rando); // permissionless: the money goes to the policy anyway
        escrow.withdrawCredit(id, address(p));
        p.claim(id, treasury);
        p.claim(id, lender);
        assertEq(usd.balanceOf(treasury), 1 * U);
        assertEq(usd.balanceOf(lender), 30 * U);
        assertEq(usd.balanceOf(address(p)), 0);
    }

    function test_tasks_are_paid_from_their_own_credit() public {
        uint256 a = _task(100 * U);
        uint256 b = _task(200 * U);
        _pay(a);
        _pay(b);
        escrow.withdrawCredit(b, address(p)); // b's credit reaches the policy first
        p.claim(a, treasury);                 // a still pulls its own credit
        assertEq(escrow.creditOf(a, address(p)), 0);
        p.claim(b, treasury);
        assertEq(usd.balanceOf(treasury), 3 * U);
        assertEq(usd.balanceOf(address(p)), 0);
        vm.expectRevert("Deductions: nothing owed");
        p.claim(a, treasury);
    }

    // ------------------------------------------------ release and compaction
    function test_only_the_recipient_releases() public {
        uint256 id = _task(100 * U);
        vm.prank(worker);
        p.assignPayment(id, insurer, 200, 0);
        vm.prank(worker);
        vm.expectRevert("Deductions: nothing to release");
        p.release(id, worker);
        vm.prank(insurer);
        p.release(id, worker);
        _pay(id);
        assertEq(p.owedOf(id, insurer), 0, "released premium is not taken");
        assertEq(usd.balanceOf(worker), 99 * U);
    }

    function test_finished_assignments_free_their_slots_in_order() public {
        (SettlementDeductionPolicy pp, ExampleEscrow ee) = _deploy(ITaxSchedule(address(0)), 5000);
        vm.startPrank(creator);
        usd.approve(address(ee), 100 * U);
        uint256 id = ee.createTask(address(usd), 100 * U);
        vm.stopPrank();
        vm.startPrank(worker);
        pp.assignPayment(id, lender, 0, 1 * U);   // will be exhausted
        pp.assignPayment(id, insurer, 100, 0);    // stays
        pp.assignPayment(id, rando, 0, 100 * U);  // will be released
        pp.assignPayment(id, treasury, 0, 2 * U); // stays
        vm.stopPrank();
        vm.prank(address(ee));
        pp.deductions(id, 1, worker, 1 * U);       // cap 50%: the lender gets 0.5 of its 1
        vm.prank(address(ee));
        pp.deductions(id, 2, worker, 10 * U);      // lender finished
        assertEq(pp.assignmentsOf(id, worker)[0].remaining, 0);
        vm.prank(rando);
        pp.release(id, worker);
        vm.prank(worker);
        pp.assignPayment(id, creator, 0, 5 * U);   // fifth assignment fits after compaction
        ISettlementDeductionPolicy.Assignment[] memory list = pp.assignmentsOf(id, worker);
        assertEq(list.length, 3);
        assertEq(list[0].recipient, insurer);
        assertEq(list[1].recipient, treasury);
        assertEq(list[2].recipient, creator, "new assignment served last");
    }

    function test_claim_cannot_be_reentered_through_the_asset() public {
        CallbackUSD cb = new CallbackUSD();
        cb.mint(creator, 100 * U);
        vm.startPrank(creator);
        cb.approve(address(escrow), 100 * U);
        uint256 id = escrow.createTask(address(cb), 100 * U);
        escrow.pay(id, worker);
        vm.stopPrank();
        cb.arm(address(p), abi.encodeCall(p.claim, (id, treasury)));
        vm.expectRevert("Escrow: transfer failed"); // the inner claim hit the guard
        p.claim(id, treasury);
        cb.arm(address(0), "");
        p.claim(id, treasury);
        assertEq(cb.balanceOf(treasury), 1 * U, "paid once");
    }

    // ------------------------------------------------ refunds are never deducted
    function test_refund_not_deducted() public {
        uint256 id = _task(100 * U);
        vm.prank(creator);
        escrow.refund(id);
        assertEq(usd.balanceOf(creator), 10_000 * U);
        assertEq(p.owedOf(id, treasury), 0);
    }

    // ------------------------------------------------ assignments
    function test_only_the_payee_binds_its_own_payments() public {
        uint256 id = _task(100 * U);
        vm.prank(rando);
        p.assignPayment(id, lender, 0, 90 * U); // binds rando, not the worker
        _pay(id);
        assertEq(usd.balanceOf(worker), 99 * U);
        assertEq(p.owedOf(id, lender), 0);
    }

    function test_assignment_rules() public {
        vm.startPrank(worker);
        vm.expectRevert("Deductions: rate xor amount");
        p.assignPayment(0, lender, 0, 0);
        vm.expectRevert("Deductions: rate xor amount");
        p.assignPayment(0, lender, 100, 1);
        vm.expectRevert("Deductions: rate above cap");
        p.assignPayment(0, lender, 5001, 0);
        vm.expectRevert("Deductions: bad recipient");
        p.assignPayment(0, address(0), 100, 0);
        vm.expectRevert("Deductions: bad recipient");
        p.assignPayment(0, worker, 100, 0);
        for (uint256 i = 0; i < 4; i++) p.assignPayment(0, lender, 0, 1);
        vm.expectRevert("Deductions: too many assignments");
        p.assignPayment(0, lender, 0, 1);
        vm.stopPrank();
    }

    function test_hooks_only_from_escrow() public {
        vm.expectRevert("Deductions: not escrow");
        p.onTaskCreated(0, address(usd), 1);
        vm.expectRevert("Deductions: not escrow");
        p.deductions(0, 1, worker, 100);
    }

    // ------------------------------------------------ native coin
    function test_native_coin() public {
        vm.prank(creator);
        uint256 id = escrow.createTask{value: 1 ether}(address(0), 1 ether);
        _pay(id);
        assertEq(worker.balance, 0.99 ether);
        p.claim(id, treasury);
        assertEq(treasury.balance, 0.01 ether);
    }

    // ------------------------------------------------ escrow obligations (shown on ExampleEscrow)
    function _escrowWith(address policy) internal returns (ExampleEscrow ee, uint256 id) {
        ee = new ExampleEscrow(ISettlementDeductions(policy));
        vm.prank(creator);
        id = ee.createTask{value: 1 ether}(address(0), 1 ether);
    }

    function test_failing_policy_pays_in_full() public {
        (ExampleEscrow ee, uint256 id) = _escrowWith(address(new RevertingPolicy()));
        vm.prank(creator);
        ee.pay(id, worker);
        assertEq(worker.balance, 1 ether);
    }

    function test_invalid_answer_pays_in_full() public {
        (ExampleEscrow ee, uint256 id) = _escrowWith(address(new GreedyPolicy()));
        vm.prank(creator);
        ee.pay(id, worker);
        assertEq(worker.balance, 1 ether);
    }

    function test_starving_the_policy_reverts() public {
        uint256 id = _task(100 * U);
        vm.prank(worker);
        p.assignPayment(id, lender, 0, 30 * U);
        vm.prank(creator);
        (bool ok, ) = address(escrow).call{gas: 150_000}(abi.encodeCall(escrow.pay, (id, worker)));
        assertFalse(ok, "must not pay without the deductions");
        _pay(id);
        assertEq(p.owedOf(id, lender), 30 * U);
    }

    function test_large_return_data_costs_the_payout_nothing() public {
        (ExampleEscrow ee, uint256 id) = _escrowWith(address(new LoudPolicy()));
        vm.prank(creator);
        (bool ok, ) = address(ee).call{gas: 400_000}(abi.encodeCall(ee.pay, (id, worker)));
        assertTrue(ok, "only 32 bytes are copied back");
        assertEq(worker.balance, 1 ether);
    }

    function test_no_gas_value_pays_without_the_deductions() public {
        uint256 id = _task(100 * U);
        vm.prank(worker);
        p.assignPayment(id, lender, 0, 30 * U);
        // Find the smallest gas limit that settles, then try every single gas value around it.
        uint256 lo = 100_000;
        uint256 hi = 1_000_000;
        assertTrue(_payWith(id, hi), "a large budget settles");
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_payWith(id, mid)) hi = mid; else lo = mid;
        }
        for (uint256 g = hi - 1_000; g <= hi + 1_000; g++) _payWith(id, g);
    }

    /// Pays with exactly `g` gas, checks a successful payout took the deductions, and rolls back.
    function _payWith(uint256 id, uint256 g) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        vm.prank(creator);
        (ok, ) = address(escrow).call{gas: g}(abi.encodeCall(escrow.pay, (id, worker)));
        if (ok) assertEq(p.owedOf(id, lender), 30 * U, "paid, so the lender must be in");
        vm.revertToState(snap);
    }

    // ------------------------------------------------ escrow events
    function test_escrow_events() public {
        uint256 id = _task(100 * U);
        vm.expectEmit(address(escrow));
        emit ISettlementCredit.SettlementDeducted(id, 1, address(p), 1 * U);
        _pay(id);

        (ExampleEscrow ee, uint256 id2) = _escrowWith(address(new RevertingPolicy()));
        vm.expectEmit(address(ee));
        emit ISettlementCredit.DeductionsSkipped(id2, 1);
        vm.prank(creator);
        ee.pay(id2, worker);
    }

    function test_tax_to_zero_treasury_blocks_creation() public {
        schedule.set(address(0), 100);
        vm.startPrank(creator);
        usd.approve(address(escrow), 1 * U);
        vm.expectRevert("Deductions: tax to zero");
        escrow.createTask(address(usd), 1 * U);
        vm.stopPrank();
    }
}
