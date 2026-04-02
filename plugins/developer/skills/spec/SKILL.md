---
description: Draft a feature specification and initialize a Git branch.
argument-hint: "Short feature description"
allowed-tools: Read, Write, Glob, Bash(git status:*), Bash(git switch:*), Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(git remote:*), Bash(git rev-parse:*)
---

You are helping to spin up a new feature spec for this application.
Always adhere to any rules or requirements set out in any CLAUDE.md files when responding.

User input: $ARGUMENTS

## High level behavior

Your job will be to turn the user input above into:

- A human friendly feature title in kebab-case (e.g. new-app-form)
- A safe git branch name not already taken (e.g. claude/feature/new-app-form)
- A detailed markdown spec file under the .spec/ directory

Then save the spec file to disk, push the branch, and print a short summary of what you did.

>**IMPORTANT:** Consider any files in $ARGUMENTS to be a **task briefing**. Postpone adding them to the code
until a new feature branch is created (see below). Use file briefings to understand the feature requirements.
If the input is insufficient to create a spec, ask the user for clarification. If you find any proposals in the briefing,
suggest alternatives. Do not make assumptions about the feature beyond what is provided in the input.

## Step 1. Check the working tree

Run `git status --porcelain` and partition the output into two sets:
- **brief-paths**: lines whose path starts with `.brief/`
- **other-paths**: everything else

If **brief-paths** is non-empty and `/.brief/` is not already in `.gitignore`:
1. Read `.gitignore` at the repo root (create it if absent).
2. Append `/.brief/` on a new line.
3. `git add .gitignore`
4. `git commit -m "chore: ignore .brief/"`

If **other-paths** is non-empty after the above, abort and tell the user to
commit or stash the remaining changes before proceeding. DO NOT GO ANY FURTHER.

## Step 2. Parse the arguments

From `$ARGUMENTS`, derive:

1. `feature_title`
    - A short, human readable title in Title Case.
    - Example: "Card Component for Dashboard Stats".

2. `feature_slug`
    - A git safe slug.
    - Rules:
        - Lowercase
        - Kebab-case
        - Only `a-z`, `0-9` and `-`
        - Replace spaces and punctuation with `-`
        - Collapse multiple `-` into one
        - Trim `-` from start and end
        - Maximum length 40 characters
    - Example: `card-component` or `card-component-dashboard`.

3. `branch_name`
    - Format: `claude/feature/<feature_slug>`
    - Example: `claude/feature/card-component`.

If you cannot infer a sensible `feature_title` and `feature_slug`, ask the user to clarify instead of guessing.

## Step 3. Switch to a new Git branch

Before making any content, switch to a new Git branch using the `branch_name` derived from the `$ARGUMENTS`. If the branch name is already taken, append a version number to it: e.g. `claude/feature/card-component-01`.

## Step 4. Draft the spec content

Create a markdown spec document that Plan mode can use directly and save it in the .spec folder using the
`feature_slug`. Use the exact structure as defined in the spec template file here: @template.md.

Do not add technical implementation details such as code examples.

## Step 5. Commit and push the branch

With the spec file saved, commit and push the branch so the spec is immediately available on GitHub.

1. Run `git rev-parse --show-toplevel` to get the repo root, then derive the path of the spec file relative to the
   repo root (e.g. `.spec/<feature_slug>.md`).
2. Stage the spec file: `git add .spec/<feature_slug>.md`
3. Commit: `git commit -m "spec: add <feature_slug>"`
4. Push: `git push -u origin <branch_name>`
5. Get the remote URL: `git remote get-url origin`
6. Construct the GitHub blob URL for the spec file:
    - Convert SSH remote (`git@github.com:org/repo.git`) → `https://github.com/org/repo`
    - Convert HTTPS remote (`https://github.com/org/repo.git`) → `https://github.com/org/repo`
    - Append `/blob/<branch_name>/<relative.spec_path>` to get `github.spec_url`.

If the push fails, print a warning and set `github.spec_url` to the local path. Do not abort.

## Step 6. Final output to the user

Respond with a short summary in this exact format:

```
Branch: <branch_name>
Spec file: .spec/<feature_slug>.md
Title: <feature_title>
GitHub: <github.spec_url>
```

Use "skipped — see warning above" for any field where the integration failed.

Do not repeat the full spec in the chat output unless the user explicitly asks to see it.
