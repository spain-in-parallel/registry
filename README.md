# registry

## the permissionless **IdeaRegistry** for a decentralized proposal pipeline

Anyone can submit an idea by registering a content identifier together with a fee held in escrow, then a governing Safe resolves each idea.

On approval the idea is promoted to a votable proposal **atomically**: `resolve` calls `createProposal` on the **configured downstream** voting contract and stores the returned `proposalId` in the same tx. The downstream is a **configurable address** (any contract with the `IProposalsState` shape), so a community points its instance wherever it votes without touching the code. Content integrity is enforced: the created proposal's `description` must equal the idea's CID. The registry exposes the list of promoted proposal ids so that clients can read them directly from the chain.

The base is deliberately **generic + standard** so any frontend and any community (its own instance) can build over it.

### Pieces
- `contracts/IdeaRegistry.sol`, `submit(cid)` payable (anyone) + `resolve(id, approve, config)` (onlySafe, **atomic `createProposal` on the configured downstream**) + `claim()` (pull) + events + `getPage`.
- Safe = the DAO/council. Approval via on-chain `approveHash` (stateless frontend, no infra).

### Economics: anti-spam + self-costing (fully pull-based)
- `submit` escrows a `deposit` (`>= fee`). Gas + fee are the anti-spam.
- `approve` → the full deposit accrues to the `treasury`.
- `reject` → `base` (non-refundable anti-spam) accrues to the treasury; the remainder becomes claimable by the submitter (**partial refund**).
- `claim()` → recipients pull what they are owed (submitter refunds, treasury fees). **No push transfers** → `resolve` can never be bricked.

### Contract shape
- `submit(string cid) → id`, payable, `msg.value >= fee`; stores `{cid, Pending, submitter, proposalId, deposit}`.
- `resolve(id, approve, config) onlySafe`. On approve: `createProposal(config)` on the configured downstream (no funding), stores the id via `lastProposalId()`, requires `config.description == idea.cid`, deposit → treasury. On reject: no downstream call, `base` kept + remainder refundable.
- `claim()`, pull-payment for refunds and treasury fees.
- `setConfig(safe, treasury, proposals, fee, base) onlySafe`, migrate the DAO / repoint the downstream / retune economics without redeploying.
- reads: public `ideas(id)` + `nextId` getters, `getPage(start, n)`, `promotedProposalIds()` (the on-chain display allowlist; temporal validity is read per id from the downstream); feed via `IdeaSubmitted` / `IdeaResolved` logs.

### Development

Built and tested with [Foundry](https://book.getfoundry.sh/).

```sh
forge build
forge test
```

### License

Licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE).
