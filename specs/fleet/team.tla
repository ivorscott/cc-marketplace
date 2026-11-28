---------------------------- MODULE team ----------------------------
(* One fleet team's lifecycle (specs/fleet/cleanup.md, "Team lifecycle"; scripts/common.sh LIFECYCLE_JQ).
   The team acts (agents work, rest, name a wait, sign off, fail); the person or the Orchestrator parks and
   unparks; the loop ticks. On a tick an Idle team is nudged once, and still Idle on the next tick it is
   Stalled. The property: a team that is not Parked, Ready or Retired is never at rest for two ticks without
   a named wait (NoSilentIdle). With Nudge = FALSE the loop does nothing for an Idle team, and the property
   must fail: team-nonudge.cfg proves the check bites. *)
EXTENDS Naturals

CONSTANTS Nudge     \* TRUE: the loop nudges an Idle team, then calls it Stalled

VARIABLES state,    \* the team's one state
          nudged,   \* the loop nudged this Idle spell already
          idleTicks \* ticks this team has spent Idle with no named wait

vars == <<state, nudged, idleTicks>>
States == {"Working", "Waiting", "Idle", "Stalled", "Ready", "Parked", "Retired"}

Init == state = "Working" /\ nudged = FALSE /\ idleTicks = 0

Go(s) == state' = s /\ nudged' = FALSE /\ idleTicks' = 0

\* --- the team ---
RestWithWait   == state = "Working" /\ Go("Waiting")
RestNoWait     == state = "Working" /\ Go("Idle")
AwaitedChanged == state = "Waiting" /\ Go("Working")
AnswerNudge    == state = "Idle" /\ nudged /\ Go("Working")
SignedOff      == state \in {"Working", "Waiting", "Idle"} /\ Go("Ready")
Fault          == state \in {"Working", "Waiting", "Idle"} /\ Go("Stalled")
Recover        == state = "Stalled" /\ Go("Working")
BackToWork     == state = "Ready" /\ Go("Working")      \* a conflict, a red check, a comment, a new head
Merged         == state = "Ready" /\ Go("Retired")      \* the loop retires it at once

\* --- a person or the Orchestrator ---
Park   == state \notin {"Parked", "Retired"} /\ Go("Parked")
Unpark == state = "Parked" /\ Go("Working")

\* --- the loop ---
Tick ==
  \/ /\ state = "Idle" /\ Nudge
     /\ IF nudged THEN Go("Stalled")                                    \* still idle after the nudge
                  ELSE state' = "Idle" /\ nudged' = TRUE /\ idleTicks' = idleTicks + 1
  \/ /\ state = "Idle" /\ ~Nudge
     /\ UNCHANGED <<state, nudged>> /\ idleTicks' = idleTicks + 1
  \/ /\ state # "Idle" /\ UNCHANGED vars

Next == RestWithWait \/ RestNoWait \/ AwaitedChanged \/ AnswerNudge \/ SignedOff \/ Fault \/ Recover
        \/ BackToWork \/ Merged \/ Park \/ Unpark \/ Tick

Spec == Init /\ [][Next]_vars

TypeOK == state \in States /\ nudged \in BOOLEAN /\ idleTicks \in Nat

\* Never at rest two ticks with no named wait, unless Parked, Ready or Retired (they are never Idle by definition).
NoSilentIdle == idleTicks < 2

\* Keep the state space finite for TLC.
TickBound == idleTicks <= 3
=============================================================================
