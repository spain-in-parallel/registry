// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.33;

import {IProposalsState} from "../../contracts/IdeaRegistry.sol";

/// @notice Faithful stand-in for the rail's ProposalsState: `createProposal`
///         returns nothing, bumps a monotonic `lastProposalId` and records the
///         call so tests can assert the config (CID) that was forwarded. Seed
///         the counter to mirror a deployment that already has proposals
///         (e.g. the real #9).
contract MockProposalsState is IProposalsState {
    uint256 public lastProposalId;
    uint256 public createCount;
    string public lastDescription;
    uint256 public lastValue;
    uint64 public lastStartTimestamp;

    event ProposalCreated(uint256 indexed proposalId, string description);

    constructor(uint256 seed) {
        lastProposalId = seed;
    }

    function createProposal(ProposalConfig calldata config) external payable {
        uint256 id = ++lastProposalId; // mirrors ProposalsState.sol:126
        createCount++;
        lastDescription = config.description;
        lastValue = msg.value;
        lastStartTimestamp = config.startTimestamp;
        emit ProposalCreated(id, config.description);
    }
}
