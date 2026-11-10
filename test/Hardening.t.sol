// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SettlementDeductionPolicy} from "../src/SettlementDeductionPolicy.sol";
import {ISettlementDeductions, ISettlementCredit} from "../src/interfaces/ISettlementDeductions.sol";
import {ISettlementDeductionPolicy} from "../src/interfaces/ISettlementDeductionPolicy.sol";
import {ITaxSchedule} from "../src/interfaces/ITaxSchedule.sol";
import {ExampleEscrow} from "../src/examples/ExampleEscrow.sol";
import {USD, Schedule} from "./SettlementDeductionPolicy.t.sol";

/// A token whose issuer can block an address, as some stablecoins can.
contract BlockingUSD is USD {
    mapping(address => bool) public blocked;
    function setBlocked(address a, bool b) external { blocked[a] = b; }
    function transfer(address to, uint256 a) external override returns (bool) {
        require(!blocked[to], "blocked");
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
}

/// A payee that refuses native currency (any address can, since EIP-7702).
contract Refuser {
    receive() external payable { revert("no"); }
}

/// A payee that burns every bit of gas it is given.
contract Burner {
    receive() external payable { while (true) {} }
}

/// Behaviour added after the public review round: tasks announced once, the escrow's
/// policy and budget readable, payouts that a payee cannot block, delegated policies refused.
contract HardeningTest is Test {
    Schedule schedule;
    address creator  = address(0xC4EA);
    address worker   = address(0xCAFE);
    address treasury = address(0x7EA5);
    address lender   = address(0x10A1);
    uint256 constant U = 1e6;

    function setUp() public {
        schedule = new Schedule();
        schedule.set(treasury, 100); // 1%
        vm.deal(creator, 100 ether);
    }

    function _deploy() internal returns (SettlementDeductionPolicy p, ExampleEscrow e) {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        p = new SettlementDeductionPolicy(next, schedule, 5000);
        e = new ExampleEscrow(p);
        assertEq(address(e), next);
    }

    // ------------------------------------------------ a task is announced once
    function test_a_task_is_announced_once() public {
        SettlementDeductionPolicy p = new SettlementDeductionPolicy(address(this), schedule, 5000);
        p.onTaskCreated(7, address(0x05DC), 100);
        vm.expectRevert("Deductions: task exists");
        p.onTaskCreated(7, address(0xBAD), 100); // same id, another asset
        (address t, uint16 bps) = p.lockedTaxOf(7);
        assertEq(t, treasury);
        assertEq(bps, 100);
    }

    // ------------------------------------------------ the escrow publishes its policy and G
    function test_the_escrow_publishes_its_policy_and_gas() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy();
        assertEq(e.deductionPolicy(), address(p));
        assertEq(e.deductionGas(), e.DEDUCTION_GAS());
        ExampleEscrow none = new ExampleEscrow(ISettlementDeductions(address(0)));
        assertEq(none.deductionPolicy(), address(0));
    }

    function test_erc165() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy();
        assertTrue(e.supportsInterface(0x01ffc9a7));
        assertTrue(e.supportsInterface(type(ISettlementCredit).interfaceId));
        assertFalse(e.supportsInterface(0xffffffff));
        assertTrue(p.supportsInterface(0x01ffc9a7));
        assertTrue(p.supportsInterface(type(ISettlementDeductions).interfaceId));
        assertTrue(p.supportsInterface(type(ISettlementDeductionPolicy).interfaceId));
        assertFalse(p.supportsInterface(0xffffffff));
    }

    // ------------------------------------------------ a payee cannot block its payout
    function _nativeTask(ExampleEscrow e, address payee) internal returns (uint256 id) {
        vm.prank(creator);
        id = e.createTask{value: 10 ether}(address(0), 10 ether, payee);
    }

    function test_a_payee_that_refuses_is_credited_and_deductions_still_count() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy();
        address payee = address(new Refuser());
        uint256 id = _nativeTask(e, payee);
        vm.prank(payee);
        p.assignPayment(id, lender, 0, 3 ether);
        vm.expectEmit(address(e));
        emit ExampleEscrow.PayoutCredited(id, 1, payee, 6.9 ether);
        vm.prank(creator);
        e.pay(id); // does not revert, so the creator has no reason to refund instead
        assertEq(e.creditOf(id, payee), 6.9 ether);
        assertEq(e.creditOf(id, address(p)), 3.1 ether);
        p.claim(id, lender);
        assertEq(lender.balance, 3 ether, "the lender is repaid all the same");
        assertEq(address(e).balance, 6.9 ether, "only the payee's credit is left");
    }

    function test_a_payee_that_burns_gas_cannot_block_its_payout() public {
        (, ExampleEscrow e) = _deploy();
        address payee = address(new Burner());
        uint256 id = _nativeTask(e, payee);
        vm.prank(creator);
        e.pay{gas: 2_000_000}(id);
        assertEq(e.creditOf(id, payee), 9.9 ether);
    }

    function test_a_blocked_token_payee_is_credited_and_withdraws_later() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy();
        BlockingUSD b = new BlockingUSD();
        b.mint(creator, 100 * U);
        b.setBlocked(worker, true);
        vm.startPrank(creator);
        b.approve(address(e), 100 * U);
        uint256 id = e.createTask(address(b), 100 * U, worker);
        e.pay(id);
        vm.stopPrank();
        assertEq(e.creditOf(id, worker), 99 * U);
        vm.expectRevert("Escrow: transfer failed");
        e.withdrawCredit(id, worker);
        b.setBlocked(worker, false);
        e.withdrawCredit(id, worker);
        assertEq(b.balanceOf(worker), 99 * U);
        p.claim(id, treasury);
        assertEq(b.balanceOf(treasury), 1 * U);
    }

    // ------------------------------------------------ a policy must have code at deployment
    /// An account without code could be given code later (EIP-7702) and so change the
    /// policy after tasks exist.
    function test_a_policy_without_code_is_refused() public {
        try new ExampleEscrow(ISettlementDeductions(address(0xE0A))) returns (ExampleEscrow) {
            assertTrue(false, "a policy without code was accepted");
        } catch Error(string memory why) {
            assertEq(why, "Escrow: policy without code");
        }
    }

    function test_the_escrow_and_the_policy_are_never_payees() public {
        (SettlementDeductionPolicy p, ExampleEscrow e) = _deploy();
        vm.startPrank(creator);
        vm.expectRevert("Escrow: bad payee");
        e.createTask{value: 1 ether}(address(0), 1 ether, address(e));
        vm.expectRevert("Escrow: bad payee");
        e.createTask{value: 1 ether}(address(0), 1 ether, address(p));
        vm.stopPrank();
    }

    // ------------------------------------------------ a delegated policy is refused
    function test_an_eip7702_delegated_policy_is_refused() public {
        address delegated = address(0xD7702);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(0x1234)));
        try new ExampleEscrow(ISettlementDeductions(delegated)) returns (ExampleEscrow) {
            assertTrue(false, "a delegated policy was accepted");
        } catch Error(string memory why) {
            assertEq(why, "Escrow: delegated policy");
        }
    }
}
