// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {SettlementDeductionPolicy} from "../src/SettlementDeductionPolicy.sol";
import {ExampleEscrow} from "../src/examples/ExampleEscrow.sol";
import {USD, Schedule} from "./SettlementDeductionPolicy.t.sol";
import {BlockingUSD} from "./Hardening.t.sol";

/// Drives an escrow and its policy through random sequences of everything any party can
/// do: create, assign, pay in parts, refund, withdraw credit as a stranger, claim, release,
/// and change the tax rate. Keeps ghost totals to check against.
contract Handler is Test {
    USD public usd;
    Schedule public schedule;
    SettlementDeductionPolicy public p;
    ExampleEscrow public e;

    uint16 public constant CAP = 3000;
    address public constant CREATOR = address(0xC4EA);
    address public constant TREASURY = address(0x7EA5);
    address[3] public workers = [address(0xA1), address(0xA2), address(0xA3)];
    address[3] public recipients = [address(0xB1), address(0xB2), address(0xB3)];

    uint256[] public tasks;
    mapping(uint256 => uint256) public remaining;      // ghost: still escrowed per task
    mapping(uint256 => address) public payeeOf;        // fixed at creation
    mapping(uint256 => uint256) public deductedOn;     // ghost: credited to the policy per task
    mapping(uint256 => uint256) public claimedOn;      // ghost: paid out on claims per task
    uint256 public minted;
    uint256 public payouts;
    uint256 public claims;
    uint256 public compactions;
    uint256 public releases;
    uint256 public strangerWithdrawals;
    uint256 public payeeCredits;      // payouts that were credited because the payee was blocked
    uint256 public payeeWithdrawals;

    constructor() {
        usd = USD(address(new BlockingUSD()));
        schedule = new Schedule();
        schedule.set(TREASURY, 100);
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        p = new SettlementDeductionPolicy(next, schedule, CAP);
        e = new ExampleEscrow(p);
        require(address(e) == next, "deploy order");
    }

    function _taskAt(uint256 seed) internal view returns (bool ok, uint256 id) {
        if (tasks.length == 0) return (false, 0);
        return (true, tasks[seed % tasks.length]);
    }

    /// Few tasks, so that actions pile up on the same ones.
    uint256 public constant MAX_TASKS = 2;

    function create(uint256 amount, uint256 w) external {
        if (tasks.length == MAX_TASKS) return;
        amount = bound(amount, 1, 1e12);
        address payee = workers[w % 3];
        usd.mint(CREATOR, amount);
        minted += amount;
        vm.startPrank(CREATOR);
        usd.approve(address(e), amount);
        uint256 id = e.createTask(address(usd), amount, payee);
        vm.stopPrank();
        tasks.push(id);
        remaining[id] = amount;
        payeeOf[id] = payee;
    }

    /// Assignments are the subtle part (order, cap, compaction), so they get extra weight.
    function assignAgain(uint256 taskSeed, uint256 w, uint256 r, uint16 bps, uint256 amount, bool isRate) external {
        assign(taskSeed, w, r, bps, amount, isRate);
    }

    function assign(uint256 taskSeed, uint256 w, uint256 r, uint16 bps, uint256 amount, bool isRate) public {
        (bool ok, uint256 id) = _taskAt(taskSeed);
        if (!ok) return;
        // Mostly on the task's own payee, whose payouts actually read them.
        address payee = w % 4 == 3 ? workers[w % 3] : payeeOf[id];
        SettlementDeductionPolicy.Assignment[] memory before = p.assignmentsOf(id, payee);
        bool full = before.length == p.MAX_ASSIGNMENTS();
        uint256 active;
        for (uint256 k = 0; k < before.length; k++) if (_active(before[k])) active++;
        if (full && active == before.length) return; // would revert: no finished entry to drop
        address rec = recipients[r % 3];
        uint16 b = isRate ? uint16(bound(bps, 1, CAP)) : 0;
        uint256 a = isRate ? 0 : bound(amount, 1, 1e10); // small sums, so that many are repaid
        vm.prank(payee);
        p.assignPayment(id, rec, b, a);
        if (full) compactions++;

        // Expected: the old list (only its active entries, in order, if it was full), then the new one.
        SettlementDeductionPolicy.Assignment[] memory got = p.assignmentsOf(id, payee);
        uint256 n;
        for (uint256 k = 0; k < before.length; k++) {
            if (full && !_active(before[k])) continue;
            _assertSame(got[n++], before[k]);
        }
        assertEq(got.length, n + 1, "one entry appended");
        assertEq(got[n].recipient, rec);
        assertEq(got[n].bps, b);
        assertEq(got[n].remaining, a);
    }

    function _active(SettlementDeductionPolicy.Assignment memory x) internal pure returns (bool) {
        return x.bps > 0 || x.remaining > 0;
    }

    function _assertSame(SettlementDeductionPolicy.Assignment memory x, SettlementDeductionPolicy.Assignment memory y)
        internal pure
    {
        assertEq(x.recipient, y.recipient, "order kept");
        assertEq(x.bps, y.bps, "rate kept");
        assertEq(x.remaining, y.remaining, "remaining kept");
    }

    function pay(uint256 taskSeed, uint256 amount) external {
        (bool ok, uint256 id) = _taskAt(taskSeed);
        if (!ok || remaining[id] == 0) return;
        amount = bound(amount, 1, remaining[id]);
        address payee = payeeOf[id];
        uint256 before = usd.balanceOf(payee);
        uint256 creditBefore = e.creditOf(id, address(p));
        uint256 payeeCreditBefore = e.creditOf(id, payee);
        vm.prank(CREATOR);
        vm.startStateDiffRecording();
        e.payPart(id, amount);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        for (uint256 i = 0; i < acc.length; i++) {
            Vm.StorageAccess[] memory s = acc[i].storageAccesses;
            for (uint256 j = 0; j < s.length; j++) {
                if (s[j].account != address(p) || !s[j].isWrite || s[j].reverted) continue;
                assertTrue(s[j].previousValue != bytes32(0), "a payout wrote a slot that was zero");
            }
        }
        uint256 got = usd.balanceOf(payee) - before;
        uint256 d = e.creditOf(id, address(p)) - creditBefore;
        uint256 credited = e.creditOf(id, payee) - payeeCreditBefore;
        assertEq(got + credited + d, amount, "payout split exactly");
        assertTrue(got == 0 || credited == 0, "paid or credited, not both");
        if (credited > 0) payeeCredits++;
        assertLe(d, amount * CAP / 10_000, "cap");
        remaining[id] -= amount;
        deductedOn[id] += d;
        payouts++;
    }

    function refund(uint256 taskSeed) external {
        (bool ok, uint256 id) = _taskAt(taskSeed);
        if (!ok || remaining[id] == 0) return;
        uint256 before = usd.balanceOf(CREATOR);
        uint256 creditBefore = e.creditOf(id, address(p));
        vm.prank(CREATOR);
        e.refund(id);
        assertEq(usd.balanceOf(CREATOR) - before, remaining[id], "refund whole");
        assertEq(e.creditOf(id, address(p)), creditBefore, "refund not deducted");
        remaining[id] = 0;
    }

    function strangerWithdraws(uint256 taskSeed) external {
        (bool ok, uint256 id) = _taskAt(taskSeed);
        if (!ok || e.creditOf(id, address(p)) == 0) return;
        vm.prank(address(0xBAD));
        e.withdrawCredit(id, address(p));
        strangerWithdrawals++;
    }

    function claim(uint256 taskSeed, uint256 r) external {
        (bool ok, uint256 id) = _taskAt(taskSeed);
        if (!ok) return;
        address to = r % 4 == 3 ? TREASURY : recipients[r % 4];
        uint256 owed = p.owedOf(id, to);
        if (owed == 0) return;
        uint256 before = usd.balanceOf(to);
        p.claim(id, to); // must never fail when something is owed
        assertEq(usd.balanceOf(to) - before, owed, "claim pays exactly what is owed");
        claimedOn[id] += owed;
        claims++;
    }

    function release(uint256 taskSeed, uint256 w, uint256 r) external {
        (bool ok, uint256 id) = _taskAt(taskSeed);
        if (!ok) return;
        address payee = workers[w % 3];
        address rec = recipients[r % 3];
        SettlementDeductionPolicy.Assignment[] memory list = p.assignmentsOf(id, payee);
        bool active;
        for (uint256 k = 0; k < list.length; k++) {
            if (list[k].recipient == rec && (list[k].bps > 0 || list[k].remaining > 0)) active = true;
        }
        if (!active) return;
        vm.prank(rec);
        p.release(id, payee);
        SettlementDeductionPolicy.Assignment[] memory got = p.assignmentsOf(id, payee);
        assertEq(got.length, list.length, "release removes nothing");
        for (uint256 k = 0; k < list.length; k++) {
            if (list[k].recipient == rec) assertFalse(_active(got[k]), "released");
            else _assertSame(got[k], list[k]);
        }
        releases++;
    }

    /// The asset's issuer blocks or unblocks a payee: payouts to it are then credited.
    function blockPayee(uint256 w, bool on) external {
        BlockingUSD(address(usd)).setBlocked(workers[w % 3], on);
    }

    /// A payee (or anyone for it) withdraws payout credit once it can receive again.
    function payeeWithdraws(uint256 taskSeed) external {
        (bool ok, uint256 id) = _taskAt(taskSeed);
        if (!ok) return;
        address payee = payeeOf[id];
        uint256 c = e.creditOf(id, payee);
        if (c == 0 || BlockingUSD(address(usd)).blocked(payee)) return;
        uint256 before = usd.balanceOf(payee);
        e.withdrawCredit(id, payee);
        assertEq(usd.balanceOf(payee) - before, c, "credit withdrawn whole");
        payeeWithdrawals++;
    }

    function setTax(uint16 bps) external {
        schedule.set(TREASURY, uint16(bound(bps, 0, CAP)));
    }

    function tasksLength() external view returns (uint256) {
        return tasks.length;
    }

    function holders() external view returns (address[] memory h) {
        h = new address[](10);
        h[0] = CREATOR; h[1] = TREASURY; h[2] = address(e); h[3] = address(p); h[4] = address(0xBAD);
        for (uint256 i = 0; i < 3; i++) { h[5 + i] = workers[i]; }
        h[8] = recipients[0];
        h[9] = recipients[1];
    }
}

contract InvariantsTest is Test {
    Handler h;

    function setUp() public {
        h = new Handler();
        targetContract(address(h));
    }

    /// The escrow holds exactly what is still escrowed plus what is credited to the policy.
    function invariant_escrow_is_solvent() public view {
        uint256 owed;
        for (uint256 i = 0; i < h.tasksLength(); i++) {
            uint256 id = h.tasks(i);
            owed += h.remaining(id) + h.e().creditOf(id, address(h.p())) + h.e().creditOf(id, h.payeeOf(id));
        }
        assertEq(h.usd().balanceOf(address(h.e())), owed);
    }

    /// Per task: everything deducted is either still credited, owed, or already claimed;
    /// and the policy never paid out more for a task than has left the escrow for it.
    function invariant_per_task_accounting() public view {
        address[4] memory rs = [h.recipients(0), h.recipients(1), h.recipients(2), h.TREASURY()];
        uint256 held;
        for (uint256 i = 0; i < h.tasksLength(); i++) {
            uint256 id = h.tasks(i);
            uint256 owed;
            for (uint256 k = 0; k < 4; k++) owed += h.p().owedOf(id, rs[k]);
            assertEq(owed + h.claimedOn(id), h.deductedOn(id), "deducted = owed + claimed");
            uint256 credit = h.e().creditOf(id, address(h.p()));
            assertLe(h.claimedOn(id), h.deductedOn(id) - credit, "paid only what left the escrow");
            held += h.deductedOn(id) - credit - h.claimedOn(id);
        }
        assertEq(h.usd().balanceOf(address(h.p())), held, "policy holds exactly the withdrawn, unclaimed amounts");
    }

    /// No token is created or destroyed anywhere.
    function invariant_tokens_conserved() public view {
        address[] memory hs = h.holders();
        uint256 sum;
        for (uint256 i = 0; i < hs.length; i++) sum += h.usd().balanceOf(hs[i]);
        sum += h.usd().balanceOf(h.recipients(2));
        assertEq(sum, h.minted());
    }
}
