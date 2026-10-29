------------------------------- MODULE fleet -------------------------------
(***************************************************************************)
(* The fleet protocol as of plugin 4.2.0: issue claims (heartbeat lease),  *)
(* the merge gate, and the Owner's authority over approvals.               *)
(*                                                                         *)
(* Actors: the Owner (a human), one Orchestrator and one team per machine, *)
(* the tracker (claim labels) and the code host (PR, CI, merge). A team is *)
(* reduced to what the properties need: it pushes, and its tester signs    *)
(* off. Time is a bounded discrete `clock`; there is no wall clock.        *)
(*                                                                         *)
(* Model only. Nothing here is plugin code; see README.md.                 *)
(***************************************************************************)
EXTENDS Naturals, Integers, FiniteSets, TLC

CONSTANTS
    Machines,              \* machines, one Orchestrator and one team each
    Issues,                \* tracked issues
    EscIds,                \* escalation slots
    Lease,                 \* a machine's heartbeat lapses when older than this
    Settle,                \* delay between writing a claim and re-reading it
    MaxClock,              \* the clock stops here (bounds the state space)
    MaxPush,               \* pushes and rebases per issue (bounds the state space)
    ApprovalTtl,           \* a relayed approval lapses after this many units
    RelayLimit,            \* how many hops the Relay action may take
    MaxMsgs,               \* message-set bound (state constraint)
    CheckLeaseBeforePush,  \* TRUE: a push first checks the claim (proposed fix)
    ClearsDraft            \* TRUE: a suggested draft is cleared, never delivered

ASSUME ApprovalTtl <= MaxClock /\ Lease < MaxClock /\ Settle >= 1

VARIABLES
    clock,
    hb,        \* hb[m]: clock of machine m's last heartbeat (one per machine)
    label,     \* label[i]: SET of machines whose claim label is on issue i
    cs,        \* cs[m][i]: idle | read | written | held (claim steps)
    wrote,     \* wrote[m][i]: clock when m wrote its label
    head,      \* head[i]: PR head, a counter (every push or rebase is new)
    pr,        \* pr[i]: none | open | merged
    ci,        \* ci[i]: pending | green | red, for the current head
    signed,    \* signed[i]: head the tester signed off, -1 for none
    mrec,      \* mrec[i]: snapshot of the gate at merge time
    stalePush, \* TRUE once a push came from a team without a live lease
    offline,   \* the Owner is offline
    esc,       \* esc[e]: an escalation
    msgs,      \* approval messages in flight
    drafts,    \* escalations with an unsent suggested draft
    acted      \* every act taken on an approval or a decision

vars == <<clock, hb, label, cs, wrote, head, pr, ci, signed, mrec,
          stalePush, offline, esc, msgs, drafts, acted>>

Sevs == {"P0", "P1", "P2"}

(* The relay rule (property 5). An Owner approval is valid at the         *)
(* Orchestrator (hop 0) and one hop on, at the lead named in the          *)
(* escalation (hop 1), as a delegated decision. It never travels further, *)
(* never for a human-only item, and a relayed one lapses after            *)
(* ApprovalTtl.                                                           *)
LeadHop == 1

Lapsed(m)  == clock - hb[m] > Lease
Live(m, i) == cs[m][i] = "held" /\ ~Lapsed(m)

Init ==
    /\ clock = 0
    /\ hb = [m \in Machines |-> 0]
    /\ label = [i \in Issues |-> {}]
    /\ cs = [m \in Machines |-> [i \in Issues |-> "idle"]]
    /\ wrote = [m \in Machines |-> [i \in Issues |-> 0]]
    /\ head = [i \in Issues |-> 0]
    /\ pr = [i \in Issues |-> "none"]
    /\ ci = [i \in Issues |-> "pending"]
    /\ signed = [i \in Issues |-> -1]
    /\ mrec = [i \in Issues |-> [sg |-> -1, hd |-> 0, ci |-> "pending"]]
    /\ stalePush = FALSE
    /\ offline = FALSE
    /\ esc = [e \in EscIds |-> [st |-> "none", sev |-> "P1", human |-> FALSE]]
    /\ msgs = {}
    /\ drafts = {}
    /\ acted = {}

Advance ==
    /\ clock < MaxClock
    /\ clock' = clock + 1
    /\ UNCHANGED <<hb, label, cs, wrote, head, pr, ci, signed, mrec,
                   stalePush, offline, esc, msgs, drafts, acted>>

(* ---- claims (heartbeat and claim, DEV-636) ---- *)

\* A machine reads the label of an unclaimed issue ...
ClaimRead(m, i) ==
    /\ cs[m][i] = "idle" /\ label[i] = {} /\ pr[i] # "merged"
    /\ cs' = [cs EXCEPT ![m][i] = "read"]
    /\ UNCHANGED <<clock, hb, label, wrote, head, pr, ci, signed, mrec,
                   stalePush, offline, esc, msgs, drafts, acted>>

\* ... and writes its label later; another machine may have read the same.
ClaimWrite(m, i) ==
    /\ cs[m][i] = "read"
    /\ label' = [label EXCEPT ![i] = @ \cup {m}]
    /\ wrote' = [wrote EXCEPT ![m][i] = clock]
    /\ cs' = [cs EXCEPT ![m][i] = "written"]
    /\ UNCHANGED <<clock, hb, head, pr, ci, signed, mrec,
                   stalePush, offline, esc, msgs, drafts, acted>>

\* After the settle delay it re-reads: it keeps the claim only if it is the
\* one label left, otherwise it drops out (claim_lost).
SettleClaim(m, i) ==
    /\ cs[m][i] = "written" /\ clock >= wrote[m][i] + Settle
    /\ IF label[i] = {m}
         THEN /\ cs' = [cs EXCEPT ![m][i] = "held"]
              /\ UNCHANGED label
         ELSE /\ cs' = [cs EXCEPT ![m][i] = "idle"]
              /\ label' = [label EXCEPT ![i] = @ \ {m}]
    /\ UNCHANGED <<clock, hb, wrote, head, pr, ci, signed, mrec,
                   stalePush, offline, esc, msgs, drafts, acted>>

\* Takeover (lapsed_claim): the holder's heartbeat lapsed and no PR is open.
Takeover(m, i) ==
    /\ cs[m][i] = "idle" /\ pr[i] = "none"
    /\ \E o \in Machines \ {m} : label[i] = {o} /\ Lapsed(o)
    /\ label' = [label EXCEPT ![i] = {m}]
    /\ wrote' = [wrote EXCEPT ![m][i] = clock]
    /\ cs' = [cs EXCEPT ![m][i] = "written"]
    /\ UNCHANGED <<clock, hb, head, pr, ci, signed, mrec,
                   stalePush, offline, esc, msgs, drafts, acted>>

\* Release of a lapsed claim: the same guards, the label is removed.
Release(m, i) ==
    /\ pr[i] = "none"
    /\ \E o \in Machines : label[i] = {o} /\ Lapsed(o)
    /\ label' = [label EXCEPT ![i] = {}]
    /\ UNCHANGED <<clock, hb, cs, wrote, head, pr, ci, signed, mrec,
                   stalePush, offline, esc, msgs, drafts, acted>>

\* A tick writes the machine's one heartbeat and re-reads its claims: a team
\* learns of claim_lost here and nowhere earlier. Renewal may happen at any
\* time before the lapse, which covers any renewal period.
Tick(m) ==
    LET lost(i) == cs[m][i] = "held" /\ label[i] # {m}
    IN /\ hb' = [hb EXCEPT ![m] = clock]
       /\ cs' = [cs EXCEPT ![m] = [i \in Issues |->
                                     IF lost(i) THEN "idle" ELSE cs[m][i]]]
       /\ label' = [i \in Issues |-> IF lost(i) THEN label[i] \ {m} ELSE label[i]]
       /\ UNCHANGED <<clock, wrote, head, pr, ci, signed, mrec,
                      stalePush, offline, esc, msgs, drafts, acted>>

(* ---- git, CI and the merge gate ---- *)

\* A push or a rebase: a new head, CI starts over, any sign-off is stale.
\* Without CheckLeaseBeforePush a team that has not yet ticked still believes
\* it holds the claim, whatever its lease says.
Push(m, i) ==
    /\ cs[m][i] = "held" /\ pr[i] # "merged" /\ head[i] < MaxPush
    /\ CheckLeaseBeforePush => Live(m, i)
    /\ head' = [head EXCEPT ![i] = @ + 1]
    /\ pr' = [pr EXCEPT ![i] = "open"]
    /\ ci' = [ci EXCEPT ![i] = "pending"]
    /\ stalePush' = (stalePush \/ ~Live(m, i))
    /\ UNCHANGED <<clock, hb, label, cs, wrote, signed, mrec,
                   offline, esc, msgs, drafts, acted>>

CIResult(i) ==
    /\ pr[i] = "open" /\ ci[i] = "pending"
    /\ \E r \in {"green", "red"} : ci' = [ci EXCEPT ![i] = r]
    /\ UNCHANGED <<clock, hb, label, cs, wrote, head, pr, signed, mrec,
                   stalePush, offline, esc, msgs, drafts, acted>>

\* The tester signs off the head it saw (and only the tester).
Signoff(m, i) ==
    /\ cs[m][i] = "held" /\ pr[i] = "open"
    /\ signed' = [signed EXCEPT ![i] = head[i]]
    /\ UNCHANGED <<clock, hb, label, cs, wrote, head, pr, ci, mrec,
                   stalePush, offline, esc, msgs, drafts, acted>>

Ready(i) == pr[i] = "open" /\ ci[i] = "green" /\ signed[i] = head[i]

\* Only the human merger merges; no agent action does.
Merge(i) ==
    /\ Ready(i)
    /\ pr' = [pr EXCEPT ![i] = "merged"]
    /\ mrec' = [mrec EXCEPT ![i] = [sg |-> signed[i], hd |-> head[i], ci |-> ci[i]]]
    /\ UNCHANGED <<clock, hb, label, cs, wrote, head, ci, signed,
                   stalePush, offline, esc, msgs, drafts, acted>>

(* ---- escalations, `fleet decide` and the Owner's authority ---- *)

ToggleOffline ==
    /\ offline' = ~offline
    /\ UNCHANGED <<clock, hb, label, cs, wrote, head, pr, ci, signed, mrec,
                   stalePush, esc, msgs, drafts, acted>>

Escalate(e, sev, human) ==
    /\ esc[e].st = "none"
    /\ esc' = [esc EXCEPT ![e] = [st |-> "open", sev |-> sev, human |-> human]]
    /\ UNCHANGED <<clock, hb, label, cs, wrote, head, pr, ci, signed, mrec,
                   stalePush, offline, msgs, drafts, acted>>

Msg(e, origin, hops, at) == [esc |-> e, origin |-> origin, hops |-> hops, at |-> at]

OwnerSend(e) ==
    /\ ~offline /\ esc[e].st = "open"
    /\ msgs' = msgs \cup {Msg(e, "owner", 0, clock)}
    /\ UNCHANGED <<clock, hb, label, cs, wrote, head, pr, ci, signed, mrec,
                   stalePush, offline, esc, drafts, acted>>

\* The grayed prompt text. When it is cleared it is never a message; when it
\* is not, another pane can read it as the Owner's answer.
DraftSuggestion(e) ==
    /\ esc[e].st = "open"
    /\ IF ClearsDraft
         THEN /\ drafts' = drafts \cup {e}
              /\ UNCHANGED msgs
         ELSE /\ msgs' = msgs \cup {Msg(e, "suggestion", 0, clock)}
              /\ UNCHANGED drafts
    /\ UNCHANGED <<clock, hb, label, cs, wrote, head, pr, ci, signed, mrec,
                   stalePush, offline, esc, acted>>

\* One hop on. Never for a human-only item.
Relay(msg) ==
    /\ msg \in msgs /\ msg.hops < RelayLimit
    /\ esc[msg.esc].st = "open" /\ ~esc[msg.esc].human
    /\ msgs' = msgs \cup {[msg EXCEPT !.hops = @ + 1]}
    /\ UNCHANGED <<clock, hb, label, cs, wrote, head, pr, ci, signed, mrec,
                   stalePush, offline, esc, drafts, acted>>

\* An agent acts on an approval. A relayed one must still be inside its TTL.
Act(msg) ==
    /\ msg \in msgs /\ esc[msg.esc].st = "open"
    /\ msg.hops = 0 \/ clock - msg.at <= ApprovalTtl
    /\ esc' = [esc EXCEPT ![msg.esc].st = "resolved"]
    /\ acted' = acted \cup {[origin |-> msg.origin, hops |-> msg.hops,
                              age |-> clock - msg.at,
                              human |-> esc[msg.esc].human, sev |-> esc[msg.esc].sev]}
    /\ UNCHANGED <<clock, hb, label, cs, wrote, head, pr, ci, signed, mrec,
                   stalePush, offline, msgs, drafts>>

\* fleet decide: the Orchestrator takes the first option, tagged delegated,
\* for a P1 or P2 that is not the human's.
Decide(e) ==
    /\ esc[e].st = "open" /\ esc[e].sev \in {"P1", "P2"} /\ ~esc[e].human
    /\ esc' = [esc EXCEPT ![e].st = "delegated"]
    /\ acted' = acted \cup {[origin |-> "delegated", hops |-> 0, age |-> 0,
                              human |-> esc[e].human, sev |-> esc[e].sev]}
    /\ UNCHANGED <<clock, hb, label, cs, wrote, head, pr, ci, signed, mrec,
                   stalePush, offline, msgs, drafts>>

\* A P0, or anything that is the human's, is parked: nothing is approved.
Park(e) ==
    /\ esc[e].st = "open" /\ (esc[e].sev = "P0" \/ esc[e].human)
    /\ esc' = [esc EXCEPT ![e].st = "parked"]
    /\ UNCHANGED <<clock, hb, label, cs, wrote, head, pr, ci, signed, mrec,
                   stalePush, offline, msgs, drafts, acted>>

Next ==
    \/ Advance
    \/ \E m \in Machines : Tick(m)
    \/ \E m \in Machines, i \in Issues :
          ClaimRead(m, i) \/ ClaimWrite(m, i) \/ SettleClaim(m, i)
          \/ Takeover(m, i) \/ Release(m, i)
          \/ Push(m, i) \/ Signoff(m, i)
    \/ \E i \in Issues : CIResult(i) \/ Merge(i)
    \/ ToggleOffline
    \/ \E e \in EscIds, s \in Sevs, h \in BOOLEAN : Escalate(e, s, h)
    \/ \E e \in EscIds : OwnerSend(e) \/ DraftSuggestion(e) \/ Decide(e) \/ Park(e)
    \/ \E msg \in msgs : Relay(msg) \/ Act(msg)

Spec == Init /\ [][Next]_vars

MsgBound == Cardinality(msgs) <= MaxMsgs

\* Issues are interchangeable, so a configuration may fold them.
IssueSymmetry == Permutations(Issues)

(* ---- properties ---- *)

TypeOK ==
    /\ clock \in 0..MaxClock
    /\ \A i \in Issues : label[i] \subseteq Machines /\ pr[i] \in {"none", "open", "merged"}
    /\ \A m \in Machines, i \in Issues : cs[m][i] \in {"idle", "read", "written", "held"}

\* 1. At most one live holder per issue, across all machines.
OneOwner ==
    \A i \in Issues : Cardinality({m \in Machines : Live(m, i)}) <= 1

\* The raw label can name two machines during the claim race (reported, not hidden).
LabelAtMostOne == \A i \in Issues : Cardinality(label[i]) <= 1

\* 2. A team whose lease lapsed never pushes.
NoStalePush == ~stalePush

\* 3. A merged PR was signed off at the head that merged, with green CI, and the
\* head did not move after.
MergeGate ==
    \A i \in Issues :
        pr[i] = "merged" =>
            /\ mrec[i].sg = mrec[i].hd /\ mrec[i].ci = "green"
            /\ head[i] = mrec[i].hd

\* 4. An act rests on the Owner's own message, or on a delegated decision
\* that is neither a P0 nor the human's. A suggestion never counts.
Authority ==
    \A a \in acted :
        \/ a.origin = "owner"
        \/ a.origin = "delegated" /\ ~a.human /\ a.sev # "P0"

\* 5. The relay rule (see LeadHop above).
RelayRule ==
    \A a \in acted :
        /\ a.hops <= LeadHop
        /\ a.hops > 0 => (~a.human /\ a.age <= ApprovalTtl)

=============================================================================
