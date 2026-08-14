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
