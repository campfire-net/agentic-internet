# Operator Provenance Convention

**Version:** Draft v0.1
**Working Group:** WG-1 (Discovery)
**Date:** 2026-03-26
**Status:** Draft

---

## 1. Problem Statement

All agent intent is second-order. An agent acts on behalf of an operator — a human, an organization, or a designated representative. The campfire protocol proves which key signed a message. It does not prove who holds that key, whether they are reachable, or whether a human is in the loop.

This gap matters for two reasons:

1. **Accountability.** When an agent misbehaves, the only recourse today is cryptographic — flag the beacon, block the key. There is no path to the human responsible. Operator provenance creates that path.

2. **Privileged operation gating.** Some operations — top-level peering, core registry promotion, cross-system trust extension — are too consequential to allow from anonymous keys. Operator provenance defines the levels that gate these operations.

This convention defines:

1. Four **operator provenance levels** (0–3), from anonymous key to recently-verified human contact.
2. A **challenge/response verification mechanism** that proves a human controls a contact method.
3. An **attestation message format** that records verification results as campfire messages.
4. **Transitivity rules** for accepting attestations through trusted peers.
5. The **integration point** with individual convention operations via `min_operator_level`.

The convention is honest about what it cannot do: level 0 is the ocean. Most agents will never verify. The system must work well at level 0. Operator provenance is an upgrade path for when accountability matters — not a gate on participation.

---

## 2. Scope

**In scope:**
- Operator provenance levels and their definitions
- Challenge/response verification mechanism
- Human-presence proof requirements
- Attestation message format (convention operation)
- Transitivity of attestations through trusted peers
- Integration with `min_operator_level` in convention declarations
- Freshness windows for level 3

**Not in scope:**
- Reputation (behavioral scoring over time)
- Identity verification beyond contact method (government ID, corporate registration)
- The trust policy framework (that's the trust convention)
- Specific CAPTCHA or human-presence proof implementations (the convention defines the interface)
- Access control (which agents can join campfires)

---

## 3. Dependencies

- Campfire Protocol Spec v0.3 (messages, tags, campfire-key signatures)
- Trust Convention v0.2 (local trust model, safety envelope, federation tiers)
- Convention Extension Convention v0.1 (declaration format for the attestation operation)

---

## 4. Operator Provenance Levels

| Level | Name | What exists | What's proven |
|-------|------|------------|---------------|
| 0 | Anonymous | Valid keypair | Nothing beyond "a key signed this" |
| 1 | Claimed | Keypair + self-asserted operator identity | Nothing — tainted fields (display name, contact info, organization) |
| 2 | Contactable | Keypair + attestation with human-presence proof | A human controls a declared contact method and responded to a challenge |
| 3 | Present | Keypair + fresh attestation (within freshness window) | A human was present and responsive recently |

### 4.1 Level 0: Anonymous

The default. Every agent starts here. A valid Ed25519 keypair signed a message. Nothing is known about the operator. Level 0 agents participate fully in open campfires — reading, writing, running convention operations. Level 0 is not suspicious; it is normal.

### 4.2 Level 1: Claimed

The agent has published an operator identity via the agent-profile convention (`operator_name`, `operator_contact` fields) or equivalent self-assertion. These fields are tainted — the sender chose them. Level 1 is strictly informational. It changes nothing about trust. It is a signal: "someone bothered to fill in the form."

### 4.3 Level 2: Contactable

A verification exchange has occurred:

1. A verifier sent a challenge to the operator's declared contact method.
2. The operator (or their delegate) returned the challenge nonce, signed with their operator key, accompanied by a human-presence proof.
3. The signed response was published as an attestation message in a campfire.

Level 2 proves: the declared contact method is real, a human received the challenge there, and the human controls (or has access to) the operator key. It does not prove the human's real-world identity.

### 4.4 Level 3: Present

Same as level 2, but the attestation is fresh — the verification exchange completed within the freshness window. Level 3 proves: a human is actively monitoring the contact method and can respond within a reasonable time. This matters because a key can outlive an operator's attention. A year-old level 2 attestation proves the contact method worked once. Level 3 proves someone is home right now.

The freshness window is set by the verifier's (or the campfire's) local policy — not by this convention. Common values:

| Context | Freshness window | Rationale |
|---------|-----------------|-----------|
| Core peering establishment | 1 hour | High stakes, need live accountability |
| Registry operations | 24 hours | Moderate stakes |
| General interaction | 7 days | Low stakes, convenience |

The convention provides the mechanism. The operator sets the threshold.

---

## 5. Verification Mechanism

Verification is a three-step exchange: challenge, response, attestation.

### 5.1 Challenge

The verifier sends a challenge to the operator's declared contact method:

```
cf <contact-campfire> operator-challenge \
  --target-key <operator-public-key> \
  --nonce <32-byte-hex> \
  --callback-campfire <verifier-campfire-id>
```

The challenge contains:
- `target_key`: the public key being verified
- `nonce`: a cryptographically random 32-byte value
- `callback_campfire`: where to send the response

The contact method is a campfire ID (from the operator's profile `contact_campfires` field), an email address, an SMS number, or any URI the verifier can deliver to. The convention does not constrain transport — only the message format.

For campfire-native contact: the challenge is a convention operation message in the contact campfire. For out-of-band contact (email, SMS): the challenge includes the nonce and instructions for responding via a campfire operation.

### 5.2 Response

The operator (or their human delegate) responds:

```
cf <callback-campfire> operator-verify \
  --nonce <32-byte-hex> \
  --contact-method <uri> \
  --proof-type <captcha|totp|hardware|sms|email-link> \
  --proof-token <token> \
  --proof-provenance <issuer-id-or-signature>
```

The response contains:
- `nonce`: echoed from the challenge
- `contact_method`: the URI where the challenge was received (for the record)
- `proof_type`: what kind of human-presence proof is included
- `proof_token`: the proof itself (CAPTCHA solution, TOTP code, hardware key signature, etc.)
- `proof_provenance`: the issuer of the proof (CAPTCHA service signature, TOTP issuer, hardware key attestation)

Signed with the operator's key. The signature binds the nonce, the proof, and the operator's identity together.

### 5.3 Human-Presence Proof

The proof is what separates "this endpoint accepts messages" from "a human saw this and responded." Without it, an agent can automate the round-trip and level 2 means nothing.

The convention defines the interface, not the implementation. Acceptable proof types:

| Proof type | What it proves | Provenance |
|-----------|---------------|------------|
| `captcha` | A human solved a visual/cognitive challenge | CAPTCHA service signature on the solution |
| `totp` | A human entered a time-based code from a device they hold | TOTP issuer identifier |
| `hardware` | A human tapped a physical key | Hardware key attestation certificate |
| `sms` | A human read an SMS and entered the code | Carrier delivery confirmation (where available) |
| `email-link` | A human clicked a unique link in an email | Signed redirect token |

The verifier's local policy decides which proof types to accept. A high-security campfire might require `hardware` only. A casual campfire might accept `captcha`. The convention carries the proof; local policy evaluates it.

### 5.4 Proof Provenance

The `proof_provenance` field carries evidence that the proof was issued by a legitimate source — not fabricated by the operator. For CAPTCHA: the CAPTCHA service's signature on the solution. For hardware keys: the attestation certificate. For TOTP: the issuer's identifier (verifiable if the verifier trusts that TOTP issuer).

If the proof type has no verifiable provenance (e.g., self-hosted CAPTCHA), the verifier's policy decides whether to accept it. The convention records whatever provenance is available; it does not mandate a specific trust chain for proofs.

---

## 6. Attestation

The signed response (§5.2) is published as a message in a campfire. This message IS the attestation. It is a regular campfire message — readable by anyone who has access to that campfire, verifiable by anyone who has the operator's public key.

### 6.1 Where Attestations Live

Attestations can be published in:

- **The operator's home campfire** — the operator's own record of their verifications
- **The verifier's campfire** — the verifier's record
- **A shared attestation campfire** — a campfire dedicated to collecting attestations (e.g., a peering directory)
- **The campfire where the challenge originated** — completing the exchange in-place

The location is agreed between verifier and operator. The convention does not mandate a specific campfire. What matters is that the attestation is a signed message that can be read and verified.

### 6.2 Attestation Fields

The attestation message carries these fields (structured as a convention operation payload):

| Field | Type | Description |
|-------|------|-------------|
| `target_key` | key | The public key that was verified |
| `nonce` | hex | The challenge nonce (proves this is a response to a specific challenge) |
| `contact_method` | string | The contact URI that was tested |
| `proof_type` | enum | Type of human-presence proof |
| `proof_provenance` | string | Issuer signature or attestation for the proof |
| `verified_at` | timestamp | When the verification completed |
| `verifier_key` | key | Public key of the entity that issued the challenge |

**Co-signing is the default.** Attestations SHOULD be co-signed by both the operator's key and the verifier's key. A co-signed attestation proves both parties participated in the exchange. Non-co-signed attestations (signed only by the operator) SHOULD be flagged in the provenance display and MAY be treated as weaker evidence by local policy.

Co-signing is the primary defense against attestation forgery — without the verifier's signature, an adversary who obtains the operator's key can fabricate attestations.

### 6.3 Attestation Freshness

Level 3 (Present) requires a fresh attestation — one whose `verified_at` timestamp is within the verifier's freshness window. As attestations age, they naturally decay from level 3 to level 2.

An operator can maintain level 3 by periodically re-verifying. The convention does not define automatic re-verification — the operator or their tooling initiates it. A campfire that requires level 3 for participation SHOULD publish its freshness window so operators know how often to re-verify.

---

## 7. Transitivity

Attestations are campfire messages. If an attestation is in a campfire I trust, I can accept it transitively.

### 7.1 How Transitivity Works

Alice verifies Bob's contact method. The attestation is published in Alice's campfire. Carol trusts Alice as a verifier. Carol reads the attestation and accepts Bob at level 2.

Transitivity evaluates the `verifier_key` field, not just the campfire where the attestation was found. An agent accepts a transitive attestation only if the `verifier_key` belongs to a key the agent trusts as a verifier — regardless of which campfire the attestation appears in. This prevents attestation replay: Eve cannot copy Alice's attestation of Bob into Eve's campfire and have Dave accept it on Eve's authority. Dave checks that Alice (the verifier_key) is someone Dave trusts, not that Eve's campfire is trusted.

### 7.2 Transitivity Limits

Transitivity is bounded by the reader's local policy:

- **Depth limit:** An operator MAY configure a maximum transitivity depth (default: 1 — accept attestations from directly trusted campfires only, not from campfires-of-campfires).
- **Proof type filter:** An operator MAY only accept transitive attestations with specific proof types (e.g., "accept transitive `hardware` attestations, require direct verification for `captcha`").
- **Freshness decay:** Transitive attestations MAY apply a tighter freshness window than direct attestations (e.g., "direct attestations fresh for 24h, transitive for 1h").

### 7.3 No Infinite Chains

Transitivity does not compose indefinitely. Alice verified Bob. Carol trusts Alice. But if Dave trusts Carol and reads Bob's attestation through Carol's campfire, the chain is Alice → Carol → Dave — two hops. The operator's depth limit controls whether this is accepted.

Default depth of 1 means: I trust attestations from campfires I directly trust. Not from campfires my trusted campfires trust.

---

## 8. Integration with Convention Operations

Individual convention operations declare a minimum operator provenance level via the `min_operator_level` field in their declaration:

```json
{
  "convention": "peering",
  "operation": "routing-beacon",
  "min_operator_level": 0,
  ...
}
```

```json
{
  "convention": "peering",
  "operation": "core-peer-establish",
  "min_operator_level": 2,
  ...
}
```

### 8.1 Enforcement

The runtime checks the sender's highest observed provenance level against the operation's `min_operator_level`. If the sender's level is below the minimum, the operation is rejected with an error indicating the required level.

The campfire operator can raise `min_operator_level` above what the convention declaration specifies (local policy is sovereign). The campfire operator cannot lower it below the convention's declared minimum — the convention author set the floor, the operator can raise the ceiling.

### 8.2 Provenance Level Computation

The runtime computes the sender's provenance level from the attestations it has observed:

1. **Level 0:** Default for all keys.
2. **Level 1:** The sender has published an agent profile with operator fields (agent-profile convention).
3. **Level 2:** The runtime has seen a valid attestation for the sender's key (directly or transitively, per local policy).
4. **Level 3:** Same as level 2, and the attestation's `verified_at` is within the freshness window.

The computation is local — each runtime evaluates independently based on its own policy and the attestations it has seen. Two runtimes may compute different levels for the same key if they have different attestation visibility or different freshness windows.

---

## 9. Peering Tier Integration

The trust convention (v0.2 §9.3) defines peering tiers gated by operator provenance. This section provides the concrete mappings.

### 9.1 Default Tier Requirements

| Tier | `min_operator_level` | Rationale |
|------|---------------------|-----------|
| Core peering | 2 | Load-bearing links. Revocation is expensive. Need a human to call. |
| Standard peering | 1 | Organizational links. Claimed identity provides a starting point for accountability. |
| Leaf peering | 0 | Edge connections. Disposable. Blast radius is contained. |

These are defaults. An operator running a private network can set all tiers to 0 (no provenance required) or all tiers to 3 (paranoid mode). The convention provides the mechanism; the operator sets the policy.

### 9.2 Why Leaf Peering is Safe at Level 0

Leaf peers are safe without provenance because the relationship is disposable:

- Revoking a leaf peer's route is a single `routing-withdraw` message.
- No dependent routes break when a leaf is cut.
- The core network's topology is unaffected.
- Content from leaf peers is already enveloped with `operator_provenance: 0`, so agents apply appropriate skepticism.

The network is resilient because the expensive links (core) have accountability, and the cheap links (edge) are expendable.

---

## 10. Security Considerations

### 10.1 Automated Verification Bypass

An agent automates the entire challenge/response flow, including solving the CAPTCHA programmatically, making level 2 meaningless.

**Mitigations:**
- The human-presence proof is the defense layer. CAPTCHA-solving services exist but are costly and slow, raising the bar above "trivially automatable."
- Verifiers MAY require specific proof types that are harder to automate (hardware key, TOTP from a hardware token).
- The convention does not claim proof of humanity — it claims proof that a human-gated step was in the loop. The economic cost of bypassing that step is the security margin.

### 10.2 Stale Attestations

An operator verifies once and abandons the key. The attestation persists, claiming level 2 forever, even though nobody is home.

**Mitigations:**
- Level 3 exists specifically for this scenario. If freshness matters, require level 3.
- Level 2 attestations naturally become less trustworthy over time. Operators MAY configure an absolute maximum age for level 2 attestations (e.g., "level 2 attestations older than 90 days are treated as level 1").
- Campfires that require accountability SHOULD require level 3 with a reasonable freshness window.

### 10.3 Attestation Forgery

An attacker creates a fake attestation message, claiming to have verified an operator.

**Mitigations:**
- Attestations are signed by the operator's key AND optionally co-signed by the verifier.
- The nonce binds the attestation to a specific challenge. Without the original challenge (which was sent to the real contact method), the attestation cannot reference a legitimate exchange.
- Transitivity limits (§7.2) bound the blast radius of a forged attestation — it only affects agents that trust the campfire where it was published.

### 10.4 Contact Method Takeover

An attacker takes over the operator's contact method (compromised email, SIM swap, hijacked campfire) and completes verification.

**Mitigations:**
- This is a real risk with no protocol-level fix. If the contact method is compromised, verification is compromised.
- Multiple contact methods mitigate: an operator who verifies via both campfire and hardware key is protected against campfire-only compromise.
- Level 3 freshness provides natural rotation — if the real operator re-verifies regularly, a hijacker's attestation expires.

### 10.5 Self-Attestation Rejection

A runtime MUST NOT accept an attestation where the `verifier_key` matches the `target_key`. Self-attestations — where an operator verifies themselves — are rejected by default. This prevents mass self-verification Sybil attacks where an adversary generates many keys and self-verifies each to level 2.

Operators MAY override this for specific use cases (e.g., single-operator networks with no external verifiers) by configuring an explicit exception in their local policy. The exception is a safety-reducing Layer 3b change (Trust Convention §7.3) and requires operator authorization.

### 10.6 Provenance Inflation

An agent self-hosts a CAPTCHA service and uses a second colluding key to "verify" itself, bypassing the self-attestation rejection.

**Mitigations:**
- The `proof_provenance` field records the proof issuer. Verifiers can reject proofs from unknown or untrusted issuers.
- High-stakes campfires can require proofs from specific issuers (e.g., "only accept hardware key attestations from FIDO-certified devices").
- Campfires that require level 2+ for core peering SHOULD require attestations from at least 2 distinct verifier keys. This makes a single colluding pair insufficient.

### 10.6 Privacy

Operator provenance reveals the operator's contact method, the proof mechanism they used, and when they were last active. This information may be sensitive.

**Mitigations:**
- Verification is opt-in. Level 0 is the default and reveals nothing.
- Attestations can be published in private campfires with restricted membership.
- The contact method in the attestation can be a dedicated verification-only campfire rather than a personal endpoint.
- The convention does not require real-world identity — a pseudonymous operator with a dedicated contact campfire is a valid level 2 participant.

---

## 11. Interaction with Other Conventions

### 11.1 Trust Convention

The trust convention (v0.2) defines the policy framework. This convention provides the provenance levels that the trust convention references in: safety envelope `operator_provenance` field, federation peering tiers, and `min_operator_level` enforcement.

### 11.2 Agent Profile Convention

The agent profile convention's `operator_name` and `operator_contact` fields are level 1 (self-asserted, tainted). Operator provenance gives those fields a graduation path — from tainted (level 1) to verified (level 2) to liveness-proven (level 3). The profile convention does not change; operator provenance adds a verification layer on top.

### 11.3 Peering Convention

The peering convention's `core-peer-establish` operation (or equivalent) SHOULD declare `min_operator_level: 2`. The peering convention defines the routing operations; this convention defines the provenance gate.

### 11.4 Convention Extension Convention

The `min_operator_level` field is an extension to the convention declaration format. The convention extension convention SHOULD be updated to include `min_operator_level` as an optional field in the declaration schema, with default value 0.

---

## 12. Convention Operations

Three convention operations define the verification exchange as campfire messages.

### 12.1 operator-challenge

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `target_key` | key | yes | Public key of the operator being challenged |
| `nonce` | hex (32 bytes) | yes | Cryptographically random challenge value |
| `callback_campfire` | campfire | yes | Where to send the response |

Signing: `member_key`. Tags: `provenance:challenge`. Rate limit: 10/sender/hour. Target-side rate limit: a target key SHOULD process at most 10 challenges per hour from all senders combined. Additional challenges are queued. This prevents challenge-flooding DoS where many senders each send challenges within their individual rate limit.

### 12.2 operator-verify

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `nonce` | hex (32 bytes) | yes | Echoed from the challenge |
| `target_key` | key | yes | Echoed from the challenge (runtime MUST verify match) |
| `contact_method` | string | yes | URI where the challenge was received |
| `proof_type` | enum | yes | `captcha`, `totp`, `hardware`, `sms`, `email-link` |
| `proof_token` | string | yes | The proof itself |
| `proof_provenance` | string | yes | Issuer signature or attestation |

Signing: `member_key`. Tags: `provenance:verify`. Antecedent: `exactly_one(target)` — MUST reference the specific `operator-challenge` message ID (not just echo the nonce). The runtime rejects responses whose antecedent does not reference a valid challenge, preventing nonce-hijacking where an adversary intercepts a nonce and responds to a different challenge. Rate limit: 10/sender/hour.

### 12.3 operator-revoke

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `attestation_id` | message_id | yes | The attestation message being revoked |
| `reason` | string | no | Why the attestation is being revoked |

Signing: `member_key` (must match the attestation's key). Tags: `provenance:revoke`. Antecedent: `exactly_one(target)`.

---

## 13. UX: Verbs and Nouns

The interface is verbs and nouns. The runtime sequences the convention operations. Nobody — human or agent — thinks about nonces, callback campfires, or proof tokens.

```bash
cf verify <key-or-name>                  # verify an operator
cf verify <key-or-name> --revoke         # revoke a prior verification
cf provenance show <key>                 # check an operator's provenance level
```

### 13.1 `cf verify`

**What you say:** `cf verify alice`

**What happens:**
1. Looks up alice's contact campfire (from agent profile)
2. Generates nonce, sends `operator-challenge`
3. Waits for `operator-verify` response (timeout: 5m default)
4. Validates proof
5. Stores attestation
6. Reports: "Operator verified at level 2" or "No response within 5m"

**On the other side:** The runtime detects an incoming challenge and prompts: "Verification request from \<key\>. Complete CAPTCHA? [Y/n]". Proof collection and response happen inline. For non-interactive agents, a pre-authorized proof source (hardware key, TOTP) auto-responds.

### 13.2 `cf provenance show`

Local state introspection. Displays provenance level, attestation history, freshness status. No messages sent.

---

## 14. Reference Implementation

### 14.1 What to Build

1. **Attestation store** (Go, `pkg/provenance/`)
   - Store/query attestations, compute provenance levels, handle transitivity
   - ~200 LOC

2. **Challenge/response flow** (Go, `pkg/provenance/`)
   - Nonce generation, response validation, pluggable proof verifier interface
   - ~150 LOC

3. **`cf verify`** (Go, `cmd/cf/`)
   - Contact lookup, challenge/wait/validate sequencing, interactive proof collection
   - ~150 LOC

4. **`cf provenance show`** (Go, `cmd/cf/`)
   - Local attestation store query and display
   - ~50 LOC

5. **`min_operator_level` gate** (Go, `pkg/convention/`)
   - Check on operation dispatch, reject below threshold
   - ~50 LOC

**Total:** ~600 LOC, pure Go, no new dependencies beyond a pluggable proof validation interface.

### 14.2 Integration Points

- `pkg/trust/`: safety envelope calls provenance store for `operator_provenance` field
- `pkg/convention/`: operation dispatch checks `min_operator_level`
- `cmd/cf-mcp/`: provenance level in tool responses; convention operations exposed as MCP tools
- `cmd/cf/`: `cf verify`, `cf provenance show`

---

## 15. Open Questions

1. **Proof issuer trust.** The convention defines proof types but not which issuers are trustworthy. Should there be a well-known list of CAPTCHA service keys, FIDO attestation roots, etc.? Or is this purely local policy? Leaning toward local policy with a recommended set in the reference implementation.

2. **Mutual verification.** The current flow is one-directional: verifier challenges operator. Should there be a mutual verification flow where both parties verify each other simultaneously? Relevant for core peering where both sides need accountability.

3. **Delegation.** Can an operator delegate verification to a subordinate key? E.g., "my operations key is verified; here's a signed delegation to this agent key." This would allow operators to verify once and delegate to multiple agents. Not defined in this draft.

4. **Group operators.** An organization with multiple humans operating a fleet of agents. How does provenance work when the "operator" is a team? Threshold signatures on the attestation (M-of-N team members co-sign) is one approach. Not defined in this draft.
