# Expertise files

An agent forgets everything between sessions. An expertise file is what it remembers: a
short, curated file per role that the agent reads before it starts, and that gets better
after every team the role takes part in.

- **Location:** `<repo>/.claude/experts/<role>.md`, for example `.claude/experts/tester.md` or
  `.claude/experts/lead.md`. `boot.sh` points each agent at its file when one exists.

## Format

Keep it under about 60 lines. An expertise file that nobody can read in a minute stops being read.

```markdown
# <role> — expertise for <repo>

## Do
- <a concrete practice that worked, and why>

## Don't
- <a mistake that happened, what it cost, what to do instead>

## Know
- <a fact about this codebase the role keeps needing: a command, a path, a quirk>

## Changelog
- YYYY-MM-DD <team>: <one line on what changed and which debrief it came from>
```

## The debrief loop

1. When a team is retired, `/fleet debrief` reads its rows (summaries, escalations,
   discovered work, outcome) and the lead's last output.
2. It writes one or two lessons per agent into the registry (`lessons`).
3. It proposes a diff per role to the expertise file: new Do, Don't or Know lines, and
   removing lines the run proved wrong. It proposes; a human applies.
4. If the template itself caused the problem (a wrong role, a missing step, an
   exit criterion that can't be checked), it proposes a template diff instead.

A lesson belongs in an expertise file only if it would change what the role does next
time. "The tests were slow" doesn't; "run `make test-unit`, not `make test`, while
iterating: the full suite takes 9 minutes" does.
