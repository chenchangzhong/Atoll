# ADR-0001: The LocalSend receive model

- Status: accepted
- Date: 2026-09-19

## Context

Atoll speaks LocalSend's v2 HTTP contract on TCP 53317 so it can send files to
phones. The reverse direction — a phone pushing a file to the Mac — needs a
server, and the protocol gives the app room to decide several things that are not
obvious from the wire format:

- **What the token is worth.** `prepare-upload` hands out a per-file token and the
  sender echoes it on `upload`. Nothing in the protocol says what happens if a
  token leaks, and the same LAN may hold untrusted devices.
- **How many transfers may be in flight.** Senders can prepare a second upload
  while the first is still running.
- **Who decides.** Upstream's core blocks the `prepare-upload` handler on the
  app's decision (a oneshot channel); dropping it yields 500.
- **When the server exists at all.** Atoll's discovery lifecycle is driven by the
  share UI, and that lifecycle is what used to create the 53317 listener.

## Decision

1. **One session slot, mirroring upstream's `SessionStateV2`.** A second
   `prepare-upload` while a session is pending or active is answered `409`
   (`Blocked by another session`). A slot that stops making progress is released
   after 90 s without progress — measured in 15 s ticks, so in practice between 90
   and ~105 s — by a reaper, so a sender that walks away cannot wedge the app;
   progress (not elapsed time) is what keeps a transfer alive.
2. **Per-file UUID tokens, bound to the sender's address.** `upload` is refused
   (`403 Invalid token or IP address`) unless the session id, the file id, the
   token *and* the address that prepared the session all match. The address is compared as the
   transport reports it (not parsed into IPv4), so an IPv6 peer is bound too.
3. **Every state has a way out.** A failure publishes the file name and the reason
   and shows a card with a Release action — including for a transfer that was
   accepted automatically, where the notch does not open by itself, so reopening it
   during the retention window still explains what happened. That card is *not*
   auto-cleared: it lives exactly as long as the session slot is claimed, so the
   card and the window agree. An in-flight transfer can be cancelled from the
   progress card, which stops the stream, removes the partial file and releases the
   slot immediately; the sender is told the transfer failed, which is what
   cancelling means here.
4. **A failed upload keeps its slot for 30 s, not 90 s.** Upstream keeps such a
   session indefinitely, but only because its sender retries *the same file with
   the same token* — and even upstream only resets a checksum mismatch back to
   pending (within an attempt limit); other failures are terminal for that file.
   Atoll is deliberately more permissive and keeps any failure retryable for 30 s,
   which is long enough for a retry that is already in flight and short enough that
   the common "send it again" (a fresh `prepare-upload`) is not left staring at a
   `409`.
5. **The user decides, in Atoll's own notch.** `prepare-upload` publishes a
   pending request, and the request is answered `200` with the tokens only after
   the user accepts, `403` when declined, and `500` when the 60 s window passes
   with no answer — upstream's "dropped decision" semantics. The default is to
   ask; a setting can opt into accepting automatically.
6. **Receive availability is gated on `dynamicShelf && quickShareProvider ==
   "LocalSend"`.** While that holds, the 53317 listener and the multicast
   discovery run from launch and are exempt from the idle teardown. There is no
   separate "receive" switch: the receive capability is considered part of using
   LocalSend as the share provider.
7. **Transport security is the peer's choice, and we do not require one.** Atoll
   announces `protocol: "http"`, so a peer that follows the announcement speaks
   plain HTTP. Against peers with encryption on, the *client* side presents a
   generated client certificate (mandatory since LocalSend 1.18) and trusts any
   peer certificate; the server side does not ask for one. Plain HTTP on a LAN is
   an accepted risk, not an oversight — see Consequences.
8. **Connections are bounded by activity, not by a stopwatch.** Every read has a
   30 s deadline — a sender that is really streaming delivers continuously, and a
   dropped network only becomes visible here when the silence is long enough,
   because a vanished peer sends no FIN — and a connection that has delivered less
   than 256 B/s after a two-minute grace period is closed — a trickle of one byte every 19 s satisfies
   a per-read deadline, so only a throughput floor can bound it. A wall-clock
   lifetime (30 minutes, as an earlier revision had) is simpler but wrong: it cuts
   off a legitimate multi-gigabyte upload on a slow link. The other limits are
   four concurrent uploads (a fifth is answered `409 Too many uploads in
   progress`), 64 connections overall, and 8 GiB per file. `register`/`info` sit
   outside the upload gate on purpose, so a peer streaming a file cannot make the
   Mac undiscoverable — the 64-connection ceiling can still be filled by a
   deliberate flood on the same LAN, but that window is bounded (the throughput
   floor closes such connections within ~135 s) rather than a leak.
9. **The device fingerprint is derived, not invented.** It is the SHA-256 of our
   client certificate in DER form (uppercase hex), which is upstream's
   `fingerprint_from_cert_der` and therefore also what an encrypted peer pins when
   it answers an https announcement; a persisted random value is the fallback when
   no certificate can be produced. A shared literal fingerprint once made every
   install filter every other install out of its device list.

## Consequences

- **Anyone on the LAN can offer files while the gate is open.** They cannot write
  anything without the user accepting the notch prompt (or opting into automatic
  acceptance), and they cannot use a leaked token from another address. The model
  trusts the local network and the user's click — the same trust upstream's app
  places in its own confirmation dialog. There is no allow-list, rate limit, or
  authentication.
- **A transfer that fails says so and can be dismissed**, and a transfer in
  progress can be cancelled; nothing in the receive flow ends without either
  storing the file or telling the user.
- **`~/Downloads` is the destination**, with `name (1).ext` de-duplication. A
  transfer is stored only if the announced SHA-256 matches (when one is announced)
  and, when a non-zero size was announced, the byte count matches it — up to 8 GiB.
  A sender that announces size 0 skips the size check, so its body is whatever it
  chose to send; that is the one path where a short body is stored rather than
  rejected, and it is why the checksum matters when a peer provides one.
- **Only a decision interrupts the user.** The notch opens by itself when a
  `prepare-upload` needs an answer; an automatically accepted transfer does not
  pop it open, and a completion only collapses a notch this flow opened, so a
  user who chose not to be asked is not interrupted.
- **A sender that cancels while the decision is pending** is answered `403
  Cancelled by sender`, which is upstream's mapping; a decision nobody answers
  resolves as a dropped decision and answers `500`.
- **Only one transfer runs at a time**, and only four uploads may hold a
  connection slot. `register`/`info` are deliberately outside that gate: a peer
  streaming an upload must not be able to make the Mac undiscoverable.
- **A 60 s decision window is a user-facing deadline.** A prompt that is ignored
  makes the sender fail; that is upstream's contract and is what the notch card
  says out loud.
- **Switching the share provider to AirDrop stops receiving.** That follows from
  the gate in decision 4; it is intended, and it is the most likely surprise for a
  new user.

## Alternatives considered

- **A separate receive switch.** Rejected because the receive capability is only
  meaningful together with the LocalSend share provider; a fresh install should
  not open a server it never uses. The cost is discoverability, accepted
  knowingly.
- **Trusting the token alone (no address binding).** Rejected: the token travels
  in a URL, and the binding is the only thing that makes a leaked URL useless from
  another machine.
- **Accepting everything silently.** Rejected as the default; it is available as
  an opt-in setting instead.
- **Refusing plain-HTTP peers outright.** Rejected: it would break every peer
  whose encryption is off, which is a supported configuration.
- **A wall-clock cap on a connection (30 minutes).** Rejected: it bounds a
  trickling peer only by also cutting off legitimate slow transfers; the
  throughput floor in decision 6 bounds the trickle and nothing else.
