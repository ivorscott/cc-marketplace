---
description: Summarize each chapter of the book
argument-hint: "@src [opt. @dest]"
allowed-tools: Read, Write, Glob
---

Your task is to summarize the **book**: **$ARGUMENTS[0]**.

1. **Output directory:** **$ARGUMENTS[1]** is optional.
   - If it's a **directory** (or doesn't exist yet and has no `.md` extension), use it as the output directory. Create it if needed.
   - If it's a **file**, use its parent directory as the output directory. If the filename is not prefixed with `<N>-` (a chapter number and dash), warn the user and fix it by prepending the correct chapter number — `1-` if no summaries exist yet, otherwise the next number after the highest existing summary.
   - If omitted, use the current directory.

   **Naming convention:** every summary file must be named `<N>-<slug>.md` where `<N>` is the chapter number and `<slug>` is a short kebab-case name derived from the chapter title (e.g. `1-introduction.md`, `2-getting-started.md`). When the user provides a file destination, the slug comes from their filename; otherwise derive it from the chapter title.
2. **Resume detection:** Before summarizing, glob for `[0-9]*-*.md` in the output directory.
   - If found, ask the user: **"Summaries detected. Should I continue summarizing the next chapter?"**
   - If the user confirms, determine the highest chapter number from the filenames and continue with the next one.
   - If the user declines, wait for further instructions.
3. **First run:** If no existing summaries are detected, summarize the first chapter.
4. **Subsequent chapters:** Only summarize additional chapters when prompted. Example user prompts:
   - **read the next chapter**
   - `chapter<N>` or `ch<N>` (e.g., chapter2, or ch2)
   - **next** or **n**

5. Create a **fact-checker** subagent to annotate corrections.
For example, for **technical books** about a versioned **library**, **framework** or **tool**, always assume the book is outdated
and lookup the current version. If the latest major release differs from that shown in the book. Create a note under the relevant
sections to educate the user about changes in the lastest version. For example, a book on Helm 3 might have a note about Helm 4:

```markdown
>**NOTE (Helm 4):** `helm lint` now requires an explicit path argument — e.g. `helm lint .` or `helm lint anvil`. The implicit current-directory fallback has been removed.
```
6. Create a **table-of-contents** subagent to include the same table of 
   contents on the top of every summary file, ensuring point-to-point 
   navigation between each summary.

Format each chapter summary header as follows:
```
# <Book Topic>: <Chapter Title>

Notes from <Book>.

<table-of-contents>
```

Example: for a book on Kafka, the first chapter summary would be:

```
# Kafka: Introduction

Notes from Apache Kafka in Action.

- [1. Introduction](1-introduction.md)
- [2. Topics, Partitions, Offsets](2-topics-partitions-offsets.md)
- [3. Producers and Message Keys](3-producers-message-keys.md)
- [4. Consumers and Deserialization](4-consumers-deserialization.md)
```
