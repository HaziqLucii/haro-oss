---
name: haro-note
description: >-
  Create or append to a haro note. Use whenever the user says "create a haro note",
  "haro note", "add this to my haro notes", "make a note in haro", "note this down in haro",
  "brainstorm note" or similar. A haro note is a plain markdown file in `.haro/notes/` at the
  root of the current project, which haro's Notes tab (Backlog > NOTES) lists and edits. Also
  use when asked what is in the haro notes. Not for backlog todos (`.haro/todos/*.md`, or
  `backlog/*.md` in a project that already uses that folder).
---

# Haro notes

A **haro note** is a markdown file at `.haro/notes/<name>.md`, relative to the project root (the
directory that holds `.haro/`, usually the git root). haro's Backlog > NOTES tab shows every `.md`
there, newest first, with search, and the user edits them in the app. The notes are plain files in
the repo, so they go with `git pull` and open in any editor.

## When the user says "create a haro note"

1. Write the note the user asked for **in their words**. Do not add sections, summaries, headings
   or ideas they did not ask for. If they gave a topic and no content ("create a haro note about
   caching"), ask once what to put in it, or write only what they said so far.
2. File name: a short kebab-case slug of the title, `.md`, directly in `.haro/notes/`
   (`caching-ideas.md`). Create `.haro/notes/` if it does not exist. A subfolder only if the
   user names one (`design/api.md`).
3. First line is `# Title` (the Notes tab uses it as the title). No front matter.
4. Never overwrite a note that exists. If `<slug>.md` is taken, add to it only when the user said
   so ("add to the caching note"); otherwise pick `<slug>-2.md` and say so.
5. Do not run `git add` or `git commit` unless asked. `.haro/notes/` is a normal tracked folder.
6. Reply with one line: the path you wrote. Nothing else.

## Append, read, list

- "Add to the X note": find it by file name or title in `.haro/notes/`, append at the end, keep
  everything above it unchanged.
- "What is in my haro notes" / "list my haro notes": list the files with their `# Title` lines.
- Read a note when the user refers to one by name; treat its text as the user's own writing.

## Where `.haro/notes/` is

- In the project's own checkout, `.haro/notes/` is what the Notes tab shows right away.
- Inside a haro worktree (the path contains `/.haro/worktrees/`), the same relative path is part of
  that workspace's branch: the note shows in the Notes tab once the branch is merged. Say so in the
  reply ("written in the worktree; it shows in the Notes tab after the merge"). If the user wants
  it visible now, write it under the project checkout instead (`$HARO_ROOT_PATH` when set).
- A scope fence limits edits to the files the user named. If a `.haro/notes/` path is outside it,
  say so instead of writing it.

## What a note is not

Notes are the user's thinking space: brainstorms, sketches, what they tried. Todos live in
`.haro/todos/*.md` (or `backlog/*.md`) as `- [ ]` lines.
Do not create a note on your own initiative; only when asked. Files that sit in `.haro/notes/` beside the notes (PDFs, spreadsheets,
Excalidraw drawings) are the user's source material: read them if asked, never rewrite or move them,
and link to one with `[[name.pdf]]`.
