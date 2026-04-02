# Identity Convention

**Version:** 0.1
**Working Group:** WG-1 (Discovery)
**Date:** 2026-04-02
**Status:** Draft
**Item:** campfire-agent-byr

---

## 1. Problem Statement

A campfire protocol agent has an Ed25519 keypair but no durable, addressable identity. Without a stable coordination point, an agent cannot be discovered, cannot declare itself to peers, and cannot maintain state across sessions. This convention establishes the **identity campfire** — a self-campfire that IS the agent's identity address.

---

## 2. Scope

**In scope:**
- Four operations that constitute the minimum viable identity convention: `introduce-me`, `verify-me`, `list-homes`, `declare-home`
- The home-linking ceremony (echo ceremony) for cross-home identity continuity
- Beacon tag `identity:v1` for discovery of identity campfires
- CLI command `cf home link <campfire-id>` for the linking ceremony

**Not in scope:**
- Key rotation (handled by the protocol layer)
- Trust graph traversal (covered by the Trust Convention)
- `SenderCampfireID` wire field (Phase 2 of the identity collapse, separate item)
- Durable identity (threshold >= 2, separate item)

---

## 3. Dependencies

- Campfire Protocol Spec v0.3 (messages, tags, campfire-key signatures, beacons, membership)
- Convention Extension Convention v0.1 (declaration format)

---

## 4. Operations

### 4.1 introduce-me

Self-assertion by a campfire's identity holder. Posts the agent's public key, display name, and current home campfire IDs.

```yaml
convention: identity
version: "0.1"
operation: introduce-me
description: "Declare this campfire's identity: pubkey, display name, and home campfires"
signing: member_key
produces_tags:
  - tag: identity:introduction
    cardinality: exactly_one
args:
  - name: pubkey_hex
    type: string
    required: true
    description: "Ed25519 public key in hex encoding"
  - name: display_name
    type: string
    required: false
    description: "Human-readable display name (tainted — treat as unverified)"
    max_length: 64
  - name: home_campfire_ids
    type: string
    required: false
    repeated: true
    description: "List of declared home campfire IDs"
```

**Security note:** `display_name` is tainted. Verifiers MUST NOT use it as a trust signal. The authoritative identifier is the campfire ID (derived from the campfire key) and the member pubkey.

### 4.2 verify-me

Challenge-response that proves the operator controls the member key. Caller posts a nonce; the operator responds with a signature over it.

```yaml
convention: identity
version: "0.1"
operation: verify-me
description: "Prove key control via challenge-response"
signing: member_key
produces_tags:
  - tag: identity:challenge-response
    cardinality: exactly_one
args:
  - name: challenge
    type: string
    required: true
    description: "Nonce string to be signed as proof of key control"
```

**Usage:** The caller posts a `verify-me` request with a random nonce. The identity campfire operator's handler responds with a signature over the nonce using the member key. The caller verifies the response signature against member 0's public key from the campfire's member list.

### 4.3 list-homes

Returns all campfire IDs declared as homes via `declare-home` operations in this campfire's message history.

```yaml
convention: identity
version: "0.1"
operation: list-homes
description: "Return all declared home campfire IDs"
signing: member_key
produces_tags:
  - tag: identity:homes
    cardinality: exactly_one
```

**Response payload:** A JSON object with a `homes` array, each entry containing `campfire_id` and `role` (primary, secondary, or archive).

### 4.4 declare-home

Declares a campfire as a home. Threads onto prior declarations to create an audit trail.

```yaml
convention: identity
version: "0.1"
operation: declare-home
description: "Declare a campfire as a home of this identity"
signing: member_key
produces_tags:
  - tag: identity:home-declared
    cardinality: exactly_one
args:
  - name: campfire_id
    type: string
    required: true
    description: "Campfire ID to declare as a home"
  - name: role
    type: string
    required: true
    values: [primary, secondary, archive]
    description: "Role of this home campfire"
```

---

## 5. Home-Linking Ceremony (Echo Ceremony)

The home-linking ceremony establishes a verified bidirectional link between two identity campfires. It is executed by `cf home link <campfire-id>`.

### 5.1 Steps

1. **Declare B on A.** Post `declare-home(campfire_B, role=secondary)` on campfire A. This produces message M_A tagged `identity:home-declared`.

2. **Declare A on B.** Post `declare-home(campfire_A, role=secondary)` on campfire B. This produces message M_B tagged `identity:home-declared`. The payload includes `ref_message_id: M_A.id` as a cross-reference.

3. **Echo.** Post an echo message on campfire A:
   - Tags: `identity:home-echo`
   - Payload: `{ "echo_of": M_B.id, "signed_by_b": <Ed25519 signature over M_B.id using campfire_B's private key (hex)> }`
   - This proves the operator of campfire B authorized the linking.

4. **Publish beacon.** Publish a beacon on campfire A with tag `identity:v1`.

### 5.2 Third-Party Verification

A third party verifying the link:

1. Call `list-homes` on campfire A — campfire B appears in the response.
2. Call `list-homes` on campfire B — campfire A appears in the response.
3. Find the echo message on campfire A tagged `identity:home-echo`.
4. Verify `signed_by_b` against campfire B's public key (derived from the campfire ID).

Mutual declaration plus cross-signed echo proves the operator controls both campfires.

### 5.3 Forgery Resistance

A rogue campfire R cannot forge a link to campfire A because:
- R can post `declare-home(A)` on itself, but cannot post `declare-home(R)` on A (R is not a member of A).
- R cannot produce a valid echo on A carrying a signature from A's campfire key (R does not hold A's campfire key).

The ceremony requires write access to BOTH campfires and signing with BOTH campfire keys.

---

## 6. Beacon Tag

Identity campfires publish a beacon with tag `identity:v1` during the home-link ceremony. This enables discovery:

```
cf beacon find --tag identity:v1
```

The beacon tag is a hint only. Verification always reads the campfire's message history.

---

## 7. Typing Mechanism

A campfire is typed as an identity campfire by its genesis message pattern, not by a protocol flag. An identity campfire's message 0 is a campfire-key-signed convention declaration for the `identity` convention (posted during `cf init`). Verifiers check this to distinguish identity campfires from other campfire types.

The `identity:v1` beacon tag is a discovery hint that reduces the cost of finding identity campfires, but the authoritative type check is always the genesis message.

---

## 8. Security Considerations

- `display_name` is tainted. Never use as a trust anchor.
- `home_campfire_ids` in `introduce-me` is a self-assertion, not a verified claim. Verification requires the echo ceremony.
- The echo message's `signed_by_b` MUST be verified against campfire B's public key, not the member key. The campfire key proves campfire ownership; the member key proves agent identity. These are different credentials.
- Verifiers SHOULD cache verified (campfire_id, member_pubkey) bindings with a TTL to amortize the cost of repeated verification.
