# Architecture Decision Records

Each file here records one durable decision about Atoll's architecture: the
forces that led to it, what was chosen, and what it costs. They exist so a later
reader can tell an intentional constraint from an accident — especially in the
LocalSend integration, where the constraints come from an external protocol and
from macOS' socket behaviour rather than from this codebase.

An ADR is written when a decision is **hard to reverse**, **surprising without
context**, and involved a **real trade-off**, and only once it has actually been
executed. It records the decision, not a plan; a proposal belongs in the PR that
implements it.

| ADR | Decision |
| --- | --- |
| [ADR-0001](ADR-0001-localsend-receive-model.md) | The LocalSend receive model: one session slot, per-file tokens, sender-IP binding, no authentication, and the availability gate |
| [ADR-0002](ADR-0002-localsend-discovery-transport.md) | Multicast discovery over raw BSD sockets, and the poll-generation invariant |
