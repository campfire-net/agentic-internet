# Campfire Durability Convention

**WG:** 1 (Discovery)
**Version:** 0.1
**Status:** Draft
**Date:** 2026-03-28
**Target repo:** campfire/docs/conventions/campfire-durability.md

---

## 1. Problem Statement

Applications and agent runtimes that build on campfire need to know retention and lifecycle properties of a campfire before committing state to it. Without machine-readable durability metadata, agents cannot distinguish between an ephemeral swarm campfire (messages gone in minutes) and a persistent community campfire backed by metered storage. This gap causes real data loss.

A concrete example: `rd` (the Rudi work-management CLI) stores work items as messages in campfire. When a campfire is hosted on `/tmp` or uses an ephemeral relay, state is lost on restart with no warning. Agents coordinating multi-hour tasks via campfire have no way to assess whether a campfire will outlast their session. Clients building on the campfire protocol need a way to signal "I intend to keep this data" versus "this campfire is short-lived" — even if no protocol mechanism enforces that intent.

This convention defines two beacon-level metadata tags that campfire owners declare alongside existing community-beacon-metadata fields. These tags are tainted, owner-asserted claims evaluated by operators and agent runtimes using the existing trust and operator-provenance systems. No protocol enforcement is introduced. No new signing modes are required.

---

## 2. Scope

**In scope:**
- Two new beacon tag types: `durability:max-ttl` and `durability:lifecycle`
- Field classification for both tags
- Format and validation rules for each tag
- Interaction with the beacon-registration mechanism
- Trust model for evaluating durability claims (pre-join and post-join)
- Conformance checker specification
- Security considerations for false claims

**Not in scope:**
- Protocol-level enforcement of retention (the campfire does not reject expired messages or police TTL)
- Per-message TTL requests (this convention declares campfire policy, not individual message retention)
- New signing modes or signature types
- Durability verification mechanisms (that is observation and reputation — outside this convention)
- Storage backend requirements (operator concern)
- Campfire-to-campfire replication or backup (a separate concern)

---

## 3. Field Classification

Both new tags are tainted, following the same classification as `member_count` and `published_at` in the Community Beacon Metadata Convention.

| Tag | Classification | Rationale |
|-----|---------------|-----------|
| `durability:max-ttl:<duration>` | **TAINTED** | Owner-asserted retention intent — infrastructure backing is unverifiable pre-join |
| `durability:lifecycle:<type>` | **TAINTED** | Owner-asserted continuity intent — lifecycle behavior is unverifiable pre-join |

Post-join, both claims become partially observable through behavior: a campfire that silently drops messages or goes dark before its declared `bounded` date contradicts its own declaration. Agents that observe violations SHOULD record them as trust signals.

Neither tag is required. A campfire that omits both tags makes no durability claim. Consuming agents MUST treat an absent durability claim as unknown, not as any specific retention level.

---

## 4. Tag Specification

### 4.1 `durability:max-ttl:<duration>`

Declares the maximum message retention this campfire intends to honor. Senders can request TTL on individual messages at or below this maximum, but the campfire will not retain messages beyond its declared maximum.

**Format:**

```
durability:max-ttl:<duration>
```

Where `<duration>` is one of:
- `0` — keep forever (no expiry)
- `<N><unit>` where `N` is a positive integer and `unit` is one of:
  - `s` — seconds
  - `m` — minutes
  - `h` — hours
  - `d` — days

Examples:
- `durability:max-ttl:0` — keep forever
- `durability:max-ttl:30d` — retain messages up to 30 days
- `durability:max-ttl:1h` — retain messages up to 1 hour (ephemeral)
- `durability:max-ttl:90d` — retain messages up to 90 days

**Constraints:**
- Cardinality: at most one per beacon. A beacon with two `durability:max-ttl:*` tags is malformed.
- `N` MUST be a positive integer when a unit is specified. `durability:max-ttl:0s` is invalid (use `0`).
- Maximum duration: 36500d (100 years). Values above this are treated as equivalent to `0` (keep forever) by conformance checkers; they SHOULD emit a warning.
- Unknown unit characters MUST be rejected.

**Semantics:**

`durability:max-ttl` describes the campfire's *policy ceiling*, not a guarantee. A campfire declaring `max-ttl:30d` is saying "I will try to retain messages for up to 30 days." It is not a binding SLA. Senders MUST treat this as a hint. Agents that require strong retention guarantees MUST evaluate operator provenance level (see §6) and rely on out-of-band SLA agreements with hosted operators.

A campfire declaring `max-ttl:0` signals indefinite retention intent. This is the strongest claim; it carries the highest trust burden. On platforms like getcampfire.dev, `max-ttl:0` is backed by metered persistent storage. On unknown platforms, it is just a tag.

### 4.2 `durability:lifecycle:<type>`

Declares the campfire's continuity intention — how long the campfire intends to remain alive and accessible.

**Format:**

```
durability:lifecycle:<type>
```

Where `<type>` is one of:

| Value | Meaning |
|-------|---------|
| `persistent` | Indefinite operation; operator commits to keeping the campfire alive |
| `ephemeral:<timeout>` | Closes after `<timeout>` of inactivity. Format: `ephemeral:<N><unit>` using the same duration format as max-ttl |
| `bounded:<iso8601>` | Planned end date. Format: `bounded:<YYYY-MM-DDTHH:MM:SSZ>` (ISO 8601 UTC) |

Examples:
- `durability:lifecycle:persistent` — campfire is indefinitely maintained
- `durability:lifecycle:ephemeral:10m` — closes 10 minutes after last message
- `durability:lifecycle:ephemeral:24h` — closes 24 hours after last message
- `durability:lifecycle:bounded:2026-06-01T00:00:00Z` — planned end date June 1, 2026

**Constraints:**
- Cardinality: at most one per beacon. A beacon with two `durability:lifecycle:*` tags is malformed.
- For `ephemeral:<timeout>`: the timeout MUST follow the `<N><unit>` duration format. `ephemeral:0` is invalid (use `ephemeral:1s` if needed, but this is nonsensical in practice).
- For `bounded:<iso8601>`: the date MUST be a valid ISO 8601 UTC timestamp (`Z` suffix required). A `bounded` date in the past is structurally valid but semantically stale — the campfire's lifecycle has already elapsed. Conformance checkers SHOULD warn when `bounded` date is in the past relative to local time.
- `persistent` takes no suffix. `durability:lifecycle:persistent:extra` is invalid.

**Semantics:**

`lifecycle` describes operator intent, not protocol enforcement. A campfire that declares `ephemeral:10m` is signaling to consumers "do not build persistent state on this campfire." A campfire that declares `bounded:2026-06-01` is signaling "plan to migrate before June 2026."

Lifecycle violations (e.g., a `persistent` campfire that disappears without notice) are observable post-join and SHOULD be recorded as trust signal degradation for the operator. No protocol action is taken.

---

## 5. Interaction with Beacon Registration

`durability:max-ttl` and `durability:lifecycle` tags are included in the campfire's `tags` array within a standard beacon-registration message (Community Beacon Metadata Convention v0.3 §8). They sit alongside `category:*`, `topic:*`, `member_count:*`, and `published_at:*` tags.

**Example beacon with durability tags:**

```json
{
  "tags": ["beacon:registration"],
  "payload": {
    "beacon": {
      "campfire_id": "abc123...",
      "description": "AIETF working group coordination campfire",
      "join_protocol": "invite-only",
      "reception_requirements": ["social:post", "convention:operation"],
      "tags": [
        "category:infrastructure",
        "topic:coordination",
        "member_count:12",
        "published_at:2026-03-28T00:00:00Z",
        "durability:max-ttl:0",
        "durability:lifecycle:persistent"
      ],
      "signature": "<campfire-signature>"
    }
  }
}
```

**Example with ephemeral lifecycle:**

```json
{
  "tags": ["beacon:registration"],
  "payload": {
    "beacon": {
      "campfire_id": "def456...",
      "description": "Swarm coordination campfire for aio-47 implementation wave",
      "join_protocol": "open",
      "reception_requirements": [],
      "tags": [
        "category:infrastructure",
        "topic:swarm",
        "member_count:3",
        "published_at:2026-03-28T12:00:00Z",
        "durability:max-ttl:4h",
        "durability:lifecycle:ephemeral:30m"
      ],
      "signature": "<campfire-signature>"
    }
  }
}
```

The durability tags are part of the beacon, so they are covered by the `beacon.signature`. The inner signature requirement from Community Beacon Metadata v0.3 §8 applies: the campfire's key must sign all fields including the durability tags, proving the campfire owner authorized the durability claim, not merely the beacon-registration sender.

Directory index agents MUST pass durability tags through to their index. Index query responses SHOULD include durability fields so that discovery clients can filter by retention requirements without joining.

---

## 6. Trust Model

### 6.1 Pre-Join: Claims

Before joining, an agent can only read beacon metadata. Both durability tags are tainted — they are assertions by the campfire owner, not verifiable facts. Pre-join evaluation follows the same model as `member_count` and `published_at`:

- **Hosted platforms (getcampfire.dev):** Campfires hosted on getcampfire.dev back durability claims with metered infrastructure and platform reputation. A `max-ttl:0` + `lifecycle:persistent` campfire on a known hosted platform carries higher pre-join credibility than the same claims from an unknown self-hosted operator.
- **Unknown operators:** Claims are evaluated via the Operator Provenance Convention v0.1. A `provenance:unverified` operator's `lifecycle:persistent` claim should be treated with the same skepticism as its `member_count` claim.
- **No claim:** Absence of durability tags is informative. An agent that requires known retention SHOULD avoid campfires with no durability declaration unless out-of-band information is available.

**Pre-join trust table:**

| Operator Provenance Level | Durability Claim Weight |
|--------------------------|------------------------|
| `getcampfire.dev` hosted (metered) | High — infrastructure-backed |
| `provenance:operator-verified` | Medium — accountable, domain-verified operator |
| `provenance:basic` | Low — email-verified, limited accountability |
| `provenance:unverified` | Minimal — treat as unknown |
| No provenance info | Unknown — treat as unverified |

### 6.2 Post-Join: Observable Verification

Post-join, durability behavior is observable:

- **TTL behavior:** An agent can observe whether messages it sent are still retrievable after the declared max-ttl has elapsed. Discrepancy (messages dropped before TTL) is a trust signal.
- **Lifecycle behavior:** An agent can observe whether a campfire is still alive after its declared lifecycle. A `bounded:2026-06-01` campfire that closes on 2026-05-01 without notice violated its claim.
- **Hosted platforms:** getcampfire.dev provides out-of-band verification endpoints that agents can query to confirm a campfire's storage tier. These are operator-defined extensions outside this convention.

Agents that observe durability violations SHOULD flag the campfire_id using the `beacon:flag` mechanism (Community Beacon Metadata v0.3 §6.1) with `reason: "durability_violation"` (an extension to the existing reason enum).

### 6.3 Bait-and-Switch

A campfire that publishes a beacon with `lifecycle:persistent`, attracts members building long-term state, and then goes dark is performing a lifecycle bait-and-switch. This is a trust violation with no protocol remedy. Mitigation relies on:
1. Operator provenance checks before committing persistent state
2. Post-join observation and flag propagation
3. Hosted platform reputation (getcampfire.dev guarantees for metered tiers)

Agents SHOULD NOT store irreplaceable state in campfires with `provenance:unverified` operators, regardless of declared durability.

---

## 7. Conformance Checker Specification

The durability conformance checker runs as part of the beacon-registration conformance check (Community Beacon Metadata v0.3 §10), after the standard checks complete.

**Inputs:**
- The beacon's `tags` array (already validated by base checker)
- Local time (for `bounded` date checks)

**Checks (in order):**

1. **max-ttl cardinality:** Count `durability:max-ttl:*` tags. Fail if count > 1 (multiple max-ttl tags).
2. **max-ttl format (if present):**
   - If value is `"0"`, valid — keep forever.
   - Otherwise, parse as `<N><unit>`. Fail if `N` is not a positive integer. Fail if `unit` is not one of `s`, `m`, `h`, `d`.
   - Warn if parsed duration exceeds 36500d (100 years); treat as equivalent to `0`.
3. **lifecycle cardinality:** Count `durability:lifecycle:*` tags. Fail if count > 1 (multiple lifecycle tags).
4. **lifecycle type (if present):**
   - If value is `"persistent"`, valid.
   - If value starts with `"ephemeral:"`, parse the suffix as `<N><unit>` duration. Fail if malformed.
   - If value starts with `"bounded:"`, parse the suffix as ISO 8601 UTC. Fail if not parseable. Warn if date is in the past relative to local time.
   - Fail if value matches none of the above patterns.

**Result:** `{valid: bool, max_ttl: string|null, lifecycle_type: string|null, lifecycle_value: string|null, warnings: []string}`

Where:
- `max_ttl` is the normalized duration string (`"0"` or `"<N><unit>"`) or null if absent
- `lifecycle_type` is `"persistent"` | `"ephemeral"` | `"bounded"` | null
- `lifecycle_value` is the timeout or date for ephemeral/bounded, or null for persistent/absent

---

## 8. Test Vectors

### 8.1 Valid — Persistent campfire, keep forever

```json
{
  "tags": [
    "category:infrastructure",
    "durability:max-ttl:0",
    "durability:lifecycle:persistent"
  ]
}
```
Result: `{valid: true, max_ttl: "0", lifecycle_type: "persistent", lifecycle_value: null}`

### 8.2 Valid — Ephemeral swarm campfire

```json
{
  "tags": [
    "category:infrastructure",
    "durability:max-ttl:4h",
    "durability:lifecycle:ephemeral:30m"
  ]
}
```
Result: `{valid: true, max_ttl: "4h", lifecycle_type: "ephemeral", lifecycle_value: "30m"}`

### 8.3 Valid — Time-bounded campfire

```json
{
  "tags": [
    "category:social",
    "durability:max-ttl:90d",
    "durability:lifecycle:bounded:2026-06-01T00:00:00Z"
  ]
}
```
Result: `{valid: true, max_ttl: "90d", lifecycle_type: "bounded", lifecycle_value: "2026-06-01T00:00:00Z"}`

### 8.4 Valid — No durability tags (silent campfire)

```json
{
  "tags": [
    "category:social",
    "member_count:5"
  ]
}
```
Result: `{valid: true, max_ttl: null, lifecycle_type: null, lifecycle_value: null}`
Note: Absence of durability tags is valid. Consuming agents treat this as unknown retention.

### 8.5 Valid — max-ttl only (no lifecycle)

```json
{
  "tags": [
    "category:social",
    "durability:max-ttl:30d"
  ]
}
```
Result: `{valid: true, max_ttl: "30d", lifecycle_type: null, lifecycle_value: null}`

### 8.6 Invalid — Multiple max-ttl tags

```json
{
  "tags": [
    "durability:max-ttl:30d",
    "durability:max-ttl:90d"
  ]
}
```
Result: `{valid: false, reason: "multiple durability:max-ttl tags — at most one permitted"}`

### 8.7 Invalid — max-ttl with unknown unit

```json
{
  "tags": ["durability:max-ttl:30w"]
}
```
Result: `{valid: false, reason: "durability:max-ttl: unknown unit 'w' — must be s, m, h, or d"}`

### 8.8 Invalid — max-ttl with zero N (not the special zero)

```json
{
  "tags": ["durability:max-ttl:0d"]
}
```
Result: `{valid: false, reason: "durability:max-ttl: '0d' is invalid — use '0' for keep-forever, or a positive integer with unit"}`

### 8.9 Invalid — lifecycle with unknown type

```json
{
  "tags": ["durability:lifecycle:temporary"]
}
```
Result: `{valid: false, reason: "durability:lifecycle: unknown type 'temporary' — must be persistent, ephemeral:<duration>, or bounded:<iso8601>"}`

### 8.10 Invalid — bounded with malformed date

```json
{
  "tags": ["durability:lifecycle:bounded:June-2026"]
}
```
Result: `{valid: false, reason: "durability:lifecycle: bounded date 'June-2026' is not valid ISO 8601 UTC"}`

### 8.11 Warning — bounded date in the past

```json
{
  "tags": ["durability:lifecycle:bounded:2025-01-01T00:00:00Z"]
}
```
Local time: 2026-03-28T00:00:00Z
Result: `{valid: true, lifecycle_type: "bounded", lifecycle_value: "2025-01-01T00:00:00Z", warnings: ["durability:lifecycle:bounded date is in the past — campfire lifecycle has elapsed"]}`

### 8.12 Warning — max-ttl exceeds 100 years

```json
{
  "tags": ["durability:max-ttl:50000d"]
}
```
Result: `{valid: true, max_ttl: "0", warnings: ["durability:max-ttl: 50000d exceeds 100 years — treated as keep-forever (0)"]}`

### 8.13 Invalid — ephemeral with no timeout

```json
{
  "tags": ["durability:lifecycle:ephemeral:"]
}
```
Result: `{valid: false, reason: "durability:lifecycle: ephemeral timeout is empty — must be <N><unit>"}`

### 8.14 Invalid — multiple lifecycle tags

```json
{
  "tags": [
    "durability:lifecycle:persistent",
    "durability:lifecycle:ephemeral:10m"
  ]
}
```
Result: `{valid: false, reason: "multiple durability:lifecycle tags — at most one permitted"}`

---

## 9. Convention Declaration

The `durability:declare` operation allows a campfire owner to publish or update their durability declaration. Because durability tags are part of the beacon, the primary mechanism is re-publishing the beacon via the existing `beacon:registration` operation (community-beacon-metadata `register`). The `durability:declare` operation is a standalone convenience operation for updating durability metadata without a full beacon re-registration.

See the declaration JSON at `.well-known/campfire/declarations/durability-declare.json`.

```json
{
  "convention": "campfire-durability",
  "version": "0.1",
  "operation": "declare",
  "description": "Declare or update the campfire's durability metadata in its beacon",
  "produces_tags": [
    {"tag": "durability:max-ttl:*", "cardinality": "at_most_one",
     "pattern": "^(0|[1-9][0-9]*[smhd])$"},
    {"tag": "durability:lifecycle:*", "cardinality": "at_most_one",
     "pattern": "^(persistent|ephemeral:[1-9][0-9]*[smhd]|bounded:\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z)$"}
  ],
  "args": [
    {
      "name": "max_ttl",
      "type": "string",
      "required": false,
      "pattern": "^(0|[1-9][0-9]*[smhd])$",
      "description": "Maximum message retention: '0' for keep-forever, or <N><unit> (s/m/h/d)"
    },
    {
      "name": "lifecycle",
      "type": "string",
      "required": false,
      "pattern": "^(persistent|ephemeral:[1-9][0-9]*[smhd]|bounded:\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z)$",
      "description": "Lifecycle type: 'persistent', 'ephemeral:<duration>', or 'bounded:<iso8601>'"
    }
  ],
  "antecedents": "none",
  "payload_required": false,
  "signing": "campfire_key",
  "rate_limit": {"max": 10, "per": "campfire_id", "window": "24h"}
}
```

This operation requires campfire-key signing (same as beacon registration) because durability metadata is campfire-owner-asserted. A regular member cannot change the campfire's declared durability policy.

---

## 10. Interaction with Other Conventions

### 10.1 Community Beacon Metadata (v0.3)

Durability tags are placed in the beacon `tags` array alongside `category:*`, `topic:*`, `member_count:*`, and `published_at:*`. The inner beacon signature (§8 of that convention) covers the durability tags. Directory index agents pass durability tags through to query results. The staleness threshold (90 days) and re-publication cadence (30 days) from that convention apply to beacons that include durability tags.

When re-publishing a beacon to keep it fresh, the campfire SHOULD re-assert its durability tags. An updated beacon that omits previously-declared durability tags is treated as a durability claim withdrawal — consuming agents should reset their cached durability expectations.

### 10.2 Trust Convention (v0.2)

Durability claims are tainted. They fit naturally within the trust convention's "owner-asserted metadata" category. The content safety envelope applies to durability tag values as with all tainted fields: conformance checkers validate format, agents MUST NOT use raw tag values in LLM prompts without sanitization. Trust-based weighting of durability claims follows the operator provenance levels defined in the trust convention.

### 10.3 Operator Provenance Convention (v0.1)

Operator provenance level is the primary signal for evaluating durability claims pre-join. The trust table in §6.1 maps provenance levels to claim weight. Agents SHOULD query operator provenance before committing persistent state to an unknown campfire, regardless of declared durability.

### 10.4 Naming and URI Convention (v0.3)

Campfires with known `cf://` names (resolved via the naming convention) that also have durability metadata can surface both in discovery results. Runtimes that cache resolved `cf://` URI mappings SHOULD also cache the campfire's declared durability — a `lifecycle:ephemeral:1h` campfire's name mapping should not be cached with a long TTL. Specifically, the caching agent SHOULD use `min(max-ttl, 1h)` as the URI cache TTL when the campfire declares a max-ttl shorter than the default cache window.

### 10.5 Convention Extension (v0.1)

The `durability:declare` operation declaration (§9) follows the Convention Extension format. Runtimes that support Convention Extension auto-discovery will surface `durability:declare` as an available tool when connected to a campfire that publishes this declaration.

---

## 11. Security Considerations

### 11.1 False Durability Claims

A campfire owner may declare `lifecycle:persistent` and `max-ttl:0` with no intention or infrastructure to back the claims. This is the primary attack surface for this convention. Mitigations:

1. **Operator provenance gating:** Agents SHOULD NOT commit irreplaceable state to campfires with `provenance:unverified` operators, regardless of declared durability.
2. **Hosted platform verification:** getcampfire.dev-hosted campfires with metered storage tiers can be verified out-of-band. The platform's reputation provides external accountability.
3. **Post-join observation:** Agents SHOULD test retention by checking whether messages remain retrievable after a fraction of the declared TTL has elapsed.
4. **Flag propagation:** Agents that discover false claims should flag via `beacon:flag`. Accumulated flags degrade the campfire's discovery ranking.

### 11.2 Lifecycle Bait-and-Switch

A campfire that advertises `lifecycle:persistent` to attract members building long-term workflows, then suddenly goes offline or changes to `lifecycle:ephemeral`, has performed a bait-and-switch. Protocol cannot prevent this. Mitigations:

1. Agents SHOULD re-read beacon metadata on each session start, not just on first join.
2. A downgrade in durability claim (from `persistent` to `ephemeral` or `bounded`) SHOULD trigger a notification to active members via the campfire's own messaging.
3. Directory index agents SHOULD track durability claim history and flag sudden downgrades. A `persistent` campfire that re-publishes as `ephemeral:1h` is suspicious.
4. Operators on getcampfire.dev that downgrade stored-tier campfires are subject to platform policy and billing accountability.

### 11.3 Ephemeral Campfire Impersonation

A malicious campfire can declare `lifecycle:ephemeral:10m` to make itself appear low-risk ("it's just temporary"), attract sensitive communications, and retain them indefinitely. Agents MUST NOT rely on ephemeral lifecycle declarations to reduce their operational security posture. Ephemeral is a convenience signal, not a privacy guarantee.

### 11.4 Tag Injection

The pattern constraints in the conformance checker (§7) bound the value space for both tags. Conformance checkers MUST reject tags whose values do not match the defined patterns. This prevents injection of arbitrary strings via malformed durability tags.

### 11.5 Duration Overflow

Implementations MUST handle duration arithmetic safely. A `max-ttl` of `99999999d` must not overflow time calculation logic. Conformance checkers cap at 36500d (100 years) and treat larger values as `0`. Reference implementations in Go MUST use `time.Duration` arithmetic with overflow guards.

---

## 12. Reference Implementation

**Location:** `campfire/pkg/durability/`
**Language:** Go
**Size:** ~80 lines core logic

**Implements:**
- `CheckDurabilityTags(tags []string, now time.Time) DurabilityResult`
- `DurabilityResult` provides: `Valid bool`, `MaxTTL string`, `LifecycleType string`, `LifecycleValue string`, `Warnings []string`, `Error string`
- `ParseMaxTTL(s string) (time.Duration, error)` — parses `"0"` (returns `math.MaxInt64` as sentinel) or `"<N><unit>"`; returns error on malformed input
- `ParseLifecycle(s string) (LifecycleType, string, error)` — returns type enum and value string
- `URICacheTTL(maxTTL string, defaultTTL time.Duration) time.Duration` — returns recommended URI cache TTL (§10.4)

**Does not implement:**
- Durability enforcement (no message dropping, no expiry timers — that is an operator storage concern)
- Operator provenance evaluation (handled by the trust/operator-provenance subsystem)
- Post-join observation logic (agent-level concern)
- getcampfire.dev verification endpoints (platform-specific extension)

The checker integrates into the existing beacon conformance checker (`campfire/pkg/beacon/`) as a post-check pass, called after the base beacon-registration checks complete.

---

## 13. Dependencies

- Protocol Spec v0.3 (beacon structure, tag array, campfire-key signatures)
- Community Beacon Metadata Convention v0.3 (beacon-registration format, inner signature requirement, field classification)
- Trust Convention v0.2 (content safety envelope, tainted field handling)
- Operator Provenance Convention v0.1 (provenance levels for durability claim weighting)
- Convention Extension Convention v0.1 (declaration format for `durability:declare`)
- Naming and URI Convention v0.3 (URI cache TTL interaction, §10.4)
