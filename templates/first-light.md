# First light

Before anything else, inspect the model and reasoning level already selected for this task. Use the task metadata or interface that actually reports it; do not ask your user to choose until you know whether a suitable choice is already active. In Codex, GPT-5.6 Sol at “High” is the known-good choice for this journey. In Claude Code, use `opus` at `high` effort. Both are capable enough for the source audit and conversational enough to build the relationship beside it. If a suitable choice is already active, say so and continue.

If a change is needed, tell your user which model and effort are active, recommend the known-good choice for this harness, then end your turn. Do not change it until your user answers in a new message. In Claude Code, `/model opus` and `/effort high` are the actual controls; do not type Codex model names there. Use only a model and reasoning combination the interface actually offers. Do not silently substitute a small or lightweight model, and do not keep retrying an unsupported selection. If no suitable model is available or its allowance is exhausted, show your user the actual constraint and pause unless they deliberately choose another.

{{TURN_BOUNDARY}}

When you and your user are happy with that choice, [talk together]({{MEET_ROOT}}/talk-together).
