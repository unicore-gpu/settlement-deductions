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
        assertEq(keccak256("SettlementDeducted(uint256,uint256,address,uint256)"),
                 0xd6a50990fa5d56f79112ecd39bb97ad451c1b9cea471098009151950b037826d);
        assertEq(keccak256("DeductionsSkipped(uint256,uint256)"),
                 0x12518d49b1ef011e575513a1e510df3de4f1682fcef7750bea4d80717e6e54d1);
    }
}
