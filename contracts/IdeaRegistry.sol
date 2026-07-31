// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.33;

/// @title  IProposalsState
/// @notice Minimal shape of the downstream voting contract the registry
///         promotes approved ideas to.
/// @dev    `createProposal` returns nothing: it bumps a monotonic counter and
///         emits the id. We read `lastProposalId()` right after the call to
///         recover it.
interface IProposalsState {
    struct ProposalConfig {
        uint64    startTimestamp;
        uint64    duration;
        uint256   multichoice;
        uint256[] acceptedOptions;
        string    description;
        address[] votingWhitelist;
        bytes[]   votingWhitelistData;
    }

    function createProposal(ProposalConfig calldata config) external payable;
    function lastProposalId() external view returns (uint256);
}

/// @title  IdeaRegistry
/// @notice Permissionless queue for a decentralized proposal pipeline. Anyone
///         `submit`s an idea (an IPFS CID) with a small fee; a DAO (a Safe)
///         `resolve`s it. On approval the idea is promoted to a votable
///         proposal atomically on the configured downstream.
/// @dev    Money flow is fully pull-based (`owed` + `claim`), no push transfers,
///         so `resolve` can never be bricked by a recipient that reverts on
///         receive. The downstream is a configurable address so a community can
///         point its instance wherever it votes without touching the code.
contract IdeaRegistry {
    /// @notice Lifecycle of an idea.
    enum Status {
        Pending,  // 0 : submitted, awaiting the DAO
        Approved, // 1 : DAO approved, proposal created
        Rejected  // 2 : DAO rejected
    }

    /// @notice A submitted idea. First 29 bytes pack into one slot (before `deposit`).
    struct Idea {
        string  cid;        // IPFS content of the idea/proposal
        Status  status;     // Pending until the DAO resolves it
        address submitter;  // refund recipient + provenance
        uint64  proposalId; // downstream proposal id set on approval
        uint256 deposit;    // amount escrowed; set to 0 once resolved
    }

    /// @notice Minimum submission fee.
    uint256 public fee;
    /// @notice Non-refundable anti-spam portion kept on reject (`base <= fee`).
    uint256 public base;

    /// @notice The DAO (Gnosis Safe): the only caller of `resolve` / `setConfig`.
    address public safe;
    /// @notice Where kept fees accrue (pulled via `claim`).
    address public treasury;
    /// @notice Downstream voting contract approved ideas are promoted to.
    address public proposals;

    /// @notice Next idea id.
    uint256 public nextId;
    /// @notice id => idea.
    mapping(uint256 => Idea) public ideas;

    /// @notice Pull ledger: address => withdrawable balance.
    mapping(address => uint256) public owed;

    /// @notice Proposal ids of approved ideas, appended on approval (terminal state).
    uint256[] internal _promotedProposalIds;

    event IdeaSubmitted(uint256 indexed id, string cid, address indexed submitter, uint256 deposit);
    event IdeaResolved(uint256 indexed id, Status status, uint64 proposalId);
    event Claimed(address indexed who, uint256 amount);
    event ConfigChanged(address safe, address treasury, address proposals, uint256 fee, uint256 base);

    error NotSafe();
    error BadId();
    error NotPending();
    error FeeTooLow();
    error BadConfig();
    error CidMismatch();
    error NothingOwed();
    error TransferFailed();

    modifier onlySafe() {
        if (msg.sender != safe) revert NotSafe();
        _;
    }

    /// @param safe_      the DAO Safe.
    /// @param treasury_  where kept fees accrue.
    /// @param proposals_ the downstream voting contract.
    /// @param fee_       minimum submission fee.
    /// @param base_      non-refundable anti-spam portion (`base <= fee`).
    constructor(address safe_, address treasury_, address proposals_, uint256 fee_, uint256 base_) {
        if (safe_ == address(0) || treasury_ == address(0) || proposals_ == address(0) || base_ > fee_) {
            revert BadConfig();
        }
        safe = safe_;
        treasury = treasury_;
        proposals = proposals_;
        fee = fee_;
        base = base_;
    }

    /// @notice Submit an idea. Gas + `fee` are the anti-spam; `msg.value` is
    ///         escrowed until the DAO resolves it.
    /// @param  cid IPFS CID of the idea content.
    /// @return id  the assigned idea id.
    function submit(string calldata cid) external payable returns (uint256 id) {
        if (msg.value < fee) revert FeeTooLow();
        id = nextId++;
        ideas[id] = Idea({cid: cid, status: Status.Pending, submitter: msg.sender, proposalId: 0, deposit: msg.value});
        emit IdeaSubmitted(id, cid, msg.sender, msg.value);
    }

    /// @notice Approve or reject a pending idea.
    /// @dev    Approve creates the proposal atomically downstream and stores its
    ///         id (read back from `lastProposalId`); `config.description` must
    ///         equal the idea's CID (content integrity). Reject keeps `base`
    ///         (clamped to the escrow) and refunds the rest. Effects precede the
    ///         external call (checks-effects-interactions).
    /// @param  id      the idea to resolve.
    /// @param  approve true to promote, false to reject.
    /// @param  config  the downstream proposal config (approve path only).
    function resolve(uint256 id, bool approve, IProposalsState.ProposalConfig calldata config)
        external
        onlySafe
    {
        if (id >= nextId) revert BadId();
        Idea storage idea = ideas[id];
        if (idea.status != Status.Pending) revert NotPending();

        uint256 dep = idea.deposit;
        idea.deposit = 0;

        if (approve) {
            if (keccak256(bytes(config.description)) != keccak256(bytes(idea.cid))) revert CidMismatch();
            idea.status = Status.Approved;
            // The council stamps `startTimestamp` at launch, not the signer: callers pass 0, so the
            // approved calldata is fully deterministic (same safeTxHash on every device / cross-device).
            IProposalsState.ProposalConfig memory cfg = config;
            cfg.startTimestamp = uint64(block.timestamp);
            IProposalsState(proposals).createProposal(cfg);
            idea.proposalId = uint64(IProposalsState(proposals).lastProposalId());
            _promotedProposalIds.push(idea.proposalId);
            owed[treasury] += dep;
        } else {
            idea.status = Status.Rejected;
            // clamp: `base` may exceed a stale `deposit`
            uint256 keep = base < dep ? base : dep;
            owed[treasury] += keep;
            owed[idea.submitter] += dep - keep;
        }

        emit IdeaResolved(id, idea.status, idea.proposalId);
    }

    /// @notice Withdraw whatever you are owed (submitter refunds and/or treasury fees).
    function claim() external {
        uint256 amt = owed[msg.sender];
        if (amt == 0) revert NothingOwed();
        owed[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amt}("");
        if (!ok) revert TransferFailed();
        emit Claimed(msg.sender, amt);
    }

    /// @notice Migrate the DAO, repoint the downstream and/or retune economics.
    /// @dev    `fee = base = 0` is valid (free submissions). Raising `base` does
    ///         not lock already-escrowed ideas: `resolve` clamps the kept amount
    ///         to each idea's own deposit.
    function setConfig(address safe_, address treasury_, address proposals_, uint256 fee_, uint256 base_)
        external
        onlySafe
    {
        if (safe_ == address(0) || treasury_ == address(0) || proposals_ == address(0) || base_ > fee_) {
            revert BadConfig();
        }
        safe = safe_;
        treasury = treasury_;
        proposals = proposals_;
        fee = fee_;
        base = base_;
        emit ConfigChanged(safe_, treasury_, proposals_, fee_, base_);
    }

    /// @notice Batch read for the frontend (paired with Multicall3 / the event feed).
    /// @dev    `view` (free off-chain eth_call); bounded by the caller's `n`.
    function getPage(uint256 start, uint256 n) external view returns (Idea[] memory page) {
        uint256 len = nextId;
        if (start >= len) return new Idea[](0);
        uint256 end = start + n;
        if (end > len) end = len;
        page = new Idea[](end - start);
        for (uint256 i = start; i < end; i++) {
            page[i - start] = ideas[i];
        }
    }

    /// @notice The list the app consumes: proposal ids of all approved ideas,
    ///         in approval order. Precomputed, no iteration. This is a display
    ///         allowlist (promoted ideas); temporal validity (open/expired) is
    ///         the downstream's business, read per id from `ProposalsState`.
    /// @dev    Replaces the off-chain proposals.json (no display-layer owner).
    function promotedProposalIds() external view returns (uint256[] memory) {
        return _promotedProposalIds;
    }
}
