---
description: Generate a quiz or flashcard study session from markdown notes 
  in the current directory.
argument-hint: "[ch<N>|ch<N>-<N>] [flashcard|quiz] [easy|medium|hard] [count]"
allowed-tools: Read, Write, Glob, Bash(which:*), Bash(go install:*), Bash(go build:*)
---

## Usage

```
/study [chapter] [type] [difficulty] [count]
```

- **chapter**: (optional) chapter filter — `ch2`, `ch2-4` (default: all chapters)
- **type**: `flashcard` or `quiz` (default: `flashcard`)
- **difficulty**: `easy`, `medium`, or `hard` (default: `medium`)
- **count**: number of items to generate (default: `10`)

## Steps

**Step 0: Ensure `stu` is installed**

Run `which stu` to check if the `stu` command is available.

If it is NOT found:

1. Locate the `stu` source by walking up from the current working directory, checking each ancestor for `apps/stu/cmd/stu/main.go` using the Glob tool. Stop at the filesystem root.
2. If found at `<marketplace>/apps/stu`:
   - Run `cd <marketplace>/apps/stu && go install ./cmd/stu` to install `stu` into `$GOPATH/bin` (typically `~/go/bin`).
3. If NOT found in any parent directory:
   - Warn the user: "`stu` is not installed and the source could not be located. Run `cd apps/stu && go install ./cmd/stu` from the marketplace root, then retry."
   - Abort.
4. Verify installation by running `which stu` again. If it still fails, warn the user that `~/go/bin` may not be in their `$PATH`, then abort.

**Step 1: Parse arguments**

Parse `$ARGUMENTS` (space-separated). Defaults: chapter=all, type=flashcard, difficulty=medium, count=10.

Check the first token against the pattern `^ch(\d+)(-(\d+))?$` (case-insensitive):
- If it matches, consume it as the **chapter filter** and parse the rest for type/difficulty/count.
  - `ch2` → single chapter N=2
  - `ch2-4` → chapter range start=2, end=4
- If it does not match, leave it in place and proceed with parsing type/difficulty/count as usual. chapter filter = none (all chapters).

**Step 2: Read all markdown files**

Use the Glob tool to find all `*.md` files recursively in the current working directory. Read each file's content. Skip any files inside `.stu/`.

If a chapter filter was parsed in Step 1, extract only the matching chapter sections from each file before using the content:

- A chapter section starts at a heading that matches `^#{1,3}\s+(Chapter\s+N\b.*)` (case-insensitive) where N is within the requested range.
- A chapter section ends at the next heading of the same or higher level (i.e., equal or fewer `#` characters), or at end-of-file.
- Discard all content that falls outside the selected chapter range.
- If no chapter headings are found in a file after filtering, skip that file entirely.
- If no content remains across all files after filtering, abort and tell the user: "No content found for the requested chapter(s)."

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
2. Create the `.stu/` directory if it doesn't exist
3. Save the JSON to `.stu/<slug>-<type>-<YYYYMMDD>.json`
    - If a file with that name already exists, append `-2`, `-3`, etc.

Use the Write tool to save the file.

**Step 5: Print the run command**

Print the following to the user (do NOT run it):

```
Study session saved to .stu/<filename>.json

To start studying, run:
  stu .stu/<filename>.json
```