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
