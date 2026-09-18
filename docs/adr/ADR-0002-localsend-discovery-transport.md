# ADR-0002: Multicast discovery over raw BSD sockets

- Status: accepted
- Date: 2026-09-19

## Context

LocalSend peers find each other on UDP 224.0.0.167:53317, and discovery has to
work next to the official LocalSend app on the same Mac (the same port), on
whichever interface the user's traffic actually takes — Wi-Fi or a plugged-in
Ethernet cable. Network.framework offers `NWConnectionGroup` for multicast, and it
was the first thing this feature used.

Two requirements pushed it out:

1. **Per-interface egress.** The announcement socket must leave through the
   interface the devices are reachable on. `NWConnectionGroup` exposes no way to
   set the IPv4 multicast egress interface per socket, so announcements followed
   the routing table — which sent them out of a cable-attached interface while the
   phone sat on Wi-Fi, and the Mac became undiscoverable.
2. **Port sharing.** `NWListener`/`NWConnectionGroup` do not expose `SO_REUSEPORT`
   semantics for UDP, so binding 53317 while the official app held it failed with
   `EADDRINUSE(48)` — and, in the code as it then stood, that failure silently took
   the send sockets down with it.

## Decision

Discovery uses raw BSD sockets on a dedicated `poll()` loop:

- One **receive** socket bound to `INADDR_ANY:53317` with `SO_REUSEADDR` **and**
  `SO_REUSEPORT`, joined to 224.0.0.167 on each usable interface.
- One **send** socket per interface address, each with `IP_MULTICAST_IF` set to
  that interface, used for announcements, so egress is explicit rather than
  routed.
- A receive loop that blocks in `poll()` with a 200 ms timeout and hands datagrams
  to the main actor.

Three invariants hold this together. They are not obvious from the code, and
breaking any of them produced a bug that was found by review rather than by
testing:

1. **`IP_MULTICAST_IF` takes a bare `struct in_addr` (4 bytes) on Darwin.** Passing
   `ip_mreq` (8 bytes) returns `EADDRNOTAVAIL(49)` and is otherwise ignored; the
   process keeps running and silently falls back to the routing table. This is the
   exact failure mode of requirement 1, and it is why the call is made with
   `in_addr` and its result checked.
2. **Never close a socket that a `poll()` may be waiting on without bumping
   `multicastGeneration` first.** Closing a file descriptor does **not** wake a
   blocked `poll()` on macOS, so a teardown that only closed the descriptor left
   the loop spinning on a stale (possibly reused) descriptor. The generation is
   bumped in the three places that can take a descriptor away from a loop or hand
   it to a new one — `startMulticastSockets()`, `stopMulticastSockets()` and
   `startReceiveLoop()` — and always before the close, and the loop re-reads the
   generation after every wakeup. The two remaining `close()` calls are creation
   failures (a send socket whose egress option failed, a receive socket whose bind
   failed); no loop ever saw those descriptors, so they do not bump.
3. **`SO_REUSEPORT` is load-bearing for coexistence.** With only `SO_REUSEADDR`,
   every second binder on UDP 53317 gets `EADDRINUSE`; REUSEPORT is what lets the
   official app and Atoll listen at once.

## Consequences

- Discovery state lives on the main actor; only the datagram loop runs off it, and
  it re-reads that state after each wakeup instead of caching it.
- The generation counter doubles as the ownership token for socket lifetime:
  anything that outlives its generation must exit without touching descriptors.
- A failure to bind the receive socket no longer takes announcements down with it;
  the send sockets are created independently and the log says which half is up.
- The listener on TCP 53317 (register/info/receive) is a separate `NWListener` on
  Network.framework: raw sockets are a UDP-discovery decision, not a general one.
- Idle teardown is decided by the actor (a self-re-arming watchdog) rather than by
  the loop, because the loop must not own product state.

## Alternatives considered

- **`NWConnectionGroup` for discovery.** Rejected for the two reasons in Context;
  it would also have hidden the `IP_MULTICAST_IF` failure mode that made the
  original bug hard to see.
- **One socket per interface for receiving.** Rejected: several joins on one port
  multiply the teardown/ownership problem that invariant 2 exists to contain.
- **Announcing only on the routing-table default interface.** Rejected: that is
  precisely the behaviour that made discovery depend on which cable was plugged
  in.
