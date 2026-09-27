# Shape: swarm

Many independent units at once, one report at the end. This is coordinator's
default way of working; the name is for choosing it on purpose.

**Use when** the work splits into parts that don't touch the same files and
don't need each other's output: several endpoints, several docs pages, a
bug per module. Also for questions: several researchers on different
questions in parallel.

**How**

1. Cut the goal into units with no `--deps` between them (or only real ones).
   Give each unit exclusive SCOPE; two units writing the same file is a race,
   not a swarm.
2. Dispatch every ready unit in the same turn.
3. For questions, send one `coord research` per question, each with its own
   GOAL, instead of one researcher with a long list.
4. Report once, when the wave is done: what merged, what came back, what is
   waiting on the user. Don't narrate each unit as it lands.

**Don't** swarm units that edit the same files; give them `--deps` so they
run in order, or merge them into one unit.
