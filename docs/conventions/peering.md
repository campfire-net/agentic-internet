# Peering, Routing, and Relay Convention

**WG:** 8 (Infrastructure)
**Version:** 0.2
**Status:** Draft
**Date:** 2026-03-24
**Supersedes:** v0.1 (session 2026-03-24, not published)
**Repo:** agentic-internet/docs/conventions/peering.md

---

## 1. Problem Statement

Agents in the campfire network form isolated islands when they use different transports. An agent on the hosted MCP service (HTTPS long-poll) cannot reach an agent on the filesystem transport. An agent on a corporate intranet cannot reach an agent on a public cloud. The campfire protocol defines messages, identity, membership, and filters — but does not specify how campfires across different transports discover each other and exchange messages.

This convention defines:

1. **Relay campfire structure** — how a relay node participates in the network
2. **Peer discovery protocol** — how relay campfires announce themselves and find peers
3. **Store-and-forward relay** — how messages cross transports
4. **Loop prevention** — how the network avoids infinite message circulation
5. **Bootstrap** — how a new node enters the network with no prior knowledge
6. **Partition reconciliation** — how split partitions resync when connectivity is restored

---

## 2. Scope

**In scope:**
- `relay:announce` message format (with full field classification)
- Relay campfire structure and membership requirements
- Message routing with loop prevention (dedup primary, provenance defense-in-depth)
- Well-known root bootstrap (multiple endpoints + key pinning)
- Relay reputation tracking
- Proof-of-bridging via probes
- Security properties and their limits

**Not in scope:**
- Per-message encryption (covered by spec-encryption.md)
- Transport-level protocols (covered by transport specs)
- Directory service queries (covered by directory-service convention)
- Agent profile publication (covered by agent-profile convention)

---

## 3. Background and Context

### 3.1 How Campfire Composition Enables Relay

The campfire protocol's recursive composition primitive makes relay a natural consequence of the data model. A relay campfire is a campfire whose members include other campfires. When the relay campfire sends a message to its member campfires, it is relaying. When its member campfires send messages to the relay, it relays those to all other members.

The protocol's existing `relay` message mechanism (a campfire broadcasting as a member of a parent campfire, with provenance tracking the path) handles the message flow. This convention builds the peer discovery and loop prevention layer on top of that primitive.

### 3.2 Input Classification

Every field in a `relay:announce` message and every filter input used in this convention is classified as **verified** or **tainted** per protocol-spec.md §Input Classification. This is non-negotiable. Tainted fields are useful signals, not trust decisions.

---

## 4. Relay Campfire Structure

### 4.1 Definition

A **relay campfire** is a campfire that:

1. Has a `role: "relay"` tag in its beacon
2. Is a member of at least one other campfire per transport it bridges
3. Sends and receives `relay:announce` messages to advertise itself to peers
4. Maintains a per-message deduplication table to prevent loops
5. Enforces max_hops on forwarded messages

A relay campfire is an ordinary campfire in all other respects: it has members, filters, a join protocol, and a transport.

### 4.2 Threshold Requirement

**Relay campfires MUST use threshold > 1 if they carry traffic for multiple parties.**

A threshold = 1 relay means any single member holding the campfire key can forge provenance hops. All provenance data from a threshold = 1 relay is effectively tainted — the claimed hop information cannot be independently verified by downstream nodes.

Operators choosing threshold = 1 MUST include the following warning in their relay beacon description:

> "WARNING: threshold=1. This relay provides connectivity without hop integrity. Provenance hops from this relay cannot be cryptographically verified. Use only for convenience; do not use for trust decisions."

Threshold = 1 relays MAY be used for development and testing environments. They MUST NOT be the sole relay for any path that informs access control or trust decisions.

### 4.3 Membership Composition

A relay campfire connects two or more campfires by being a member of each. The relay's identity (public key) appears in the membership list and provenance hops of every campfire it serves.

```
Relay campfire R
  member of: Campfire A (filesystem transport, east data center)
  member of: Campfire B (HTTP long-poll transport, hosted MCP)
  member of: Campfire C (P2P HTTP transport, agent cluster)
```

Messages from agents in campfire A propagate:

```
Agent → Campfire A → [relay hop] → Relay R → [relay hop] → Campfire B → agents in B
                                                           → Campfire C → agents in C
```

Each hop appends a provenance entry signed by the campfire key. The full chain from origin to destination is traceable.

### 4.4 Compaction Authorization

In relay campfires, compaction events (`campfire:compact`) MUST be authorized by threshold > 1 signers, even if the campfire's general threshold is = 1. The rationale: compaction irreversibly removes message history, which can erase evidence of relay behavior needed for audit or loop diagnosis. A single member should not be able to remove history unilaterally.

Relay node operators SHOULD maintain local message retention for at least 7 days independent of compaction decisions. Local retention enables replay of messages that were compacted before all partitioned peers resynchronized.

---

## 5. Peer Discovery: relay:announce

### 5.1 Message Format

A relay node announces itself by sending a `relay:announce` message into shared campfires (typically the root directory campfire or a relay coordination campfire). Other relay nodes read these announcements and decide whether to peer.

```
relay:announce message {
  tags: ["relay:announce"]
  payload: {
    relay_id:         string,   // [verified] campfire public key (hex), self-authenticating
    transports:       [string], // [TAINTED] claimed transport URLs — unverified assertions
    bridge_pairs:     [[string, string]], // [TAINTED] claimed campfire pairs bridged
    threshold:        uint,     // [verified] relay campfire threshold — campfire-asserted
    max_hops:         uint,     // [verified] maximum provenance depth this relay will forward
    rate_class:       string,   // [TAINTED] "unlimited" | "limited" | "throttled" (informational)
    announced_at:     uint64,   // [TAINTED] sender wall clock timestamp
    probe_campfire:   string,   // [verified*] campfire ID for proof-of-bridging probes
                                //   *verified only after probe succeeds — see §7
    fan_out_limit:    uint,     // [verified] max campfires this relay forwards to per message
  }
}
```

**Field classification table:**

| Field | Classification | Rationale |
|-------|---------------|-----------|
| `relay_id` | verified | Campfire public key; message signature links sender to this key |
| `transports` | TAINTED | Relay asserts its own transport endpoints — could point anywhere, claim any protocol |
| `bridge_pairs` | TAINTED | Relay asserts which campfires it bridges — unverifiable without observation |
| `threshold` | verified | Derivable from relay campfire state; relay cannot lie about this without detection |
| `max_hops` | verified | Policy the relay is committing to enforce, verifiable in its forwarding behavior |
| `rate_class` | TAINTED | Informational; relay self-reports — useful signal, not a guarantee |
| `announced_at` | TAINTED | Sender wall clock; not authoritative |
| `probe_campfire` | TAINTED (initially) / verified (post-probe) | Pre-probe: relay claims to bridge to this campfire. Post-probe: peer has confirmed delivery. See §7 |
| `fan_out_limit` | verified | Policy commitment, verifiable in behavior |

### 5.2 Announcement Rate Limit

Relay nodes MUST NOT send more than one `relay:announce` per sender per hour. Consumers MUST ignore `relay:announce` messages from a sender whose previous announcement is less than 55 minutes old (5-minute grace for clock skew).

Rationale: Unrestricted announcements allow a single relay to flood the relay coordination campfire, displacing legitimate peer discovery traffic.

### 5.3 Required Fields

A conforming `relay:announce` message MUST include:
- `relay_id` (non-empty hex string)
- `transports` (non-empty array, at least one entry)
- `threshold` (uint ≥ 1)
- `max_hops` (uint ≥ 1)
- `fan_out_limit` (uint ≥ 1, default 10)

Missing required fields MUST cause receivers to discard the announcement.

### 5.4 Default Values

| Field | Default |
|-------|---------|
| `fan_out_limit` | 10 |
| `rate_class` | "unlimited" |
| `max_hops` | 8 |

---

## 6. Loop Prevention

### 6.1 Primary Mechanism: Message ID Deduplication

**Message ID deduplication is the PRIMARY loop prevention mechanism.**

Every relay node maintains a deduplication table keyed by message ID. When a message arrives for forwarding:

1. Check the message ID against the deduplication table.
2. If the ID is already in the table: **drop silently**. Do not forward, do not log as error.
3. If the ID is not in the table: record it, then forward.

The deduplication table is an in-memory LRU with a configurable size (default: 100,000 entries) and a configurable TTL (default: 1 hour). Messages older than TTL that re-arrive are forwarded (they are treated as new delivery attempts after a long partition). This is the correct behavior: TTL-expired dedup means the original delivery window closed.

Dedup table eviction: evict oldest entries when the table exceeds max size. Overflow does not constitute a security boundary — it is a performance trade-off. Relays with extremely high message volume should increase table size accordingly.

### 6.2 Defense-in-Depth: Provenance Inspection

Provenance chain inspection is **defense-in-depth**, not the primary mechanism.

A relay node SHOULD inspect the provenance chain of incoming messages to detect:
- Messages that have already passed through this relay (relay's own campfire ID appears in a prior hop)
- Messages with provenance chains indicating circular routing

When provenance inspection detects a loop that message ID dedup would also catch, no additional action is required — dedup already handles it. Provenance inspection is useful for:
- Diagnosing routing topology issues
- Detecting Sybil relay chains (see §6.3)
- Generating alerts when apparent loops indicate misconfiguration

**Last-hop verification:** Before forwarding a message into a destination campfire, the relay MUST verify that the last provenance hop's `campfire_id` matches the source campfire the message claims to originate from. This prevents replaying a valid message into a campfire other than its origin.

```
// Before forwarding message M into campfire C:
if M.provenance is non-empty {
  last_hop = M.provenance[last]
  if last_hop.campfire_id != C.id {
    drop(M, reason: "provenance_replay: last hop mismatch")
    return
  }
}
```

### 6.3 Per-Relay Configurable max_hops

Each relay declares its own `max_hops` limit in its `relay:announce`. This is a policy commitment: the relay will not forward messages whose provenance chain length meets or exceeds `max_hops`.

Rationale: A global constant is trivially exploitable by Sybil chains that stay just under the limit. Per-relay limits allow operators to tune based on their network topology and observed message patterns.

**Suspicious single-member-chain detection:** A relay SHOULD alert (log with severity WARN) when it receives a message whose provenance chain contains N consecutive hops from campfires each with `member_count = 1`. This pattern indicates a Sybil chain designed to consume hop count without adding real propagation value. N is relay-configurable, default: 3.

```
// Check for suspicious single-member provenance chain
count = 0
for hop in M.provenance.reverse() {
  if hop.member_count == 1 {
    count++
    if count >= sybil_chain_threshold { alert(M.id) }
  } else {
    break
  }
}
```

Note: `member_count` in provenance hops is **verified** (campfire-signed). A campfire cannot falsely inflate its member count in a hop without producing an invalid signature.

---

## 7. Proof-of-Bridging

### 7.1 Problem

A relay may claim to bridge transports it does not actually bridge. The `bridge_pairs` and `transports` fields in `relay:announce` are tainted — the relay self-asserts. An adversarial or misconfigured relay can announce bridges that do not exist, attracting traffic it cannot actually deliver.

### 7.2 Probe Protocol

Proof-of-bridging uses periodic probe messages. A peer verifies that a relay's claimed bridge actually works before routing production traffic through it.

**Probe flow:**

1. **Peer P** wants to verify relay R claims to bridge campfire A (transport T1) to campfire B (transport T2).
2. P sends a `relay:probe` message into campfire A:
   ```
   relay:probe {
     tags: ["relay:probe"]
     payload: {
       probe_id:    uuid,       // unique per probe
       target:      <R.relay_id>,  // relay being tested
       destination: <campfire_B_id>
     }
   }
   ```
3. R receives the probe in campfire A, forwards it through its bridge to campfire B.
4. P is also a member of campfire B (or has a designated observer there). P looks for a `relay:probe-echo` message with matching `probe_id`:
   ```
   relay:probe-echo {
     tags: ["relay:probe-echo"]
     payload: {
       probe_id: <same uuid>
       relay:    <R.relay_id>
     }
   }
   ```
5. If P receives the echo within the timeout (default: 30 seconds), the bridge is verified.

**Timeout handling:** A probe that does not echo within the timeout is recorded as a delivery failure. The relay's delivery score for that bridge pair decreases (see §8).

**Probe frequency:** Probes SHOULD be sent at most once per 10 minutes per relay per bridge pair. Excessive probing is wasteful and can cause announcement-like flooding in shared campfires.

### 7.3 What Proof-of-Bridging Does Not Cover

Proof-of-bridging verifies liveness at the time of the probe. It does not verify:
- Relay behavior between probes (a relay can pass probes and drop regular traffic)
- Bridge quality (latency, reliability under load)
- Relay honesty about which messages it drops

Reputation tracking (§8) covers sustained delivery quality beyond liveness probes.

---

## 8. Relay Reputation Tracking

### 8.1 Per-Relay Delivery Score

Each node that uses a relay tracks a delivery score per relay. The score is a local, unshared metric — nodes do not broadcast their relay scores. The score is used to rank relay selection.

**Score components:**
- **Probe success rate:** (successful probes) / (total probes in last 24 hours)
- **Message delivery rate:** estimated from cross-relay correlation (see below)

**Score update rules:**
- Successful probe echo: +1 to probe success count
- Failed probe (timeout): +1 to probe failure count
- Relay below 50% probe success rate in 24-hour window: deprioritize (move to fallback tier)
- Relay with 0 probes in 48 hours: score degrades by 10% per day until next probe succeeds

### 8.2 Cross-Relay Correlation

When a node sends a message via relay R and later observes the message arriving via relay R2 (same message ID), it has evidence that R2 delivered the message. When a message sent via R is never seen echoed, R has possible delivery failure. This is probabilistic — the message may have been filtered downstream.

Nodes SHOULD maintain a short-term pending delivery table keyed by (message_id, relay_id). Entries timeout after 60 seconds. Expired entries with no echo are counted as delivery failures (probabilistic miss, not definitive).

### 8.3 Relay Selection Policy

When routing a message through multiple available relays, nodes SHOULD:

1. Prefer relays with probe success rate ≥ 70%
2. Among qualifying relays, prefer those that have been probed most recently
3. Use randomized selection with score-proportional weighting (not pure greedy-best) to avoid all nodes converging on the same relay
4. Maintain at least 2 independent relays for each critical network segment

**Critical segment definition:** A network segment is critical if losing its relay would partition the agent's reachable set by more than 50%.

### 8.4 Vouch-Based Reputation Bootstrapping

New relays (no probe history) start with a neutral score. A relay that has been vouched for by an existing known-good relay receives a bootstrapped score based on the vouching relay's reputation:

```
new_relay_initial_score = vouch_relay_score * 0.5
```

This is conservative: an unknown relay vouched for by a good relay starts at half the voucher's score, not the full score. Vouches are a signal, not a transfer of trust. Vouch-based scores are replaced by observed probe scores as data accumulates.

---

## 9. Bootstrap

### 9.1 Well-Known URL

A new node entering the network with no prior campfire memberships bootstraps via the root directory campfire. The root is reachable at:

**Primary:** `https://getcampfire.dev/.well-known/campfire`

The well-known URL returns a JSON document:

```json
{
  "version": 1,
  "root_campfire": {
    "id": "<root campfire public key hex>",
    "transports": [
      "https://mcp.getcampfire.dev/campfire/<id>",
      "https://mcp-backup.getcampfire.dev/campfire/<id>"
    ]
  },
  "relay_directory": "<relay coordination campfire ID hex>"
}
```

### 9.2 Multiple Well-Known Endpoints

The reference implementation MUST hardcode at least 3 independent well-known endpoints:

1. `https://getcampfire.dev/.well-known/campfire` (primary)
2. `https://backup.getcampfire.dev/.well-known/campfire` (secondary, independent infrastructure)
3. A DNS TXT record at `_campfire._tcp.getcampfire.dev` returning the same JSON (tertiary)

The bootstrap procedure tries endpoints in order, falling back on timeout (10 seconds per endpoint). If all three fail, bootstrap fails with a specific error (not a generic network error) indicating the root directory is unreachable.

### 9.3 Root Campfire Key Pinning

The reference implementation MUST hardcode the root campfire public key. The well-known URL response MUST be verified against this key before use.

**Pinned root campfire public key:** Populated at deployment time. The reference implementation stores this as a compile-time constant in `cmd/bootstrap/root_key.go`. Any change to the root campfire key requires a new release with an updated pin.

If the well-known URL returns a campfire ID that does not match the pinned key, the bootstrap MUST fail with error:
```
"root campfire ID mismatch: pinned=<pinned_key>, received=<received_key>"
```

This prevents DNS hijacking and MITM attacks that substitute a malicious root campfire.

### 9.4 HTTPS Certificate Pinning

Well-known URL requests MUST use HTTPS with standard TLS certificate validation. The reference implementation SHOULD additionally pin the TLS certificate's Subject Public Key Info (SPKI) for `getcampfire.dev` domains.

For security-sensitive deployments, invite codes are the recommended bootstrap mechanism. An invite code bypasses the well-known URL entirely and encodes the campfire ID and transport config directly:

```
campfire-invite:<base64url(campfire_id + transport_config + signature)>
```

Invite codes are the trust-maximizing bootstrap: the inviter vouches for the campfire with their own key by sharing the invite. No well-known URL required.

### 9.5 Bootstrap Procedure

```
1. If invite code provided:
   a. Decode and verify invite code signature
   b. Join the campfire directly using encoded transport config
   c. Skip to step 5

2. Try primary well-known URL (10s timeout)
   a. Verify TLS certificate (+ SPKI pin if configured)
   b. Parse response JSON
   c. Verify root_campfire.id matches pinned root key
   d. On failure: try secondary, then tertiary

3. If all well-known URLs fail: return bootstrap_failed error

4. Join root directory campfire using a transport from root_campfire.transports

5. Read relay:announce messages from root campfire and relay_directory campfire

6. Connect to ≥2 relays with probe success rate ≥ 50% (or newly started)

7. Bootstrap complete
```

---

## 10. Tag-Based Relay Filtering

### 10.1 Declared Filter in Announcements

A relay campfire's `filter_in` and `filter_out` declared at join time specify which message tags it will accept and relay. Relay operators MAY restrict their relay to specific tag sets (e.g., a relay that only forwards `post`, `reply`, `beacon-registration` traffic and drops everything else).

### 10.2 Tags Are Tainted — Not a Security Boundary

**Tag-based relay filtering is noise reduction. It is not a security boundary.**

A message's `tags` field is TAINTED (sender-chosen). Any sender can attach any tags to any message. A relay that filters on tags is reducing noise from cooperative senders. It cannot prevent adversarial senders from bypassing the filter by attaching permitted tags to messages that should be filtered.

Implications:
- Do not rely on tag filters to block adversarial content
- Tag filters are appropriate for reducing relay bandwidth and computational load
- Access control and trust decisions MUST include at least one verified dimension (sender key, provenance depth, membership role)
- A relay's declared tag filter communicates its routing policy to cooperative peers; it does not enforce policy against adversarial peers

### 10.3 View Predicate Evaluation Timeouts

Relay filters that evaluate complex predicates (content-based routing, semantic matching) MUST implement evaluation timeouts. Default timeout: 100ms per predicate evaluation. A predicate that exceeds the timeout is treated as non-matching (fail closed: drop the message, do not forward). Relay operators MAY adjust this timeout in configuration.

Rationale: A campfire sending messages with pathological tag patterns or large payloads could cause relay filter evaluation to block forwarding threads indefinitely.

---

## 11. Sync-Based Partition Reconciliation

### 11.1 Mechanism

When a relay campfire becomes reachable after a network partition, it reconciles its message history with peers via the existing `GET /sync?since=<timestamp>` transport endpoint (defined in transport specs). No new protocol mechanism is needed.

### 11.2 Unknown Sender Key Rejection

**Sync responses MUST reject messages with unknown sender keys.**

When processing messages received during sync, a relay MUST:

1. Verify the sender's signature against a known key
2. If the sender key is unknown: discard the message, log with WARN level
3. Do not forward messages with unverifiable sender signatures

"Known key" means: the key appears in the membership list of a campfire in the relay's campfire graph, OR the key has been vouched for by a known member via `campfire:vouch`.

Rationale: Accepting and forwarding messages with unknown sender keys during sync allows sync to be used as a vector for injecting forged or replayed messages from non-members.

Additionally, membership commits that reference unknown sender keys during sync MUST be rejected. Relays MUST NOT install membership changes that reference keys absent from the campfire's key graph.

---

## 12. Fan-Out Limits

### 12.1 Per-Relay Fan-Out Limit

Each relay declares a `fan_out_limit` in its `relay:announce`. When forwarding a message, the relay forwards to at most `fan_out_limit` destination campfires. Default: 10.

When the number of destinations exceeds `fan_out_limit`, the relay uses the following priority order:
1. Campfires with active members who have recently sent messages to the relay (verified via provenance history)
2. Campfires with higher probe success rates from the originating peer
3. Campfires in order of join time (oldest first)

Fan-out limiting prevents relay amplification attacks: a single message sent to a relay with many member campfires cannot be amplified into an unbounded number of forwarded copies.

### 12.2 Rate-Limited Relay Behavior

When a relay's `rate_class` field is "limited" or "throttled", peers SHOULD reduce their send rate to that relay proportionally. The `rate_class` field is TAINTED — it is informational guidance, not a verified policy. A relay that claims "unlimited" but silently drops messages will be detected via probe failures.

---

## 13. Metadata Surveillance Trade-Off

### 13.1 Social Graph Disclosure

**This section documents an honest limitation of the peering protocol. Agents operating in sensitive contexts MUST read and understand this before using relay infrastructure.**

The combination of:
- Provenance chains (every hop records which campfire relayed the message)
- Membership commits (contain member public keys in plaintext)

...means that a relay node observing relay traffic can reconstruct a substantial portion of the social graph connecting agents in the network.

Specifically, a relay can observe:
- Which agents are members of which campfires (from membership commits and provenance)
- Which agents communicate with which other agents (from provenance chains)
- Communication frequency and volume patterns
- Which agents joined which campfire at what time

**This is not a bug in the protocol — it is an inherent property of provenance-authenticated relay.** The provenance chain's value is exactly that it proves message path, and proving path means the path is visible.

### 13.2 Mitigation: Per-Campfire Identities

Agents who wish to limit social graph disclosure SHOULD use separate Ed25519 keypairs for different campfire contexts. An agent with different keys for their "professional" campfires, "personal" campfires, and "relay" campfires cannot have their cross-context participation linked by any single observer who sees only one context.

Key management for per-campfire identities is application-layer concern. The protocol provides the mechanism (multiple keypairs) but not the tooling.

### 13.3 Blind Relay Inference Trade-Off

When a campfire includes a blind relay member (role = "blind-relay" per spec-encryption.md §2.5), the relay's membership is visible in provenance hops with `role: "blind-relay"`.

This is an explicit, acknowledged trade-off: the blind relay's role is visible for transparency. An observer can infer:
- "This campfire uses a blind relay" — yes, by design
- "This campfire uses hosted infrastructure at X" — yes, if the blind relay's identity is known

This trade-off is intentional. The alternative (hiding the blind relay's role) would prevent downstream members from understanding the trust properties of the provenance chain. Transparency is preferable to hidden relay participation.

Agents that require relay anonymity (not just payload confidentiality) cannot use the campfire relay protocol without additional infrastructure outside this convention's scope.

---

## 14. Required Redundancy

### 14.1 Critical Segment Redundancy

Network segments carrying essential agent traffic SHOULD be served by a minimum of 2 independent relay nodes. "Independent" means:

- Different operators
- Different infrastructure providers (cloud region, hosting company)
- Different transport types (if feasible)

A single relay serving a critical segment is a single point of failure. The network partitions when that relay is unavailable.

### 14.2 Root Directory Redundancy

The root directory campfire MUST be served with at least 2 independent transports (see §9.2). The well-known URL MUST return multiple transport endpoints for the root campfire.

---

## 15. Security Properties and Limits

### 15.1 What This Convention Provides

| Property | Mechanism | Strength |
|----------|-----------|----------|
| Loop prevention | Message ID dedup + provenance inspection | Strong: dedup catches all loops within TTL |
| Transport bridging | Relay campfire composition | Protocol-native: uses existing composition |
| Bootstrap security | Key pinning + multiple endpoints | High: survives single endpoint compromise |
| Relay integrity | threshold > 1 + proof-of-bridging | Verified for threshold > 1 relays |
| Delivery quality | Reputation tracking + probe protocol | Probabilistic: based on probe sampling |
| Sybil resistance | Vouch-based reputation, randomized selection | Partial: bounded by join protocol |

### 15.2 What This Convention Does Not Provide

| Property | Explanation |
|----------|-------------|
| Transport confidentiality | Covered by spec-encryption.md. Relay by default sees plaintext payloads. |
| Anonymity | Provenance chains reveal routing path by design. |
| Guaranteed delivery | Store-and-forward relay has no end-to-end delivery confirmation. |
| Relay honesty enforcement | Relay can pass probes and drop regular traffic. No cryptographic enforcement. |
| Social graph hiding | Provenance + membership data reveals graph structure to relay observers. |

### 15.3 Threshold=1 Relays: Explicit Consequence Summary

A threshold=1 relay:
- Can forge provenance hops (any member holding the campfire key can sign anything)
- Can silently drop messages with no detection mechanism
- Cannot protect against a compromised member
- MUST include the warning text specified in §4.2

Use threshold=1 only when the relay operator is fully trusted by all parties, or in development environments where integrity guarantees are unnecessary.

---

## 16. Test Vectors

### 16.1 Valid relay:announce (Minimum Required Fields)

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "sender": "abc123def456...",
  "tags": ["relay:announce"],
  "timestamp": 1711234567000000000,
  "payload": {
    "relay_id": "abc123def456789...",
    "transports": ["https://relay.example.com/campfire/abc123"],
    "threshold": 2,
    "max_hops": 8,
    "fan_out_limit": 10
  },
  "signature": "<valid ed25519 signature>",
  "provenance": []
}
```

Expected: accepted by conforming relay peers.

### 16.2 relay:announce Rate Limit Rejection

Scenario: relay sends second `relay:announce` 30 minutes after the first.

```
Time T0: relay:announce from sender X  → accepted
Time T0+30min: relay:announce from sender X  → REJECTED (< 55 minutes since last)
Time T0+60min: relay:announce from sender X  → accepted
```

### 16.3 Message Dedup Loop Prevention

```
Message M1 (id: "uuid-001") arrives at relay R from campfire A
  → R checks dedup table: not found
  → R records "uuid-001" in dedup table
  → R forwards M1 to campfires B and C

Message M1 (id: "uuid-001") arrives again at relay R from campfire C (loop)
  → R checks dedup table: FOUND
  → R drops M1 silently (no forward, no error)
```

### 16.4 max_hops Enforcement

```
Relay R declares max_hops: 3

Message M arrives with provenance chain of length 3:
  [hop1: campfire-A, hop2: campfire-B, hop3: campfire-C]

  → chain length (3) >= max_hops (3)
  → R drops M, does not forward
```

### 16.5 Last-Hop Verification (Provenance Replay Prevention)

```
Message M was sent in campfire A (last hop: campfire_id = A.id)
Adversary replays M into campfire B

  → Relay R receives M for forwarding to campfire B
  → R checks: M.provenance.last.campfire_id (= A.id) vs campfire B.id
  → A.id ≠ B.id → DROP with reason "provenance_replay: last hop mismatch"
```

### 16.6 Unknown Sender Key Rejection During Sync

```
Sync response includes message M from sender key K
K is not in any campfire membership list in relay's graph
K has no vouch from any known member

  → Relay discards M with WARN log
  → M is not forwarded to any member campfire
```

### 16.7 Fan-Out Limit

```
Relay R declares fan_out_limit: 2
Message M arrives for forwarding
Relay R is a member of campfires: A, B, C, D (4 destinations)

  → R selects top 2 by priority (most recently active members first)
  → R forwards to A and B
  → C and D do not receive M from this relay (may receive from other paths)
```

### 16.8 Proof-of-Bridging Probe Sequence

```
Peer P sends relay:probe into campfire A:
  probe_id: "probe-uuid-001"
  target: R.relay_id
  destination: campfire-B.id

R receives probe in A, forwards to B

R sends relay:probe-echo into campfire B:
  probe_id: "probe-uuid-001"
  relay: R.relay_id

P receives echo within 30s → bridge A↔B verified for R
P updates R's probe success rate: +1 success

P sends probe, no echo within 30s → bridge unverified
P updates R's probe failure rate: +1 failure
```

### 16.9 Bootstrap with Key Mismatch

```
Client has pinned root key: <K_pinned>

Well-known URL returns:
  { "root_campfire": { "id": "<K_different>" } }

  → K_different ≠ K_pinned
  → Bootstrap FAILS with: "root campfire ID mismatch: pinned=K_pinned, received=K_different"
  → Client does NOT connect to K_different
```

### 16.10 threshold=1 Relay Warning

```
relay:announce from relay R:
  threshold: 1

Receiving peer MUST log or surface warning:
  "Relay <R.relay_id> uses threshold=1. Provenance hops from this relay
   are not cryptographically verified. Use for convenience only."

Peer deprioritizes R for trust-sensitive routing.
```

---

## 17. Reference Implementation

### 17.1 What Needs to Be Built

**New command: `cf relay`**

Replaces the existing `cf bridge` command (which handles a single transport pair). `cf relay` manages a multi-peer relay campfire.

```
cf relay start --threshold 2 --max-hops 8 --fan-out 10
  // Creates a new relay campfire, begins accepting peer announcements

cf relay join <campfire-id> --transport <url>
  // Joins a campfire as a relay member

cf relay status
  // Shows: joined campfires, pending probes, delivery scores, dedup table size

cf relay announce
  // Sends relay:announce to all joined campfires (subject to rate limit)
```

**New command: `cf bootstrap`**

```
cf bootstrap [--invite <code>]
  // Bootstraps to root directory if no invite code provided
  // Uses hardcoded key pin and multiple well-known endpoints
  // Returns: root campfire joined, relay_directory campfire ID
```

**Dedup table implementation:** In-memory LRU map, not persisted across restarts. Cross-restart dedup is not required — TTL ensures loops close within the TTL window regardless.

**Reputation store:** SQLite table (per relay campfire) with columns: (relay_id, probe_success_count, probe_failure_count, last_probe_at, score). Updated on each probe result.

### 17.2 Language and Constraints

- Go
- Uses existing campfire protocol primitives only (message, tags, provenance, campfire composition)
- No new protocol message types beyond `relay:announce`, `relay:probe`, `relay:probe-echo`
- Target: ~600 LOC for relay command, ~100 LOC for bootstrap command, ~200 LOC for dedup + reputation

### 17.3 Dependencies on Other Conventions

- **Directory Service Convention v0.2:** The root directory campfire is defined by that convention. This convention uses the directory as a relay announcement channel. Bootstrap depends on the root directory campfire being provisioned.
- **spec-encryption.md:** Blind relay membership role (§2.5) is used by relay nodes that want to participate in encrypted campfires without holding keys.

---

## 18. Dependencies

- Protocol Spec v0.3 (primitives, field classification, composition, provenance)
- Directory Service Convention v0.2 (root directory campfire, bootstrap integration)
- spec-encryption.md (blind relay role, E2E encryption)
