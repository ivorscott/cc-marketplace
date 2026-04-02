---
name: analogy
description: Generate an analogy for highlighted/selected text and insert it below the selection in the markdown file. Use when the user selects text and asks for an analogy.
user_invocable: true
---

# Analogy Skill

Generate a clear, relatable analogy for the selected text and insert it directly below the selection in the file.

## Trigger

The user selects text in a markdown file and asks for an analogy (e.g., "make an analogy", "add analogy", "/analogy").

## Instructions

1. Read the selected text from the system reminder (the `<system-reminder>` tag will include the selected lines and file path).
2. Understand the technical concept being described.
3. Craft a concise, everyday analogy that makes the concept intuitive.
4. Insert the analogy as a blockquote directly below the selected text using this exact format:

```
> ### 🪞 Analogy
>
> {analogy text}
```

## Rules

- Keep the analogy to 1-3 sentences.
- Use familiar, everyday objects or scenarios (mail delivery, plumbing, traffic, etc.).
- The analogy should map clearly to the technical concept — avoid vague comparisons.
- Always use the `> ### 🪞 Analogy` header inside a blockquote.
- Insert a blank line between the selected text and the blockquote.
- Do not modify the selected text itself.
- Use emojis inline to visually reinforce key nouns in the analogy. Place the emoji before the _italicized_ noun (e.g., `📦 _mail_`, `🏠 _house_`). Use 2-4 emojis per analogy — enough to add color, not so many it becomes noisy.

## Example

Given this selected text:

```
Every device on an IP network needs a unique address within its network scope.
```

Insert below it:

```
> ### 🪞 Analogy
>
> Every 🏠 _house_ needs a unique address on the street to receive 📦 _mail_. The street is the 🛜 _network_, and the house number is the host part of the IP.
```