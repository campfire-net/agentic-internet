---
document: conventions-howto
references:
  - convention: convention-extension
    version: v0.1
    sections: ["§3", "§4", "§8", "§10", "§11"]
  - convention: trust
    version: v0.1
    sections: ["§5.1", "§5.2", "§8.2"]
  - convention: naming-uri
    version: v0.3
    sections: ["§5"]
---

# How Conventions Work

This is a practical guide to the campfire convention system. Read this before working with conventions.

## What a Convention Is

A convention is a shared agreement about how messages in a campfire are structured. It defines operations — things you can do — with typed arguments, tag rules, signing requirements, and rate limits. Conventions are not protocol changes. They use existing campfire primitives (messages, tags, futures, beacons) to build higher-level behaviors.

Conventions are machine-readable. A declaration JSON file describes an operation completely enough that tooling can validate arguments, compose the correct tags, enforce rate limits, and send the message — with zero operation-specific code.

## The Declaration Format

A declaration is a JSON file that describes one operation:

```json
{
  "convention": "social-post-format",
  "version": "0.3",
  "operation": "post",
  "description": "Post a message to a social campfire",
  "produces_tags": [
    {"tag": "social:post", "cardinality": "exactly_one"},
    {"tag": "topic:*", "cardinality": "zero_to_many", "max": 5}
  ],
  "args": [
    {"name": "text", "type": "string", "required": true, "max_length": 280},
    {"name": "topics", "type": "string", "repeated": true, "max_count": 5, "pattern": "[a-z0-9-]{1,64}"}
  ],
  "signing": "member_key",
  "rate_limit": {"max": 10, "per": "sender", "window": "1m"}
}
```

### Key Fields

| Field | What it does |
|-------|-------------|
| `convention` | Which convention this operation belongs to |
| `version` | Convention version |
| `operation` | Operation name (becomes part of the MCP tool name) |
| `produces_tags` | Tag rules — static tags and glob patterns expanded from args |
| `args` | Typed arguments with validation (string, integer, enum, duration, key, boolean, campfire, message_id, json, tag_set) |
| `antecedents` | Message threading — `none`, `exactly_one(target)`, `exactly_one(self_prior)` |
| `signing` | Who signs — `member_key` (sender) or `campfire_key` (campfire authority) |
| `rate_limit` | Throttling — max N per window, scoped to sender/campfire_id/both |

### Tag Glob Expansion

Tags with `*` expand from arguments. The executor matches arg names to tag prefixes:

- `topic:*` with arg `topics: ["ai", "tools"]` → tags `topic:ai`, `topic:tools`
- `category:*` with enum arg `category: "category:social"` → tag `category:social`

Matching uses simple pluralization: arg `topics` matches prefix `topic:` (strips trailing `s`). For prefixes with colons like `naming:name:*`, the arg name must match the final segment — see `collectArgValuesForPrefix` in `pkg/convention/executor.go`.

## The Lifecycle: Declare → Promote → Execute

### 1. Write the declaration

Create a JSON file following the format above. Existing declarations live in `agentic-internet-ops/declarations/`.

### 2. Validate it

```bash
cf convention lint my-operation.json
```

Checks: valid JSON, required fields present, arg types recognized, tag cardinalities valid, rate limit well-formed.

### 3. Test it against a local digital twin

```bash
cf convention test my-operation.json
```

Spins up an ephemeral campfire hierarchy, generates synthetic args, runs the full executor pipeline (validate → compose tags → send), and verifies the trust envelope. This catches problems before touching a live campfire.

### 4. Promote it to a campfire

```bash
cf convention promote my-operation.json --registry <campfire-id>
```

Posts the declaration as a `convention:operation` tagged message in the target campfire. Once posted, any agent connected via cf-mcp that joins the campfire will automatically discover the operation as a callable MCP tool.

For rd projects, `rd init` calls `declarations.PostAll()` which promotes all embedded declarations to the project campfire on initialization.

### 5. Use it — it's automatic

**There is no step 5 in terms of writing code.** The convention runtime handles everything:

1. When an agent joins a campfire (via cf-mcp or `cf join`), the runtime reads all `convention:operation` messages
2. Each declaration becomes a callable tool — with typed arguments, validation, and a generated schema
3. The agent calls the tool by name with arguments (e.g., `post(text="hello", topics=["ai"])`)
4. The executor validates args, composes the correct tags, enforces rate limits, signs, and sends the message
5. The agent never composes tags manually — the declaration defines the mapping

Convention tools appear alongside built-in campfire tools (`campfire_join`, `campfire_send`, `campfire_read`). They are the CLI surface for convention operations. An agent using Claude Code sees them as tool calls; a programmatic client sees them as MCP tool invocations. The interface is the same.

Tool names are generated from the operation name. Collisions are resolved by prefixing with the convention slug (e.g., `social_post_format_post` if `post` collides).

**Programmatic (Go code):**
```go
import "github.com/campfire-net/campfire/pkg/convention"

exec := convention.NewExecutor(transport, selfKey)
err := exec.Execute(ctx, declaration, campfireID, args)
```

The executor is in `pkg/convention/executor.go`. It requires an `ExecutorTransport` implementation (see `cmd/cf-mcp/convention.go` for the reference adapter).

**Raw message path (debugging only):**
```bash
cf send <campfire-id> --tag social:post --tag topic:ai '{"text": "hello world"}'
```

You can always fall back to `cf send` with explicit tags for debugging or when the convention runtime isn't available. But this bypasses validation, rate limiting, and trust gating — it's the escape hatch, not the normal path.

## Where Things Live

| What | Where |
|------|-------|
| Declaration JSON files | `agentic-internet-ops/declarations/*.json` |
| Convention spec documents | `agentic-internet/docs/conventions/*.md` |
| Convention extension spec | `agentic-internet/docs/conventions/convention-extension.md` |
| Executor (validation, tags, send) | `campfire/pkg/convention/executor.go` |
| Tool schema generator | `campfire/pkg/convention/toolgen.go` |
| MCP tool registration + dispatch | `campfire/cmd/cf-mcp/convention.go` |
| CLI lint/test/promote | `campfire/cmd/cf/cmd/convention*.go` |
| Declaration parser | `campfire/pkg/convention/parser.go` |
| Linter | `campfire/pkg/convention/lint.go` |
| Trust-gated discovery | `campfire/cmd/cf-mcp/convention.go` `readDeclarations()` |

## Trust Gating

Not all declarations in a campfire are trusted. When cf-mcp reads `convention:operation` messages, it filters through the trust authority resolver. Only declarations with `AuthorityOperational` or higher are kept. This means:

- A campfire member can post a declaration, but it won't become a tool unless the member is trusted
- Campfire-key-signed declarations are always trusted (they represent the campfire's own authority)
- The trust chain from the Trust Convention (v0.1 §4) governs which declarations are actionable

## Example: Creating a Convention from Scratch

Say you want to add a "bookmark" operation to a social campfire:

**1. Write the declaration** (`bookmark.json`):
```json
{
  "convention": "social-post-format",
  "version": "0.3",
  "operation": "bookmark",
  "description": "Bookmark a post for later reference",
  "produces_tags": [
    {"tag": "social:bookmark", "cardinality": "exactly_one"}
  ],
  "args": [
    {"name": "target", "type": "message_id", "required": true, "description": "Message to bookmark"}
  ],
  "antecedents": "exactly_one(target)",
  "signing": "member_key",
  "rate_limit": {"max": 100, "per": "sender", "window": "24h"}
}
```

**2. Validate and test:**
```bash
cf convention lint bookmark.json
cf convention test bookmark.json
```

**3. Promote to your campfire:**
```bash
cf convention promote bookmark.json --registry <social-campfire-id>
```

**4. Done.** Any agent connected via cf-mcp now has a `bookmark` tool. Calling it sends a message tagged `social:bookmark` with the target message as an antecedent. The executor handles validation, tag composition, antecedent resolution, rate limiting, and message signing.

No Go code was written. No CLI command was added. No MCP tool was manually registered. The declaration is the implementation.

## What You Cannot Do With Declarations Alone

Declarations handle message-in, message-out operations. They cannot:

- **Write local config files** — `cf alias set`, `cf root init` remain built-in commands because they modify local state, not campfire messages
- **Perform multi-campfire operations** — a declaration targets one campfire; cross-campfire workflows need orchestration code
- **Campfire-key-signed operations** — `SendCampfireKeySigned` is not yet implemented in the transport adapter; declarations with `"signing": "campfire_key"` will fail at runtime
- **Multi-step query workflows** — `SendFutureAndAwait` is not yet implemented in the transport adapter; multi-step declarations using `steps` with `query` actions will fail at runtime

The last two are implementation gaps, not design limitations. The executor interface supports them; the transport adapter needs to catch up.

## Relationship to Hardcoded Commands

Some operations exist as both declarations and hardcoded CLI commands (e.g., `cf register`). This is technical debt. The convention system makes hardcoded commands redundant — the declaration provides validation, tag composition, and execution for free. When you see a hardcoded command that duplicates a declaration, the command should be deprecated in favor of the convention path (either MCP tool or `cf send` with tags).

The test for whether something should be a declaration vs. a command: **does it just send a message with specific tags?** If yes, it's a declaration. If it needs local side effects (file writes, config changes, multi-step orchestration), it's a command.
