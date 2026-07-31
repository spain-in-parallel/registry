// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IdeaRegistry, IProposalsState} from "../contracts/IdeaRegistry.sol";
import {MockProposalsState} from "./mocks/MockProposalsState.sol";

contract IdeaRegistryTest is Test {
    IdeaRegistry reg;
    MockProposalsState ps;

    address safe = makeAddr("safe");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice"); // submitter
    address bob = makeAddr("bob"); // another submitter / stranger

    uint256 constant FEE = 1 ether;
    uint256 constant BASE = 0.1 ether;
    uint256 constant SEED = 8; // so the first created proposal id is 9, like the real one

    string constant CID = "QmIdeaContentCID";

    function setUp() public {
        ps = new MockProposalsState(SEED);
        reg = new IdeaRegistry(safe, treasury, address(ps), FEE, BASE);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _cfg(string memory desc) internal pure returns (IProposalsState.ProposalConfig memory c) {
        c.startTimestamp = 0;
        c.duration = uint64(90 days);
        c.multichoice = 0;
        c.acceptedOptions = new uint256[](1);
        c.acceptedOptions[0] = 7;
        c.description = desc;
        c.votingWhitelist = new address[](0);
        c.votingWhitelistData = new bytes[](0);
    }

    function _submit(address who, string memory cid, uint256 value) internal returns (uint256 id) {
        vm.prank(who);
        id = reg.submit{value: value}(cid);
    }

    // ------------------------------------------------------------------- submit

    function test_Submit_EscrowsAndStores() public {
        uint256 id = _submit(alice, CID, FEE);
        assertEq(id, 0);
        assertEq(reg.nextId(), 1);
        (string memory cid, IdeaRegistry.Status status, address submitter, uint64 pid, uint256 dep) =
            reg.ideas(0);
        assertEq(cid, CID);
        assertEq(uint8(status), uint8(IdeaRegistry.Status.Pending));
        assertEq(submitter, alice);
        assertEq(pid, 0);
        assertEq(dep, FEE);
        assertEq(address(reg).balance, FEE);
    }

    function test_Submit_RevertsBelowFee() public {
        vm.prank(alice);
        vm.expectRevert(IdeaRegistry.FeeTooLow.selector);
        reg.submit{value: FEE - 1}(CID);
    }

    function test_Submit_FreeWhenFeeZero() public {
        vm.prank(safe);
        reg.setConfig(safe, treasury, address(ps), 0, 0);
        uint256 id = _submit(alice, CID, 0); // free submission allowed
        (, , , , uint256 dep) = reg.ideas(id);
        assertEq(dep, 0);
    }

    // ------------------------------------------------------------- resolve/perm

    function test_Resolve_OnlySafe() public {
        uint256 id = _submit(alice, CID, FEE);
        vm.prank(bob);
        vm.expectRevert(IdeaRegistry.NotSafe.selector);
        reg.resolve(id, true, _cfg(CID));
    }

    function test_Resolve_RevertsBadId() public {
        vm.prank(safe);
        vm.expectRevert(IdeaRegistry.BadId.selector);
        reg.resolve(0, true, _cfg(CID));
    }

    function test_Resolve_RevertsNotPendingOnDoubleResolve() public {
        uint256 id = _submit(alice, CID, FEE);
        vm.prank(safe);
        reg.resolve(id, false, _cfg("")); // reject
        vm.prank(safe);
        vm.expectRevert(IdeaRegistry.NotPending.selector);
        reg.resolve(id, true, _cfg(CID));
    }

    // ------------------------------------------------------- approve (atomic)

    function test_Approve_CreatesProposalAtomically_AndReadsBackId() public {
        uint256 id = _submit(alice, CID, FEE);
        vm.warp(1_700_000_000);
        vm.prank(safe);
        reg.resolve(id, true, _cfg(CID)); // _cfg sets startTimestamp = 0

        // downstream was called exactly once with the idea's CID
        assertEq(ps.createCount(), 1);
        assertEq(ps.lastDescription(), CID);
        assertEq(ps.lastValue(), 0); // no funding forwarded
        // the council stamps startTimestamp at launch (block.timestamp), overriding the 0 in calldata
        assertEq(ps.lastStartTimestamp(), uint64(1_700_000_000));

        // read-back: id 9 (SEED+1), stored on the idea
        (, IdeaRegistry.Status status, , uint64 pid, uint256 dep) = reg.ideas(id);
        assertEq(uint8(status), uint8(IdeaRegistry.Status.Approved));
        assertEq(pid, 9);
        assertEq(dep, 0); // escrow consumed

        // full deposit accrued to treasury; display list holds the proposal id
        assertEq(reg.owed(treasury), FEE);
        uint256[] memory ids = reg.promotedProposalIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], 9);
    }

    function test_Approve_RevertsOnCidMismatch() public {
        uint256 id = _submit(alice, CID, FEE);
        vm.prank(safe);
        vm.expectRevert(IdeaRegistry.CidMismatch.selector);
        reg.resolve(id, true, _cfg("QmSomethingElse"));
        // nothing happened downstream, escrow intact
        assertEq(ps.createCount(), 0);
        (, IdeaRegistry.Status status, , , uint256 dep) = reg.ideas(id);
        assertEq(uint8(status), uint8(IdeaRegistry.Status.Pending));
        assertEq(dep, FEE);
    }

    /// The read-back must capture THIS resolve's proposal id even when other
    /// proposals are created directly on the downstream in between.
    function test_ReadBack_CorrectDespiteInterleavedExternalCreates() public {
        // idea 0 -> approve -> proposal 9
        uint256 id0 = _submit(alice, "cid0", FEE);
        vm.prank(safe);
        reg.resolve(id0, true, _cfg("cid0"));
        (, , , uint64 pid0, ) = reg.ideas(id0);
        assertEq(pid0, 9);

        // someone creates a proposal directly on the rail (permissionless) -> 10
        ps.createProposal(_cfg("outsider"));
        assertEq(ps.lastProposalId(), 10);

        // idea 1 -> approve -> must read back 11, not the idea id (1)
        uint256 id1 = _submit(bob, "cid1", FEE);
        vm.prank(safe);
        reg.resolve(id1, true, _cfg("cid1"));
        (, , , uint64 pid1, ) = reg.ideas(id1);
        assertEq(pid1, 11);
        assertTrue(pid1 != uint64(id1)); // idea id and proposal id diverge, by design

        uint256[] memory ids = reg.promotedProposalIds();
        assertEq(ids.length, 2);
        assertEq(ids[0], 9);
        assertEq(ids[1], 11); // approval order
    }

    // ---------------------------------------------------------------- reject

    function test_Reject_KeepsBase_RefundsRemainder() public {
        uint256 id = _submit(alice, CID, FEE);
        vm.prank(safe);
        reg.resolve(id, false, _cfg(""));

        assertEq(ps.createCount(), 0); // no downstream call
        (, IdeaRegistry.Status status, , uint64 pid, ) = reg.ideas(id);
        assertEq(uint8(status), uint8(IdeaRegistry.Status.Rejected));
        assertEq(pid, 0);
        assertEq(reg.owed(treasury), BASE);
        assertEq(reg.owed(alice), FEE - BASE);
    }

    /// THE bug the review caught: base raised above a stale deposit must not
    /// underflow / lock the idea; the kept amount clamps to the escrow.
    function test_Reject_ClampsWhenBaseExceedsStaleDeposit() public {
        uint256 id = _submit(alice, CID, FEE); // deposit = 1 ether
        // DAO later raises the economics well above the stale deposit
        vm.prank(safe);
        reg.setConfig(safe, treasury, address(ps), 100 ether, 50 ether);

        vm.prank(safe);
        reg.resolve(id, false, _cfg("")); // must not revert

        assertEq(reg.owed(treasury), FEE); // clamped to the deposit (1 ether), not 50
        assertEq(reg.owed(alice), 0); // nothing left to refund
    }

    function test_Reject_FreeSubmissionNoRefundNoRevert() public {
        vm.prank(safe);
        reg.setConfig(safe, treasury, address(ps), 0, 0);
        uint256 id = _submit(alice, CID, 0);
        vm.prank(safe);
        reg.resolve(id, false, _cfg(""));
        assertEq(reg.owed(treasury), 0);
        assertEq(reg.owed(alice), 0);
    }

    // ----------------------------------------------------------------- claim

    function test_Claim_PullsOwed() public {
        uint256 id = _submit(alice, CID, FEE);
        vm.prank(safe);
        reg.resolve(id, false, _cfg("")); // alice owed FEE-BASE, treasury owed BASE

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        reg.claim();
        assertEq(alice.balance, aliceBefore + (FEE - BASE));
        assertEq(reg.owed(alice), 0);

        uint256 tBefore = treasury.balance;
        vm.prank(treasury);
        reg.claim();
        assertEq(treasury.balance, tBefore + BASE);
    }

    function test_Claim_RevertsNothingOwed() public {
        vm.prank(bob);
        vm.expectRevert(IdeaRegistry.NothingOwed.selector);
        reg.claim();
    }

    // ------------------------------------------------------------- setConfig

    function test_SetConfig_OnlySafe() public {
        vm.prank(bob);
        vm.expectRevert(IdeaRegistry.NotSafe.selector);
        reg.setConfig(bob, bob, address(ps), 0, 0);
    }

    function test_SetConfig_RevertsBaseAboveFee() public {
        vm.prank(safe);
        vm.expectRevert(IdeaRegistry.BadConfig.selector);
        reg.setConfig(safe, treasury, address(ps), 1 ether, 2 ether);
    }

    function test_SetConfig_RevertsZeroAddress() public {
        vm.prank(safe);
        vm.expectRevert(IdeaRegistry.BadConfig.selector);
        reg.setConfig(address(0), treasury, address(ps), FEE, BASE);
    }

    function test_SetConfig_RepointDownstream() public {
        MockProposalsState ps2 = new MockProposalsState(100);
        vm.prank(safe);
        reg.setConfig(safe, treasury, address(ps2), FEE, BASE);
        uint256 id = _submit(alice, CID, FEE);
        vm.prank(safe);
        reg.resolve(id, true, _cfg(CID));
        assertEq(ps.createCount(), 0); // old downstream untouched
        assertEq(ps2.createCount(), 1);
        (, , , uint64 pid, ) = reg.ideas(id);
        assertEq(pid, 101); // read back from the new downstream
    }

    // ----------------------------------------------------------- solvency

    /// After an arbitrary mix of outcomes, the contract holds at least the sum
    /// of everything it owes (each idea only ever pays out its own deposit).
    function test_Solvency_Invariant() public {
        _submit(alice, "a", FEE); // id 0
        _submit(bob, "b", 2 ether); // id 1 (over-pays)
        _submit(alice, "c", FEE); // id 2

        vm.prank(safe);
        reg.resolve(0, true, _cfg("a")); // approve -> treasury owed 1
        vm.prank(safe);
        reg.resolve(1, false, _cfg("")); // reject -> treasury+0.1, bob 1.9
        // id 2 left pending

        uint256 totalOwed = reg.owed(treasury) + reg.owed(alice) + reg.owed(bob);
        assertLe(totalOwed, address(reg).balance);
        // exact backing: pending escrow (id2) + owed == balance
        assertEq(address(reg).balance, totalOwed + FEE);
    }

    // -------------------------------------------------------------- fuzz

    function testFuzz_Reject_NeverUnderflows(uint96 deposit, uint256 newFee, uint256 newBase) public {
        deposit = uint96(bound(deposit, 0, 50 ether));
        newFee = bound(newFee, 0, 1_000 ether);
        newBase = bound(newBase, 0, newFee); // invariant base <= fee
        vm.deal(alice, deposit);

        // submit at fee 0 so any deposit is accepted, then retune upward
        vm.prank(safe);
        reg.setConfig(safe, treasury, address(ps), 0, 0);
        uint256 id = _submit(alice, CID, deposit);
        vm.prank(safe);
        reg.setConfig(safe, treasury, address(ps), newFee, newBase);

        vm.prank(safe);
        reg.resolve(id, false, _cfg("")); // must never revert

        // payouts for this idea sum to exactly its deposit
        assertEq(reg.owed(treasury) + reg.owed(alice), deposit);
    }
}
