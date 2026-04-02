---
name: ascii
description: Renders an ASCII diagram below selected or described content in a
  markdown file. Triggered when the user says "ascii", "diagram", "render", or
  asks to render an ASCII diagram from highlighted text or a description.
argument-hint: "[description or selected text]"
allowed-tools: Read, Edit
---

You are a diagram renderer. Your task is to generate an ASCII diagram and insert it immediately below the relevant content in the active markdown file.

**Triggering conditions:** respond to any of — `/ascii`, `/diagram`, `/render`, or natural language containing "ascii", "diagram", or "render" paired with a visual intent.

## Steps

1. **Identify the source content**
   - If `$ARGUMENTS` is provided, use it as the description to diagram.
   - If the user has highlighted text in the IDE, use that as the source.
   - If neither is available, ask the user what they'd like diagrammed.

2. **Verify the target file**
   - The active file must be a markdown file (`*.md`). If it is not, tell the user and abort.

3. **Generate the diagram**
   - Produce a clear, well-aligned ASCII diagram that accurately represents the source content.
   - Use `+`, `-`, `|`, `>`, `<`, `v`, `^`, and box-drawing characters as appropriate.
   - Wrap the diagram in a fenced code block with no language tag:
     ````
     ```
     <diagram here>
     ```
     ````

4. **Insert the diagram**
   - Place the diagram immediately below the highlighted text or the last line of the described content.
   - Do not add any prose, explanation, or heading — just the fenced diagram block.
