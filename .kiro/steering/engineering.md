# Engineering Philosophy

- **Plan before building** - for any task with 3+ steps or architectural decisions,
  outline the approach before touching files. Reduce ambiguity upfront.
- **Evidence over assertions** - never claim something works without showing proof.
  Run the command; show the output. No "should work" or "probably fixed".
- **Read before writing** - understand existing patterns before modifying or adding
  anything. Match the style, naming, and structure already in place.
- **Minimal, focused changes** - solve exactly what was asked. No gold-plating,
  no unrequested refactors, no speculative abstractions.
- **Systematic debugging** - find root cause before acting. One hypothesis at a time;
  make the smallest possible change to test it. After two failures on the same approach,
  stop and rethink - do not keep pushing minor variations.
- **Exhaust read-only checks before surfacing an open question** - if a question can be
  answered by a `get`/`describe`/`top`/`explain` call (AUTO tier, no confirmation needed
  per remediation-safety.md), run it yourself before presenting it to the user as an open
  item or asking "do you want me to check X?". Asking permission to run a read-only,
  reversible check is itself the failure - only pause for input on CONFIRM/NEVER-tier
  actions or genuine ambiguity about intent. Investigation is not complete until every
  cheap, available, non-destructive verification has been run.
- **Decide, don't survey** - when a technical parameter or design choice has a
  determinable right answer from data already gathered (current usage, growth rate,
  headroom, established patterns elsewhere in the repo), pick it and state it as a
  decision, not an open-ended question. Never hand the user a bare fill-in-the-blank
  like "what retention period do you want?" - that pushes analysis work back onto the
  user that the agent is better positioned to do with the data already in hand.
  Every proposed change to a tunable value must include: (1) the current value/state
  with the evidence for it, (2) the proposed value with the reasoning tied to that
  evidence, (3) what happens if left as-is or what the user would need to say to get
  a different outcome. The user's job is to confirm or override a stated position, not
  to fill in a blank the agent left empty. This is a decision-tier action, not a
  CONFIRM-tier action - deciding a proposed number does not itself change anything
  live; the actual apply of that number still goes through the normal CONFIRM tier or
  Git/PR flow.
  Reserve genuine open questions for cases where the answer depends on information the
  agent cannot derive from the repo, cluster state, or docs - user priorities, budget
  or hardware constraints not yet documented, or a tradeoff between two defensible
  options where reasonable engineers would choose differently and the choice is a
  matter of taste/priority rather than correctness (e.g. "cut this feature to hit a
  deadline" vs "keep scope, ship later" - a genuine priority call). Also avoid the
  opposite failure: do not silently pick a technical-debt shortcut to avoid asking -
  if the data-driven right answer requires more effort (e.g. a size-based retention
  cap in addition to a time-based one, rather than just bumping a number), propose
  that, don't default to the smaller/lazier change just because it needs no
  discussion.
- **Agent config edits (`.kiro/agents/*.json`) may not hot-reload into an already-running
  subagent session** - `execute_bash.allowedCommands`/`deniedCommands` changes were
  confirmed on-disk and correct (regex tested in isolation, JSON valid) but a subagent
  spawned earlier in the same orchestrator conversation still rejected a command the new
  rule should have allowed. A genuinely fresh subagent spawn picked up the change
  correctly. Contrast: `write.allowedPaths`/`deniedPaths` changes (a different tool
  subsystem) DID take effect immediately within the same session without a fresh spawn.
  Takeaway: if a config fix doesn't seem to work right after editing, try a fresh
  subagent session before concluding the fix itself is wrong - the two tool subsystems
  (`execute_bash` vs `write`) don't necessarily share the same reload behavior.
