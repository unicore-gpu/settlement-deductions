// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {SettlementDeductionPolicy} from "../src/SettlementDeductionPolicy.sol";
import {ISettlementDeductions, ISettlementCredit, ISettlementVault} from "../src/interfaces/ISettlementDeductions.sol";
import {ExampleEscrow} from "../src/examples/ExampleEscrow.sol";
import {Schedule} from "./SettlementDeductionPolicy.t.sol";

/// A token that logs its transfers and, like ERC-777, may call the sender's hook first.
contract HookToken {
    event Transfer(address indexed from, address indexed to, uint256 value);
    mapping(address => uint256) public balanceOf;
    address public hook;
    function mint(address a, uint256 v) external { balanceOf[a] += v; }
    function setHook(address h) external { hook = h; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) { return _move(f, to, a); }
    function transfer(address to, uint256 a) external returns (bool) {
        if (hook != address(0)) Creator(hook).onTransfer();
        return _move(msg.sender, to, a);
    }
    function _move(address f, address to, uint256 a) private returns (bool) {
        balanceOf[f] -= a;
        balanceOf[to] += a;
        emit Transfer(f, to, a);
        return true;
    }
}

/// A task creator that pays out several times in one transaction, and can try to start a
/// payout from inside another one's transfer.
contract Creator {
    ExampleEscrow immutable e;
    uint256 public id;
    uint256 nested;
    bool armed;
    bool refunding;
    bytes public refusal;
    constructor(ExampleEscrow e_) { e = e_; }
    function create(address asset, uint256 a, address payee) external { id = e.createTask(asset, a, payee); }
    function payParts(uint256[] calldata parts) external {
        for (uint256 i = 0; i < parts.length; i++) e.payPart(id, parts[i]);
    }
    function payNested(uint256 outer, uint256 inner) external {
        nested = inner;
        armed = true;
        e.payPart(id, outer);
    }
    function payRefundingInside(uint256 outer) external {
        refunding = true;
        armed = true;
        e.payPart(id, outer);
    }
    function onTransfer() external {
        if (!armed) return;
        armed = false;
        if (refunding) {
            try e.refund(id) {} catch (bytes memory why) { refusal = why; }
        } else {
            try e.payPart(id, nested) {} catch (bytes memory why) { refusal = why; }
        }
    }
}

/// Section 5, requirements 13 and 14: a reader that knows only this ERC pairs every
/// PayoutSettled with the transfer that paid it, using the task's vault and asset.
contract PairingTest is Test {
    address constant WORKER = address(0xCAFE);
    address constant TREASURY = address(0x7EA5);
    SettlementDeductionPolicy p;
    ExampleEscrow e;
    HookToken token;
    Creator creator;

    function setUp() public {
        Schedule s = new Schedule();
        s.set(TREASURY, 100); // 1%
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        p = new SettlementDeductionPolicy(next, s, 5000);
        e = new ExampleEscrow(ISettlementDeductions(address(p)));
        token = new HookToken();
        creator = new Creator(e);
        token.mint(address(creator), 1_000);
        creator.create(address(token), 1_000, WORKER);
    }

    /// Pairs each PayoutSettled with the first transfer of the task's asset from its vault
    /// to the payee, or the PayoutCredited, logged after it and before the next payout.
    /// Returns how many payouts were paired.
    function _pair(Vm.Log[] memory logs, uint256 id) internal view returns (uint256 paired) {
        address vault = ISettlementVault(address(e)).vaultOf(id);
        address asset = e.assetOf(id);
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(e) || logs[i].topics[0] != ISettlementCredit.PayoutSettled.selector) continue;
            address payee = address(uint160(uint256(logs[i].topics[3])));
            (uint256 amount, uint256 deducted) = abi.decode(logs[i].data, (uint256, uint256));
            uint256 net = amount - deducted;
            bool found;
            for (uint256 j = i + 1; j < logs.length && !found; j++) {
                Vm.Log memory l = logs[j];
                if (l.emitter == address(e) && l.topics[0] == ISettlementCredit.PayoutSettled.selector) break;
                if (l.emitter == asset && l.topics[0] == HookToken.Transfer.selector
                    && address(uint160(uint256(l.topics[1]))) == vault
                    && address(uint160(uint256(l.topics[2]))) == payee) {
                    assertEq(abi.decode(l.data, (uint256)), net, "transfer = amount - deducted");
                    found = true;
                } else if (l.emitter == address(e) && l.topics[0] == ISettlementCredit.PayoutCredited.selector) {
                    assertEq(abi.decode(l.data, (uint256)), net, "credited = amount - deducted");
                    found = true;
                }
            }
            assertTrue(found || net == 0, "every payout paired");
            paired++;
        }
    }

    function test_reports_its_vault_and_asset() public view {
        assertTrue(e.supportsInterface(type(ISettlementVault).interfaceId));
        assertEq(type(ISettlementVault).interfaceId, bytes4(0xdaa0bfba));
        assertEq(e.vaultOf(0), address(e));
        assertEq(e.assetOf(0), address(token));
    }

    function test_several_payouts_to_one_payee_in_one_transaction_pair() public {
        uint256[] memory parts = new uint256[](3);
        (parts[0], parts[1], parts[2]) = (600, 99, 301); // nets 594, 99, 298
        vm.recordLogs();
        creator.payParts(parts);
        assertEq(_pair(vm.getRecordedLogs(), creator.id()), 3);
        assertEq(token.balanceOf(WORKER), 991);
    }

    /// Without the guard, the inner payout's transfer was logged before the outer one's,
    /// and a reader pairing in order matched each event with the other's transfer.
    function test_a_payout_cannot_start_inside_another() public {
        token.setHook(address(creator));
        vm.recordLogs();
        creator.payNested(600, 300);
        bytes memory refusal = creator.refusal();
        assertEq(refusal, abi.encodeWithSignature("Error(string)", "Escrow: re-entered"));
        assertEq(_pair(vm.getRecordedLogs(), creator.id()), 1);
        assertEq(token.balanceOf(WORKER), 594);
    }

    /// Nor can a refund: it would move funds between the payout's event and its transfer.
    function test_a_refund_cannot_start_inside_a_payout() public {
        token.setHook(address(creator));
        creator.payRefundingInside(600);
        assertEq(creator.refusal(), abi.encodeWithSignature("Error(string)", "Escrow: re-entered"));
        assertEq(token.balanceOf(WORKER), 594);
        assertEq(token.balanceOf(address(creator)), 0, "nothing refunded yet");
    }
}
