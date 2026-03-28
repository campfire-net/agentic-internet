---
document: application-persistence
version: "0.1"
date: 2026-03-28
---

# Application-Owned Persistence Guide

This guide is for developers building applications on campfire that need durable state. It is the consumer-side companion to the [Campfire Durability Convention v0.1](conventions/campfire-durability.md) — that convention tells operators how to declare durability metadata; this guide tells application developers how to consume it and design their storage accordingly.

---

## Problem Statement

`rd` (the Rudi work-management CLI) stores work items as messages in campfire. When a campfire was hosted on `/tmp`, state was lost on restart. The application had no warning, no fallback, and no recovery path.

This is the canonical failure mode for applications that treat campfire as their database. Campfire is a coordination protocol. Its storage guarantees are operator-defined, not protocol-guaranteed, and they can change without notice. Applications that do not own their own persistence will lose state.

The fix is not "find a campfire with better guarantees." The fix is: **own your state. Use campfire as the coordination and sync layer, not the source of truth.**

---

## Three Principles

**1. A campfire is the authoritative source for its own message state.**

If the campfire says a message is gone — due to TTL expiry, compaction, or lifecycle end — it is gone. There is no appeal. Applications that rely solely on campfire storage have no recourse when this happens.

**2. Campfires may change state without notice.**

TTL expiry, compaction, and operator lifecycle decisions happen without warning to participants. A campfire that declared `lifecycle:persistent` last week may be gone today. A campfire re-publishing its beacon may omit durability tags it previously declared, which is treated as a claim withdrawal. Applications must not assume continuity.

**3. Campfire continuity is not guaranteed — ephemeral or persistent is an operator choice.**

The protocol is neutral on storage duration. Whether a campfire retains messages for one hour or forever is entirely up to the operator and whatever infrastructure backs it. Applications cannot determine this from the protocol alone — they must evaluate durability claims using the trust model.

---

## Tiered Storage Model

The same application should work at any scope: one project, multiple projects, or multiple machines. Rather than designing for the hardest case from the start, structure storage in three tiers with a common interface. The storage backend changes; the application API does not.

```
Tier 1: Single project
  └─ JSONL file in the project repo
  └─ git distributes, version controlled, works offline
  └─ limited to one machine / one repo

Tier 2: Multi-project
  └─ JSONL file in home directory (~/.config/<app>/)
  └─ filesystem-local, crosses project boundaries
  └─ limited to one machine

Tier 3: Multi-host
  └─ campfire protocol as the network layer
  └─ messages carry state mutations (create, update, close)
  └─ local JSONL is the materialized view
  └─ every participant sees mutations; no single host is privileged
```

### Promotion

Move between tiers when scope grows:

- **Tier 1 → 2**: You need the same state visible across multiple projects on one machine. Copy the JSONL to `~/.config/<app>/`, update config to point there. No schema change.
- **Tier 2 → 3**: You need the same state across multiple machines. Start syncing mutations via campfire. Keep the local JSONL as the materialized view. No schema change — you are adding a sync layer, not replacing the storage layer.

Promotion is a one-way operation in practice. Demoting from tier 3 back to tier 2 means accepting that you will lose any state changes that happened on other hosts while you were disconnected.

### Same Interface at Every Tier

Design the application's storage interface against an abstract backend:

```
read(query) -> []Item
write(mutation) -> Item
list(filter) -> []Item
```

At tier 1, the implementation reads/writes JSONL directly. At tier 2, same implementation, different file path. At tier 3, `write` also posts a mutation message to the campfire; `read` queries the local materialized view, not the campfire directly.

If you find yourself calling campfire APIs in your application's query path, you are using campfire as a database. Move the query to the local copy.

---

## Evaluating Campfire Durability for Tier 3

Before choosing a campfire as your tier 3 transport, read its durability metadata from the beacon. Do this before committing any state.

### What to Look For

Durability metadata appears as tags in the campfire's beacon (Campfire Durability Convention v0.1 §4):

| Tag | Meaning |
|-----|---------|
| `durability:max-ttl:0` | Messages retained indefinitely (keep-forever) |
| `durability:max-ttl:<N><unit>` | Messages retained up to N units (e.g., `30d`) |
| `durability:lifecycle:persistent` | Campfire is indefinitely maintained |
| `durability:lifecycle:ephemeral:<timeout>` | Campfire closes after timeout of inactivity |
| `durability:lifecycle:bounded:<date>` | Campfire has a planned end date |
| *(absent)* | Unknown retention — treat as ephemeral |

For tier 3, you want both `durability:max-ttl:0` (or a long TTL) and `durability:lifecycle:persistent`. Either tag alone is partial information.

### The Trust Table

Durability tags are tainted claims — assertions by the campfire owner with no protocol enforcement. Evaluate them using operator provenance (Operator Provenance Convention v0.1):

| Operator provenance level | Weight to give durability claims |
|--------------------------|----------------------------------|
| getcampfire.dev hosted (metered tier) | High — infrastructure-backed, platform reputation |
| `provenance:operator-verified` | Medium — accountable operator, domain-verified |
| `provenance:basic` | Low — email-verified, limited accountability |
| `provenance:unverified` | Minimal — treat tags as unknown |
| No provenance info | Unknown — same as unverified |

**Do not store irreplaceable state in campfires with `provenance:unverified` operators, regardless of what their durability tags claim.**

### Absent Durability Tags

A campfire with no `durability:*` tags makes no durability claim. Treat it as unknown retention. This is not an error in the beacon — many campfires are purely operational and have no reason to declare persistence. But from your application's perspective, unknown retention = treat as ephemeral.

### Observation Is the Only Validation

Provenance checks tell you who the operator is. They do not tell you whether the operator's storage backend survives a reboot. A verified operator with a `/tmp` backend loses your data.

The only real validation is observation over time: check whether messages you sent are still retrievable after a fraction of the declared TTL has elapsed. This is a long tail — you won't know until time passes. For applications that cannot tolerate loss, an out-of-band SLA with a hosted platform (getcampfire.dev metered tier) is the strongest assurance available.

Re-read beacon metadata at each session start. A campfire that re-publishes its beacon without durability tags has effectively withdrawn its claim. A downgrade from `lifecycle:persistent` to `lifecycle:ephemeral:1h` should trigger a warning to your users and a migration plan.

---

## The Local-Copy Pattern

At tier 3, the application maintains a local JSONL copy and syncs via campfire. The campfire is the transport; the local copy is the source of truth for queries.

```
┌─────────────────────────────────────────────────────┐
│  Application                                        │
│                                                     │
│  write(mutation)                                    │
│    → append to local JSONL                          │
│    → post mutation message to campfire              │
│                                                     │
│  read(query)                                        │
│    → query local JSONL (never query campfire)       │
│                                                     │
│  on join / reconnect                                │
│    → replay missed campfire messages                │
│    → update local JSONL                             │
│                                                     │
│  on disconnect                                      │
│    → continue operating from local JSONL            │
│    → buffer pending mutations                       │
│    → flush on reconnect                             │
└─────────────────────────────────────────────────────┘
```

### Mutation Messages

State changes become campfire messages carrying enough information to reconstruct the new state. For a work item system, a mutation message might be:

```json
{
  "tags": ["work:item:update"],
  "payload": {
    "id": "rd-abc123",
    "status": "closed",
    "reason": "implemented in commit a1b2c3d",
    "closed_at": "2026-03-28T14:00:00Z",
    "actor": "<agent-pubkey>"
  }
}
```

Every participant that receives this message can update their local copy. The campfire log is an ordered mutation stream; the local JSONL is the materialized view.

### Rebuilding State on Join

When an agent joins (or rejoins after a gap), it reads the campfire's message history and replays any mutations it missed, applying them to its local copy. This is eventual consistency — the local copy converges to the campfire's state as messages arrive.

Replay is bounded by the campfire's `max-ttl`. If the campfire has `max-ttl:30d` and your agent was offline for 45 days, you cannot fully replay from the campfire. Your local copy at the point of disconnection is your starting state; you've missed 15 days of mutations. Applications that cannot tolerate this gap need a different recovery strategy (full-state snapshot messages, a peer that stayed connected, or a hosted campfire with `max-ttl:0`).

### Conflict Resolution

When multiple agents write concurrently, mutations may conflict. Two strategies:

**Last-writer-wins:** Each mutation carries a timestamp and actor key. On conflict, the later timestamp wins. Simple, correct for most work management scenarios where the conflict is rare and the user can see the history.

**Application-defined merge:** The application defines a merge function for conflicting mutations. Required when concurrent writes to the same record are common and last-writer-wins produces unacceptable data loss.

The campfire message order is the canonical ordering for last-writer-wins. If two mutations arrive in order A then B, B wins — regardless of the timestamps in the payload. Payload timestamps are useful for display ("edited 3 minutes ago") but not for conflict resolution.

---

## When NOT to Use Campfire for State

Campfire is a message log over a coordination protocol. It is the wrong tool for:

**Secrets, credentials, keys.** Never put secrets in campfire messages, even in campfires you control. Use a secrets manager. The campfire log is replicated to all members.

**Large binary blobs.** Campfire is a message log, not a file store. Put the blob in object storage, reference it by URL in the campfire message.

**ACID transactions.** Campfire is eventually consistent. If your application requires atomic multi-record operations with rollback, use a database. Campfire can notify participants that a transaction happened, but it cannot execute one.

**State where loss is catastrophic and unrecoverable.** If losing one mutation would permanently corrupt your application state, campfire's eventual consistency model is not appropriate, even with a hosted `max-ttl:0` campfire. Use a database with WAL. Use campfire to broadcast that writes happened, not to hold the writes.

---

## Ready's Implementation

`rd` (Rudi work management CLI) is the first application to hit this pattern. Its implementation illustrates how the tiers work in practice.

**Today — Tier 1:**
- Work items live in `.beads/issues.jsonl` within the project repo
- `git` distributes state: `git push` syncs, `git pull` receives updates
- Offline operation is native — the file is always local
- Conflict resolution: git merge (line-level, each item is one line)
- Limitation: one machine at a time without explicit git push/pull

**Tier 3 plan — cross-host sync:**

When `rd` needs to sync work items across machines without explicit git push/pull:

1. Choose a campfire with `max-ttl:0` + `lifecycle:persistent` + operator provenance at medium or above
2. Work item mutations become campfire messages (create, update, close, reopen)
3. The local `.beads/issues.jsonl` is the materialized view, updated as messages arrive
4. On join, replay missed messages from the campfire's history into the local JSONL
5. On disconnect, continue operating from the local JSONL; buffer pending mutations

The storage interface does not change between tier 1 and tier 3. The `rd` commands remain `rd create`, `rd update`, `rd close`. The sync layer is below the application interface.

**Durability check at tier 3 setup:**

Before a user configures a campfire as `rd`'s tier 3 transport, `rd` reads the campfire's beacon and evaluates:

1. Are `durability:max-ttl:0` and `durability:lifecycle:persistent` present?
2. What is the operator's provenance level?
3. Are there any accumulated flags on this campfire?

If the campfire does not meet minimum durability criteria (configurable, default: `max-ttl:0` + `lifecycle:persistent` + `provenance:basic` or above), `rd` warns the user and requires explicit confirmation before proceeding. The user decides — `rd` informs.

---

## Summary

| Situation | Storage choice |
|-----------|---------------|
| Single project, one machine | Tier 1: JSONL in repo, git distributes |
| Multiple projects, one machine | Tier 2: JSONL in `~/.config/<app>/` |
| Multiple machines | Tier 3: local JSONL + campfire sync layer |
| Secrets | Not campfire. Use a secrets manager. |
| Large files | Not campfire. Object storage + URL reference. |
| ACID transactions | Not campfire. Use a database. |

The invariant across all tiers: **the local JSONL is the source of truth for queries. Campfire is the sync layer, not the store.**

---

## Dependencies

- [Campfire Durability Convention v0.1](conventions/campfire-durability.md) — defines `durability:max-ttl` and `durability:lifecycle` beacon tags
- [Operator Provenance Convention v0.1](conventions/operator-provenance.md) — provenance levels for evaluating durability claims
- [Community Beacon Metadata Convention v0.3](conventions/community-beacon-metadata.md) — beacon format and tainted field semantics
- [Trust Convention v0.2](conventions/trust.md) — content safety envelope, tainted field handling
