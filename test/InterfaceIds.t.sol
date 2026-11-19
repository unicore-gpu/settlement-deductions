// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISettlementDeductions, ISettlementCredit} from "../src/interfaces/ISettlementDeductions.sol";
import {ISettlementDeductionPolicy} from "../src/interfaces/ISettlementDeductionPolicy.sol";
import {ITaxSchedule} from "../src/interfaces/ITaxSchedule.sol";

/// The interface identifiers and event topics published in the ERC's Test Cases.
contract InterfaceIdsTest is Test {
    function test_interface_ids() public pure {
        assertEq(type(ISettlementDeductions).interfaceId, bytes4(0x77f547ff));
        assertEq(type(ISettlementCredit).interfaceId, bytes4(0x3a440a3e));
        assertEq(type(ISettlementDeductionPolicy).interfaceId, bytes4(0x80ba847a));
        assertEq(type(ITaxSchedule).interfaceId, bytes4(0xbbb356a6));
    }

    function test_event_topics() public pure {
        assertEq(keccak256("PayoutSettled(uint256,uint256,address,uint256,uint256)"),
                 0x5ea26080db4e57a546bd3bde39877f04221f27cd135c547140004d8ed8874eb9);
        assertEq(keccak256("DeductionsSkipped(uint256,uint256)"),
                 0x12518d49b1ef011e575513a1e510df3de4f1682fcef7750bea4d80717e6e54d1);
        assertEq(keccak256("PayoutCredited(uint256,uint256,address,uint256)"),
                 0x04ab8430152b57cce04ae8ca52ad44317ee26f1d8c7646697e3e65b7d9fc988b);
        assertEq(keccak256("PayoutWithdrawn(uint256,address,uint256)"),
                 0xd1a15b9173e0bd19f4a0af7e8662bbbacb41e5c41d6f477ede54b32345d0b97c);
        assertEq(ISettlementCredit.PayoutSettled.selector,
                 0x5ea26080db4e57a546bd3bde39877f04221f27cd135c547140004d8ed8874eb9);
        assertEq(ISettlementCredit.DeductionsSkipped.selector,
                 0x12518d49b1ef011e575513a1e510df3de4f1682fcef7750bea4d80717e6e54d1);
        assertEq(ISettlementCredit.PayoutCredited.selector,
                 0x04ab8430152b57cce04ae8ca52ad44317ee26f1d8c7646697e3e65b7d9fc988b);
        assertEq(ISettlementCredit.PayoutWithdrawn.selector,
                 0xd1a15b9173e0bd19f4a0af7e8662bbbacb41e5c41d6f477ede54b32345d0b97c);
    }
}
