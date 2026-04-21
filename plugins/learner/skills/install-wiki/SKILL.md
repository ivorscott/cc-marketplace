---
name: install-wiki
description: Set up Karpathy's LLM Wiki pattern in a folder — creates the full directory structure, CLAUDE.md schema, index, log, and four page templates ready for use with Obsidian.
argument-hint: "[path/to/folder]"
user_invocable: true
allowed-tools: Read, Write, Glob, Bash(mkdir:*), Bash(ls:*)
---

Here is Andrej Karpathy’s LLM Wiki pattern. Please implement this as my personal knowledge base in this Obsidian vault. 
Create the full directory structure, the CLAUDE.md schema file, the index, the log, and all templates.
Use this @llm-wiki-template.md as the first source to ingest.
