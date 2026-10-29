# Fleet protocol model (TLA+)

`fleet.tla` models the 4.2.0 fleet protocol: issue claims with a heartbeat lease (two machines can race for one
issue), the merge gate (PR head, CI, the tester's sign-off), and the Owner's authority over approvals
(`fleet decide`, relayed answers, suggested drafts). It is a model only; no plugin code depends on it.
Time is a bounded counter, so nothing here uses a wall clock.

## Run it

    TLA2TOOLS=~/.local/share/tla/tla2tools.jar specs/fleet/run-tlc.sh          # every configuration
    specs/fleet/run-tlc.sh fleet-gate                                          # one

Needs Java 11+ and `tla2tools.jar` (TLC 2.19). CI (`fleet-tla.yml`) runs the same script with a pinned,
checksum-verified jar. Each must-hold configuration has to finish clean; each expected-failing one has to report
exactly its violation, so a counterexample that vanishes also fails the run.

| config | covers | holds? |
|---|---|---|
| `fleet` | 2 machines, 1 issue: claim race, takeover, push, sign-off, merge | must hold: `OneOwner`, `NoStalePush`, `MergeGate` |
| `fleet-gate` | 1 machine, 1 issue, 3 pushes: the gate alone | must hold: `MergeGate` |
| `fleet-authority` | escalations, `decide`, relay, TTL, Owner offline; no git | must hold: `Authority`, `RelayRule` |
| `fleet-stale` | `fleet` without the claim check before a push | fails `NoStalePush` |
| `fleet-label` | the raw label set during the claim race | fails `LabelAtMostOne` |
| `fleet-draft` | a suggested draft that is not cleared | fails `Authority` |
| `fleet-relay` | relaying one hop past the lead | fails `RelayRule` |

The model is split by concern because the product of all of it is too large to check in a minute. The state
counts and times are in the PR description.

## What the spec proved

On the bounds in the configs (2 machines, lease 3, settle 1, clock to 8):

1. **One owner.** At most one machine is a live holder of an issue, even when two machines race for the claim.
2. **No stale work**, once a push first checks the claim (`CheckLeaseBeforePush = TRUE`).
3. **Merge gate.** A merge needs an open PR, green CI and a sign-off on the current head. Any push or rebase after
   sign-off moves the head, so it needs a new sign-off.
4. **Authority.** An act rests on the Owner's own message, or on a delegated decision that is neither a P0 nor a
   human-only item (merge, production, infrastructure apply, secrets, branch protection). A suggestion never counts.
5. **Relay** (below), as `RelayRule`.

Seeded bugs were each caught by the matching property: dropping the sign-off or green-CI guard (`MergeGate`),
dropping the settle re-read (`OneOwner`), dropping the human or P0 gate in `decide`, the TTL, or the human check
on relay (`Authority` / `RelayRule`).

## What it found

- **A team learns of a lost or lapsed claim only on its next tick.** Until then it can push: the claim lapses, the
  team has not ticked, and it pushes (`fleet-stale`). With the claim checked just before each push the property
  holds. *Proposed follow-up:* a claim re-check before a push or rebase. The model checks the claim and pushes in
  one step, so a real check still leaves a short window between the two.
- **The raw label can name two machines** while both are inside the settle delay (`fleet-label`). It is safe,
  because neither holds until the re-read, and the loser drops out, but a consumer that reads the label alone
  should not treat it as ownership. *Proposed follow-up:* say so where the label is read.
- **A suggested draft that is not cleared reads as an approval** (`fleet-draft`). The clearing step is what keeps
  `Authority` true; it must stay a guarantee, not a courtesy.
- **A gap.** Dropping the "no open PR" guard from takeover or release is not caught by any property: with the claim
  check in place the old holder cannot push, so the model sees no harm. The guard protects work already pushed,
  which this model does not value. *Proposed follow-up:* a property that a PR's branch has one owner.
- **Renewal period.** The issue asks for a renewal every 20-25 minutes; the plugin renews on every tick. The model
  lets a renewal happen at any time before the lapse, which covers both.

## Relay rule (decision)

An Owner approval is valid at the Orchestrator and, through `decide`, one hop on, at the lead named in the
escalation, as a *delegated* decision. It never reaches a planner, builder or tester as authority; they receive
instructions. It is never relayed for a human-only item. A relayed approval lapses when its escalation resolves, or
after `ApprovalTtl` while the Owner is offline; after that an Orchestrator under `fleet run` decides non-human P1/P2
items itself and parks the rest. `LeadHop`, `Relay`, `Act` and `RelayRule` in `fleet.tla` state and check this.
`ApprovalTtl` is in clock units; the 4 h stall that motivated it is a real-time bound the model only scales.

## Keep it in step with the plugin?

Yes, for the protocol constants and guards: the lease and settle rule, takeover and release guards, "sign-off equals
head", and `decide` parking. A change to any of them should change the model first and pass TLC. No, for output
shapes, pane handling or the registry file format: they are outside the model on purpose.

## Left out

Herdr panes and rendering, the registry file format, tick scheduling beyond "a heartbeat any time before the
lapse", the roles inside a team (a team pushes and signs off), `FLEET_FORCE`, symmetry between machines.
