// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {SettlementDeductionPolicy} from "../src/SettlementDeductionPolicy.sol";
import {ISettlementDeductions, ISettlementCredit} from "../src/interfaces/ISettlementDeductions.sol";
import {ISettlementDeductionPolicy} from "../src/interfaces/ISettlementDeductionPolicy.sol";
import {ITaxSchedule} from "../src/interfaces/ITaxSchedule.sol";
import {ExampleEscrow} from "../src/examples/ExampleEscrow.sol";
import {USD, Schedule} from "./SettlementDeductionPolicy.t.sol";

/// Answers with no return data.
contract MutePolicy {
    function onTaskCreated(uint256, address, uint256) external {}
    function deductions(uint256, uint256, address, uint256) external {}
}

/// Answers with two words.
contract TwoWordPolicy {
    function onTaskCreated(uint256, address, uint256) external {}
    function deductions(uint256, uint256, address, uint256) external pure returns (uint256, uint256) {
        return (1, 1);
    }
}

/// Burns its whole gas budget.
contract GasHogPolicy {
    function onTaskCreated(uint256, address, uint256) external {}
    function deductions(uint256, uint256, address, uint256) external pure returns (uint256) {
        while (true) {}
        return 0;
    }
}

/// One test per normative rule that the main suite does not already pin down.
contract SpecCoverageTest is Test {
    USD usd;
    Schedule schedule;

    address creator  = address(0xC4EA);
    address worker   = address(0xCAFE);
    address treasury = address(0x7EA5);
    address referrer = address(0x1A5);
    address lender   = address(0x10A1);
    address rando    = address(0xBAD);
    uint256 constant U = 1e6;

    function setUp() public {
        usd = new USD();
        schedule = new Schedule();
        schedule.set(treasury, 100); // 1%
        usd.mint(creator, 1_000_000 * U);
        vm.deal(creator, 100 ether);
    }

    function _deploy(ITaxSchedule s, uint16 cap) internal returns (SettlementDeductionPolicy p, ExampleEscrow e) {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        p = new SettlementDeductionPolicy(next, s, cap);
        e = new ExampleEscrow(p);
        assertEq(address(e), next);
    }

    function _task(ExampleEscrow e, uint256 amount) internal returns (uint256 id) {
        vm.startPrank(creator);
        usd.approve(address(e), amount);
        id = e.createTask(address(usd), amount, worker);
        vm.stopPrank();
    }

    function _skipped(Vm.Log[] memory logs) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == ISettlementCredit.DeductionsSkipped.selector) return true;
        }
        return false;
    }

    // ------------------------------------------------------------ construction
    /// try/catch rather than expectRevert: with dynamic test linking, an expected revert
    /// in a `new` ends the test early and skips the checks after it.
    function _refused(address escrow_, uint16 cap, string memory why) internal {
        try new SettlementDeductionPolicy(escrow_, schedule, cap) returns (SettlementDeductionPolicy) {
            assertTrue(false, string.concat("deployed, expected: ", why));
        } catch Error(string memory got) {
            assertEq(got, why);
        }
    }

    function test_constructor_rejects_zero_escrow_and_cap_above_100() public {
        _refused(address(0), 100, "Deductions: zero escrow");
        _refused(address(1), 10_001, "Deductions: cap above 100%");
        SettlementDeductionPolicy p = new SettlementDeductionPolicy(address(1), schedule, 10_000);
        assertEq(p.escrow(), address(1));
        assertEq(address(p.taxSchedule()), address(schedule));
        assertEq(p.maxDeductionBps(), 10_000);
    }

    // ------------------------------------------------------------ section 5: escrow
    function test_answers_of_the_wrong_length_are_invalid() public {
        address[2] memory policies = [address(new MutePolicy()), address(new TwoWordPolicy())];
        for (uint256 i = 0; i < 2; i++) {
            ExampleEscrow e = new ExampleEscrow(ISettlementDeductions(policies[i]));
            uint256 id = _task(e, 100 * U);
            uint256 before = usd.balanceOf(worker);
            vm.expectEmit(address(e));
            emit ISettlementCredit.DeductionsSkipped(id, 1);
            vm.prank(creator);
            e.pay(id);
            assertEq(usd.balanceOf(worker) - before, 100 * U);
        }
    }

    function test_a_policy_that_burns_its_budget_is_skipped() public {
        ExampleEscrow e = new ExampleEscrow(ISettlementDeductions(address(new GasHogPolicy())));
        uint256 id = _task(e, 100 * U);
        vm.expectEmit(address(e));
        emit ISettlementCredit.DeductionsSkipped(id, 1);
        vm.prank(creator);
        e.pay{gas: 1_000_000}(id);
        assertEq(usd.balanceOf(worker), 100 * U);
    }

    function test_withdraw_credit_rules() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(schedule, 5000);
        uint256 id = _task(e, 100 * U);
        vm.expectRevert("Escrow: nothing credited");
        e.withdrawCredit(id, address(p));
        vm.prank(creator);
        e.pay(id);
        vm.prank(rando);
        e.withdrawCredit(id, address(p)); // anyone; pays only the account
        assertEq(usd.balanceOf(address(p)), 1 * U);
        assertEq(usd.balanceOf(rando), 0);
        assertEq(e.creditOf(id, address(p)), 0);
        vm.expectRevert("Escrow: nothing credited");
        e.withdrawCredit(id, address(p));
    }

    function test_every_partial_payout_is_asked_and_the_refund_is_not() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(schedule, 3000);
        uint256 id = _task(e, 300 * U);
        vm.prank(worker);
        p.assignPayment(id, lender, 0, 50 * U);
        vm.startPrank(creator);
        vm.expectEmit(address(p));
        emit ISettlementDeductionPolicy.Deducted(id, 1, treasury, 1 * U);
        e.payPart(id, 100 * U); // tax 1 + repay 29
        vm.expectEmit(address(p));
        emit ISettlementDeductionPolicy.Deducted(id, 2, treasury, 1 * U);
        e.payPart(id, 100 * U); // tax 1 + repay 21
        uint256 before = usd.balanceOf(creator);
        e.refund(id);                   // the last 100 comes back whole
        vm.stopPrank();
        assertEq(usd.balanceOf(creator) - before, 100 * U);
        assertEq(usd.balanceOf(worker), 70 * U + 78 * U);
        assertEq(p.owedOf(id, lender), 50 * U);
        assertEq(p.owedOf(id, treasury), 2 * U);
    }

    // ------------------------------------------------------------ section 6: policy
    function test_deductions_touch_no_other_contract() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(schedule, 5000);
        uint256 id = _task(e, 100 * U);
        vm.startPrank(worker);
        p.assignPayment(id, referrer, 200, 0);
        p.assignPayment(id, lender, 0, 30 * U);
        vm.stopPrank();
        vm.startStateDiffRecording();
        vm.prank(address(e));
        p.deductions(id, 1, worker, 100 * U);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertGt(accesses.length, 0);
        for (uint256 i = 0; i < accesses.length; i++) {
            if (accesses[i].account == address(vm)) continue; // the prank itself
            assertEq(accesses[i].account, address(p), "deductions called out");
        }
    }

    function test_worst_case_fits_the_example_budget() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(schedule, 10_000);
        uint256 id = _task(e, 100 * U);
        vm.startPrank(worker);
        for (uint160 i = 1; i <= 4; i++) p.assignPayment(id, address(0x5000 + i), 0, 10 * U);
        vm.stopPrank();
        vm.cool(address(p)); // measure with cold storage, as in a fresh transaction
        vm.prank(address(e));
        uint256 g = gasleft();
        p.deductions(id, 1, worker, 100 * U);
        g -= gasleft();
        emit log_named_uint("worst-case deductions gas", g);
        assertLt(g, e.DEDUCTION_GAS(), "worst case must fit G");
    }

    /// The payee is fixed when the task is created: the escrow has no way to pay anyone else,
    /// so the payee's assignments cannot be skipped.
    function test_the_payee_is_fixed_before_the_payout() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(schedule, 5000);
        vm.startPrank(creator);
        usd.approve(address(e), 100 * U);
        vm.expectRevert("Escrow: bad payee");
        e.createTask(address(usd), 100 * U, address(0));
        vm.stopPrank();
        uint256 id = _task(e, 100 * U);
        vm.prank(worker);
        p.assignPayment(id, lender, 0, 30 * U);
        vm.prank(creator);
        e.pay(id);
        assertEq(usd.balanceOf(worker), 69 * U, "the fixed payee, minus tax and repayment");
        assertEq(p.owedOf(id, lender), 30 * U);
    }

    /// A token address without code returns nothing from a call, which must not count as a
    /// transfer: neither when funding a task nor when the policy pays a recipient.
    function test_an_asset_without_code_is_not_a_transfer() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(schedule, 5000);
        vm.prank(creator);
        vm.expectRevert("Escrow: transfer failed");
        e.createTask(address(0xDEAD), 100 * U, worker);

        uint256 id = _task(e, 100 * U);
        vm.prank(creator);
        e.pay(id);
        e.withdrawCredit(id, address(p)); // the tax reaches the policy
        vm.etch(address(usd), "");       // the token's code is gone
        vm.expectRevert("Deductions: transfer failed");
        p.claim(id, treasury);
        assertEq(p.owedOf(id, treasury), 1 * U, "still owed");
    }

    /// No payout creates storage in the policy: every slot `deductions` writes was allocated
    /// at task creation or assignment, and stays allocated after claims. Covers the first
    /// payout, later payouts, payouts after every recipient has claimed, and an assignment
    /// running out.
    function test_deductions_create_no_storage() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(schedule, 10_000);
        uint256 id = _task(e, 400 * U);
        address[4] memory rs = [address(0x5001), address(0x5002), address(0x5003), address(0x5004)];
        vm.startPrank(worker);
        p.assignPayment(id, rs[0], 300, 0);       // a rate
        p.assignPayment(id, rs[1], 0, 5 * U);     // runs out on the first payout
        p.assignPayment(id, rs[2], 0, 15 * U);
        p.assignPayment(id, rs[3], 0, 1_000 * U);
        vm.stopPrank();
        vm.prank(rs[2]);
        p.release(id, worker); // a released assignment is written no more either
        for (uint256 k = 0; k < 4; k++) {
            _payWithoutCreating(p, e, id, 100 * U);
            if (k == 1) {
                p.claim(id, treasury);
                for (uint256 i = 0; i < 4; i++) if (p.owedOf(id, rs[i]) > 0) p.claim(id, rs[i]);
            }
        }
        assertEq(p.owedOf(id, rs[1]), 0);
        assertGt(p.owedOf(id, rs[3]), 0);
    }

    function _payWithoutCreating(SettlementDeductionPolicy p, ExampleEscrow e, uint256 id, uint256 amount) internal {
        vm.startStateDiffRecording();
        vm.prank(creator);
        e.payPart(id, amount);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        uint256 writes;
        for (uint256 i = 0; i < accesses.length; i++) {
            Vm.StorageAccess[] memory s = accesses[i].storageAccesses;
            for (uint256 j = 0; j < s.length; j++) {
                if (s[j].account != address(p) || !s[j].isWrite || s[j].reverted) continue;
                writes++;
                assertTrue(s[j].previousValue != bytes32(0), "payout wrote a slot that was zero");
            }
        }
        assertGt(writes, 0, "the policy did record the payout");
    }

    /// The paths most likely to need a new slot: an assignment made before the task exists,
    /// the treasury also an assignee, the same recipient twice and on another payee's task,
    /// release, compaction and reassignment, claims in between.
    function test_no_storage_is_created_on_the_edge_paths() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(schedule, 10_000);
        address worker2 = address(0xCAF2);
        vm.prank(worker);
        p.assignPayment(0, lender, 0, 7 * U); // task 0 does not exist yet
        uint256 id = _task(e, 1_000 * U);
        assertEq(id, 0);
        vm.startPrank(creator);
        usd.approve(address(e), 1_000 * U);
        uint256 id2 = e.createTask(address(usd), 1_000 * U, worker2);
        vm.stopPrank();
        vm.startPrank(worker);
        p.assignPayment(id, treasury, 100, 0);
        p.assignPayment(id, referrer, 0, 3 * U);
        p.assignPayment(id, referrer, 50, 0);
        vm.stopPrank();
        vm.prank(worker2);
        p.assignPayment(id2, lender, 0, 2 * U);
        _payWithoutCreating(p, e, id, 100 * U);
        _payWithoutCreating(p, e, id2, 100 * U);
        p.claim(id, lender);
        p.claim(id, treasury);
        p.claim(id, referrer);
        p.claim(id2, lender);
        vm.prank(referrer);
        p.release(id, worker);
        vm.prank(worker);
        p.assignPayment(id, address(0xA55), 0, 1_000 * U); // compacts the full list
        assertEq(p.assignmentsOf(id, worker).length, 2);
        for (uint256 k = 0; k < 4; k++) {
            _payWithoutCreating(p, e, id, 100 * U);
            if (k == 1) {
                p.claim(id, treasury);
                p.claim(id, address(0xA55));
            }
        }
    }

    /// A task the escrow never announced is refused: the payout settles in full with
    /// DeductionsSkipped, instead of the policy creating storage and miscounting the task.
    function test_a_task_never_announced_is_refused() public {
        SettlementDeductionPolicy p = new SettlementDeductionPolicy(address(this), ITaxSchedule(address(0)), 5000);
        vm.prank(worker);
        p.assignPayment(42, lender, 0, 30 * U);
        vm.expectRevert("Deductions: unknown task");
        p.deductions(42, 1, worker, 100 * U);
    }

    /// A policy whose code is gone cannot answer: the payout settles in full and says so.
    function test_a_policy_without_code_is_skipped() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(schedule, 5000);
        uint256 id = _task(e, 100 * U);
        vm.etch(address(p), "");
        vm.expectEmit(address(e));
        emit ISettlementCredit.DeductionsSkipped(id, 1);
        vm.prank(creator);
        e.pay(id);
        assertEq(usd.balanceOf(worker), 100 * U);
    }

    // ------------------------------------------------------------ section 7: profile
    function test_zero_rate_locks_nothing() public {
        schedule.set(treasury, 0);
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(schedule, 5000);
        vm.recordLogs();
        uint256 id = _task(e, 100 * U);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != ISettlementDeductionPolicy.TaxLocked.selector);
        }
        (address t, uint16 bps) = p.lockedTaxOf(id);
        assertEq(t, address(0));
        assertEq(bps, 0);
    }

    function test_tax_comes_first_then_assignments_in_order_within_the_cap() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(schedule, 1000); // cap 10%
        uint256 id = _task(e, 200 * U);
        vm.startPrank(worker);
        p.assignPayment(id, referrer, 500, 0);  // 5%, made first
        p.assignPayment(id, lender, 0, 50 * U); // made second
        vm.stopPrank();
        vm.startPrank(creator);
        e.payPart(id, 100 * U); // budget 10: tax 1, fee 5, repay 4
        assertEq(p.owedOf(id, treasury), 1 * U);
        assertEq(p.owedOf(id, referrer), 5 * U);
        assertEq(p.owedOf(id, lender), 4 * U);
        e.payPart(id, 100 * U); // the same again; 42 still to repay
        vm.stopPrank();
        assertEq(p.owedOf(id, lender), 8 * U);
        assertEq(p.assignmentsOf(id, worker)[1].remaining, 42 * U);
    }

    function test_rounding_down_can_mean_no_deduction_at_all() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(schedule, 5000);
        uint256 id = _task(e, 99); // 1% of 99 rounds to 0
        vm.recordLogs();
        vm.prank(creator);
        e.pay(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != ISettlementCredit.SettlementDeducted.selector);
            assertTrue(logs[i].topics[0] != ISettlementDeductionPolicy.Deducted.selector);
        }
        assertFalse(_skipped(logs));
        assertEq(usd.balanceOf(worker), 99);
        assertEq(e.creditOf(id, address(p)), 0);
    }

    function test_cap_zero_means_nothing_is_ever_taken() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(ITaxSchedule(address(0)), 0);
        uint256 id = _task(e, 100 * U);
        vm.startPrank(worker);
        vm.expectRevert("Deductions: rate above cap");
        p.assignPayment(id, referrer, 1, 0);
        p.assignPayment(id, lender, 0, 30 * U); // accepted, but the cap leaves no room
        vm.stopPrank();
        vm.prank(creator);
        e.pay(id);
        assertEq(usd.balanceOf(worker), 100 * U);
        assertEq(p.owedOf(id, lender), 0);
    }

    function test_cap_100_can_take_the_whole_payout() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(ITaxSchedule(address(0)), 10_000);
        uint256 id = _task(e, 100 * U);
        vm.prank(worker);
        p.assignPayment(id, lender, 0, 100 * U);
        vm.prank(creator);
        e.pay(id);
        assertEq(usd.balanceOf(worker), 0);
        p.claim(id, lender);
        assertEq(usd.balanceOf(lender), 100 * U);
    }

    function test_release_touches_only_the_callers_assignments() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(schedule, 5000);
        uint256 id = _task(e, 100 * U);
        vm.startPrank(worker);
        p.assignPayment(id, referrer, 200, 0);
        p.assignPayment(id, lender, 0, 30 * U);
        p.assignPayment(id, referrer, 0, 5 * U);
        vm.stopPrank();
        vm.expectEmit(address(p));
        emit ISettlementDeductionPolicy.PaymentReleased(id, worker, referrer);
        vm.prank(referrer);
        p.release(id, worker); // both of the referrer's, none of the lender's
        vm.prank(referrer);
        vm.expectRevert("Deductions: nothing to release");
        p.release(id, worker);
        vm.prank(creator);
        e.pay(id);
        assertEq(p.owedOf(id, referrer), 0);
        assertEq(p.owedOf(id, lender), 30 * U);
    }

    function test_claim_with_nothing_owed_reverts() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(schedule, 5000);
        uint256 id = _task(e, 100 * U);
        vm.expectRevert("Deductions: nothing owed");
        p.claim(id, treasury);
        vm.prank(creator);
        e.pay(id);
        p.claim(id, treasury);
        vm.expectRevert("Deductions: nothing owed");
        p.claim(id, treasury);
    }

    function test_native_coin_withdrawn_by_a_third_party() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(schedule, 5000);
        vm.prank(creator);
        uint256 id = e.createTask{value: 10 ether}(address(0), 10 ether, worker);
        vm.prank(worker);
        p.assignPayment(id, lender, 0, 3 ether);
        vm.prank(creator);
        e.pay(id);
        vm.prank(rando);
        e.withdrawCredit(id, address(p));
        p.claim(id, lender);
        p.claim(id, treasury);
        assertEq(worker.balance, 6.9 ether);
        assertEq(lender.balance, 3 ether);
        assertEq(treasury.balance, 0.1 ether);
        assertEq(address(p).balance, 0);
    }

    // ------------------------------------------------------------ fuzz
    /// The policy alone, called by this test as its escrow.
    function testFuzz_deductions_respect_tax_order_and_cap(
        uint256 amount, uint16 cap, uint16 tax, uint16 rate, uint256 sum
    ) public {
        amount = bound(amount, 0, 1e30);
        cap = uint16(bound(cap, 0, 10_000));
        tax = uint16(bound(tax, 0, cap));
        rate = uint16(bound(rate, 1, 10_000));
        sum = bound(sum, 1, 1e30);
        schedule.set(treasury, tax);
        SettlementDeductionPolicy p = new SettlementDeductionPolicy(address(this), schedule, cap);
        p.onTaskCreated(1, address(usd), amount);
        vm.startPrank(worker);
        if (rate <= cap) p.assignPayment(1, referrer, rate, 0);
        p.assignPayment(1, lender, 0, sum);
        vm.stopPrank();

        uint256 total = p.deductions(1, 1, worker, amount);

        uint256 budget = amount * cap / 10_000;
        uint256 taxed = tax == 0 ? 0 : amount * tax / 10_000;
        assertLe(total, budget, "within the cap");
        assertLe(total, amount, "never more than the payout");
        assertEq(p.owedOf(1, treasury), taxed, "tax exact and first");
        uint256 fee = p.owedOf(1, referrer);
        uint256 repaid = p.owedOf(1, lender);
        assertEq(taxed + fee + repaid, total, "total is the sum of shares");
        if (rate <= cap) {
            uint256 want = amount * rate / 10_000;
            assertEq(fee, want < budget - taxed ? want : budget - taxed, "fee before repayment");
        }
        assertEq(repaid, _min(sum, budget - taxed - fee), "repayment takes what is left");
        assertEq(p.assignmentsOf(1, worker)[rate <= cap ? 1 : 0].remaining, sum - repaid, "carry-over kept");
    }

    /// Through the escrow: the payee gets exactly the payout minus what is credited.
    function testFuzz_payout_is_conserved(uint256 amount, uint16 rate, uint256 sum, uint256 parts) public {
        amount = bound(amount, 1, 1e24);
        rate = uint16(bound(rate, 1, 5000));
        sum = bound(sum, 1, 1e24);
        parts = bound(parts, 1, 5);
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy(schedule, 5000);
        usd.mint(creator, amount);
        uint256 id = _task(e, amount);
        vm.startPrank(worker);
        p.assignPayment(id, referrer, rate, 0);
        p.assignPayment(id, lender, 0, sum);
        vm.stopPrank();
        uint256 paid;
        vm.startPrank(creator);
        for (uint256 k = 0; k < parts; k++) {
            uint256 part = k + 1 == parts ? amount - paid : amount / parts;
            if (part == 0) continue;
            e.payPart(id, part);
            paid += part;
        }
        vm.stopPrank();
        uint256 credited = e.creditOf(id, address(p));
        assertEq(usd.balanceOf(worker) + credited, amount, "nothing created or lost");
        assertLe(credited, amount / 2, "cap holds across payouts");
        assertEq(p.owedOf(id, treasury) + p.owedOf(id, referrer) + p.owedOf(id, lender), credited);
        if (p.owedOf(id, treasury) > 0) p.claim(id, treasury);
        if (p.owedOf(id, referrer) > 0) p.claim(id, referrer);
        if (p.owedOf(id, lender) > 0) p.claim(id, lender);
        assertEq(usd.balanceOf(address(p)), 0, "policy keeps nothing");
        assertEq(usd.balanceOf(address(e)), 0, "escrow keeps nothing");
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
