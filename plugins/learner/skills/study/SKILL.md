---
description: Generate a quiz or flashcard study session from markdown notes 
  in the current directory.
argument-hint: "[@file.md] [ch<N>|ch<N>-<N>] [flashcard|quiz] [easy|medium|hard] [count]"
allowed-tools: Read, Write, Glob, Bash(which:*), Bash(go install:*), Bash(go build:*)
---

## Usage

```
/study [@file] [chapter] [type] [difficulty] [count]
```

- **file**: (optional) restrict to a single markdown file or a directory — `@notes.md` or `@some-dir/` (default: all `.md` files in the current directory). Can be combined with a chapter filter — e.g. `@some-dir/ ch2` extracts chapter 2 from every file under that directory. The generated study file is saved under the basedir of this path rather than the current directory (see Step 4).
- **chapter**: (optional) chapter filter — `ch2`, `ch2-4` (default: all chapters). Applies to whichever file(s) are selected — a single file, a directory's files, or all files in the current directory.
- **type**: `flashcard` or `quiz` (default: `flashcard`)
- **difficulty**: `easy`, `medium`, or `hard` (default: `medium`)
- **count**: number of items to generate (default: `10`)

## Steps

**Step 0: Ensure `stu` is installed**

Run `which stu` to check if the `stu` command is available. If found, continue to Step 1.

If it is NOT found:

1. Run `go install github.com/ivorscott/cc-marketplace/apps/stu/cmd/stu@latest` to install the latest published version into `$GOPATH/bin` (typically `~/go/bin`).
2. If `go install` fails (e.g., no network or no Go toolchain), surface the error to the user and abort.
3. Run `which stu` again. If it still fails, warn the user:
   > `stu` was installed but is not on `$PATH`. Add `$HOME/go/bin` to your PATH:
   > `echo 'export PATH="$PATH:$HOME/go/bin"' >> ~/.zshrc && source ~/.zshrc`

   Then abort.

**Step 1: Parse arguments**

Parse `$ARGUMENTS` (space-separated). Defaults: file=none, dir=none, chapter=all, type=flashcard, difficulty=medium, count=10. Track a **basedir** for Step 4 — defaults to the current working directory.

Check the first token against the pattern `^@(.+)$`:
- If it matches, take the path after `@` and decide which kind of path filter it is:
  - If the path ends in `/`, or it exists on disk as a directory: consume it as the **directory filter**. Set basedir = that directory (trailing slash stripped).
  - Otherwise: consume it as the **file filter**. Set basedir = the directory containing that file (its dirname; `.` if the path has no directory component).
- If it does not match, leave it in place; there is no path filter (basedir stays the current working directory).

After resolving the path filter (or confirming there is none), check the **next unconsumed token** against the pattern `^ch(\d+)(-(\d+))?$` (case-insensitive), regardless of whether a path filter was found:
- If it matches, consume it as the **chapter filter**.
  - `ch2` → single chapter N=2
  - `ch2-4` → chapter range start=2, end=4
- If it does not match, leave it in place. Chapter filter = none (all chapters).

Parse whatever tokens remain for type/difficulty/count as usual.

**Step 2: Read markdown file(s)**

If a directory filter was parsed in Step 1:
- If the directory doesn't exist, abort and tell the user: "Directory not found: `<path>`".
- Use the Glob tool to find all `*.md` files recursively under that directory. Read each file's content. Skip any files inside `.stu/`.
- If no `.md` files are found, abort and tell the user: "No markdown files found in: `<path>`".

Else if a file filter was parsed in Step 1:
- Read that file directly. If it doesn't exist or isn't a `.md` file, abort and tell the user: "File not found: `<path>`".

Otherwise (no path filter): use the Glob tool to find all `*.md` files recursively in the current working directory. Read each file's content. Skip any files inside `.stu/`.

In every case above, if a chapter filter was parsed in Step 1, extract only the matching chapter sections from each file that was read (single file, a directory's files, or the current directory's files) before using the content:

- A chapter section starts at a heading that matches `^#{1,3}\s+(Chapter\s+N\b.*)` (case-insensitive) where N is within the requested range.
- A chapter section ends at the next heading of the same or higher level (i.e., equal or fewer `#` characters), or at end-of-file.
- Discard all content that falls outside the selected chapter range.
- If no chapter headings are found in a file after filtering, skip that file entirely.
- If no content remains across all files after filtering, abort and tell the user: "No content found for the requested chapter(s)."

If no chapter filter was parsed, use the whole content of each file read above — no chapter-section extraction.

**Step 3: Generate study content**

Based on the parsed type, generate the content using the rules below. Output ONLY valid JSON — no prose, no markdown fences.

### If type = `quiz`

Generate exactly `count` multiple-choice questions at the specified `difficulty` level. Each question must test a distinct concept from the notes. Harder difficulty means more nuanced distinctions or deeper conceptual understanding required.

Output JSON matching this schema exactly:

```json
{
  "type": "quiz",
  "title": "<topic> Quiz",
  "difficulty": "<difficulty>",
  "sources": ["<relative path to each .md file read>"],
  "created_at": "<ISO 8601 timestamp>",
  "questions": [
    {
      "id": 1,
      "question": "<clear, specific question>",
      "options": [
        "<option A>",
        "<option B>",
        "<option C>",
        "<option D>"
      ],
      "correct": <0-based index of correct option>,
      "hint": "<brief hint that doesn't give away the answer>",
      "explanations": [
        "<explanation for why option A is correct or incorrect>",
        "<explanation for why option B is correct or incorrect>",
        "<explanation for why option C is correct or incorrect>",
        "<explanation for why option D is correct or incorrect>"
      ]
    }
  ]
}
```

Rules:
- Shuffle the correct answer's position across questions (don't always put correct at index 1)
- Each explanation should be a complete sentence explaining why that option is right or wrong
- Do NOT prefix the correct option's explanation with "Correct!", "That's right!", or any affirmation — the app adds this dynamically
- Hints should help guide thinking without revealing the answer

### If type = `flashcard`

Generate exactly `count` flashcards at the specified `difficulty` level. Each card tests a distinct fact or concept. Harder difficulty means more nuanced or application-level questions.

Output JSON matching this schema exactly:

```json
{
  "type": "flashcards",
  "title": "<topic> Flashcards",
  "difficulty": "<difficulty>",
  "sources": ["<relative path to each .md file read>"],
  "created_at": "<ISO 8601 timestamp>",
  "cards": [
    {
      "id": 1,
      "front": "<question or prompt>",
      "back": "<concise answer>",
      "explanation": "<optional: 1-2 sentence deeper explanation>"
    }
  ]
}
```

Rules:
- Front should be a clear question or fill-in-the-blank prompt
- Back should be concise (1 sentence or a short list)
- Explanation is optional but recommended for non-obvious answers

**Step 4: Save the file**

1. Derive a slug from the topic (e.g., `kafka`, `ccna`, `grpc`) based on the directory or file names
2. Create the `<basedir>/.stu/` directory if it doesn't exist, where `basedir` is the one determined in Step 1 (the directory of the `@file`/`@dir` argument, or the current working directory if no path filter was given)
3. Save the JSON to `<basedir>/.stu/<slug>-<type>-<YYYYMMDD>.json`
    - If a file with that name already exists, append `-2`, `-3`, etc.

Use the Write tool to save the file.

**Step 5: Print the run command**

Print the following to the user (do NOT run it), using the `<basedir>/.stu/<filename>.json` path from Step 4:

```
Study session saved to <basedir>/.stu/<filename>.json

To start studying, run:
  stu <basedir>/.stu/<filename>.json
```