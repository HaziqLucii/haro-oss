"""The templates a new note can start from.

Each follows an established format, so a blank page already says what goes where, and each has its
own shape (a record, a table, a timeline) rather than one heading list reused:

- ``decision``: MADR 4.0 (Markdown Architectural Decision Records, adr.github.io/madr).
- ``design-doc``: the Google design doc (context and scope, goals and non-goals, the design,
  alternatives considered, cross-cutting concerns; industrialempathy.com).
- ``postmortem``: the blameless postmortem of Google's SRE book (summary, impact, root causes,
  trigger, resolution, detection, action items by type, lessons learned, timeline).
- ``pitch``: a Shape Up pitch (problem, appetite, solution, rabbit holes, no-gos).
- ``spike``: a time-boxed technical spike (one question, a time box, criteria, evidence, a
  recommendation, follow-ups).
- ``bug``: a bug investigation (intake, minimal reproduction, evidence, ranked hypotheses, five
  whys, root cause, fix and verification).
- ``brainstorm`` and ``learning``: haro's own. The learning log is about staying the author: what
  you wrote yourself, where you leaned on a tool, what you did not understand.

``{{title}}`` and ``{{date}}`` are filled in when a note is made. Lines in _italics_ are hints to
write over. Fields written ``name:: value`` are read by Obsidian's Dataview and show as plain text
in haro.
"""

from __future__ import annotations

BUILT_IN: dict[str, tuple[str, str]] = {
    "brainstorm": (
        "Brainstorm",
        """# {{title}}

{{date}}

## The question

_One sentence. If it needs two, it is two brainstorms._

## Ideas

- 

## Constraints

- 

## Try first

_The cheapest idea that would teach you something._
""",
    ),
    "decision": (
        "Decision record (MADR)",
        """# {{title}}

status:: proposed
date:: {{date}}
decision-makers:: 
consulted:: 
informed:: 

## Context and Problem Statement

_What is being decided, and why now? Say it as a question if you can._

## Decision Drivers

- 

## Considered Options

- Option 1
- Option 2

## Decision Outcome

Chosen option: "", because 

### Consequences

- Good, because 
- Bad, because 

### Confirmation

_How will you know the decision is followed? A test, a review, a check in CI._

## Pros and Cons of the Options

### Option 1

- Good, because 
- Neutral, because 
- Bad, because 

### Option 2

- Good, because 
- Bad, because 

## More Information

_Evidence, links to related decisions, and when to revisit this one._
""",
    ),
    "design-doc": (
        "Design doc",
        """# {{title}}

author:: 
status:: draft
updated:: {{date}}

## Context and scope

_The landscape today and what is being built, in objective terms. Assume a reader new to the project; the solution does not belong here._

## Goals

- 

## Non-goals

_Things that could reasonably be goals and were left out on purpose. Not just the goals negated._

- 

## The design

### Overview

### Details

_APIs, data, how the pieces talk. The trade-offs matter more than the code._

## Alternatives considered

| Alternative | Why it could work | Why not |
|---|---|---|
|  |  |  |

## Cross-cutting concerns

- Security: 
- Privacy: 
- Observability: 

## Open questions

- [ ] 
""",
    ),
    "pitch": (
        "Pitch (Shape Up)",
        """# {{title}}

appetite:: 
shaped:: {{date}}

## Problem

_One concrete story that shows why the status quo does not work._

## Appetite

_How much time is this worth? The solution has to fit it; the time does not stretch to fit the solution._

## Solution

_The core elements, rough enough to leave room for the builder, concrete enough to be sure it fits._

## Rabbit holes

_Tempting detail that could eat the time, and how to avoid it._

- 

## No-gos

_What is left out on purpose to fit the appetite._

- 

## Done when

- [ ] 
""",
    ),
    "spike": (
        "Spike",
        """# {{title}}

time box:: 
decide by:: 
started:: {{date}}

## The question

_One question per spike._

### Smaller questions

- 

## How I will judge the answer

- 

## What I tried

| Step | What I did | What happened |
|---|---|---|
|  |  |  |

_Evidence beats opinion: a prototype, a benchmark, a test, a link._

## Findings

## Recommendation

## What I did not check

## Follow-up

- [ ] 
""",
    ),
    "bug": (
        "Bug investigation",
        """# {{title}}

status:: investigating
opened:: {{date}}

## What was expected, what happened

- Expected: 
- Actual: 

## Intake

- Since when: 
- What changed around then: 
- Who or what is affected: 
- Happens every time: 

## Reproduction

1. 

_Environment, and the smallest case that still fails._

## Evidence

_Logs, stack traces, screenshots, the commit where it started (`git bisect`)._

## Hypotheses

| # | Hypothesis | Confidence | How to test it | Result |
|---|---|---|---|---|
| 1 |  |  |  |  |

## Five whys

1. Why? 
2. Why? 
3. Why? 

## Root cause

## Fix and verification

- [ ] Fix: 
- [ ] A test that failed before the fix and passes after: 
- [ ] Checked the same mistake nowhere else: 
""",
    ),
    "postmortem": (
        "Postmortem",
        """# {{title}}

date:: {{date}}
status:: draft
authors:: 

_Blameless: what happened and why, not who did it._

## Summary

## Impact

_Who was affected, for how long, and by how much._

## Root causes

_Contributing factors, not one culprit._

## Trigger

## Resolution

## Detection

_What noticed it first, and how long after it began._

## Action items

| Type | Action | Owner | Tracked in |
|---|---|---|---|
| Mitigate |  |  |  |
| Prevent |  |  |  |
| Process |  |  |  |

## Lessons learned

### What went well

- 

### What went wrong

- 

### Where we got lucky

- 

## Timeline

| Time | Event |
|---|---|
|  |  |

## Supporting information

_Dashboards, logs, the pull requests._
""",
    ),
    "learning": (
        "Learning log",
        """# {{title}}

{{date}}

## What I set out to do

## What I wrote myself

## Where I leaned on a tool or an agent

_And whether I could now do it without it._

## What I did not understand

- 

## To read or try next

- [ ] 
""",
    ),
}
