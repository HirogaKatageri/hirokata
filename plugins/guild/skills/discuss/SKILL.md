---
name: discuss
description: >
  This skill should be used when the user says "discuss", "let's discuss", "discuss [topic]",
  "talk about", "let's talk about", "summarize the context", "what are we working on",
  "break down the topics", "what subjects do we have", "let's review the context",
  "recap the conversation", or any phrase asking to analyze and discuss the current
  context or a specific subject within it.
version: 1.0.0
user-invocable: true
---

# Discuss — Context Summarizer and Discussion Facilitator

Analyze the current conversation context, surface the subjects it contains, and facilitate a
focused discussion with the user — either across all topics or scoped to one specific topic.

## Two Modes

### Mode 1: Open Discussion (`/discuss` or `discuss`)

No topic argument given. Scan the full conversation context.

**Step 1 — Extract subjects**

Read the conversation and identify all distinct subjects, decisions, problems, questions, and
themes present. Group closely related items under a single subject heading. Aim for 3–8 groups;
merge very small or overlapping ones.

**Step 2 — Present the topic map**

Display a numbered list of subjects with a one-sentence summary for each:

```
Context Summary
===============

Subjects found in this conversation:

1. <Subject Title>
   <One-sentence description of what was discussed or decided.>

2. <Subject Title>
   <One-sentence description.>

3. <Subject Title>
   <One-sentence description.>

Which subject would you like to discuss? (enter a number, name, or "all")
```

**Step 3 — Enter discussion loop**

Wait for the user to pick a subject or say "all". Then enter the discussion loop (see below).

---

### Mode 2: Targeted Discussion (`discuss [topic]`)

A topic argument was given. Scope analysis to that topic only.

**Step 1 — Find relevant context**

Search the conversation for everything related to the given topic: decisions made, problems
raised, open questions, referenced files or code, dependencies, and constraints.

**Step 2 — Present the topic summary**

```
Discussion: <Topic>
===================

Summary
-------
<2–4 sentence narrative summary of everything the context says about this topic.>

Key points:
  • <point>
  • <point>
  • <point>

Open questions or unresolved items:
  • <item> (or "None" if everything is settled)

What would you like to explore or decide about [topic]?
```

Then enter the discussion loop immediately.

---

## Discussion Loop

Once a topic is established, drive an active back-and-forth:

1. **Ask a focused question** to advance understanding or reach a decision. Base it on gaps,
   open questions, or unresolved items surfaced during summarization.

2. **Listen and integrate** the user's response into the running understanding of the topic.

3. **Offer observations, trade-offs, or recommendations** when relevant — connect the topic to
   other context in the conversation, surface implications, and raise unconsidered factors.

4. **Check satisfaction signals** after each exchange: if the user signals they are done
   ("that's it", "thanks", "good", "we're done"), wrap up.

5. **Proactively check** when the discussion reaches a natural conclusion: ask "Is there anything
   else you'd like to explore about [topic], or are we good?"

6. **Loop** until the user is satisfied — never end the loop without confirmation.

### Mid-loop topic switches

If the user says "let's talk about <other topic>" or "actually, discuss X instead" during the
loop, summarize the current topic with a one-liner ("Got it — we covered: <brief summary>"),
then start a fresh Mode 2 summary for the new topic.

---

## Wrap-up

When the discussion ends, present a brief closing summary:

```
Discussion Complete: <Topic>
============================

What we covered:
  • <point>
  • <point>

Decisions or conclusions:
  • <item> (or "None reached — exploration only")

Next steps (if any):
  • <item>
```

Then ask:
```
Would you like to discuss another subject, or are we done?
```

If the user wants another subject, return to **Mode 1 Step 2** (show the topic map again) or
jump directly to a new topic if the user names one.

---

## Rules

- **Never end the loop unilaterally** — always confirm with the user before stopping.
- **Be opinionated** — go beyond summarizing; offer analysis, flag risks, suggest directions.
- **Stay scoped** — in targeted mode, do not drift into unrelated subjects.
- **Keep summaries tight** — bullet points over paragraphs; depth over length.
- **One question at a time** — avoid multi-question prompts that overwhelm the user.
