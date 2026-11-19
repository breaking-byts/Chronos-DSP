# Public showcase posture: no auth, capped ephemeral scene persistence

Status: accepted

Chronos-DSP is published as a single-tenant showcase demo, not a multi-user
product: no authentication and no per-user isolation. The named-scene store
accepts anonymous writes but is capped (scene count and total bytes, FIFO
eviction, bounded description/vertices) and ephemeral by design — container
disk is not durable, and `docs/DEPLOYMENT.md`'s stateless contract is amended
to say so rather than attaching a volume. Chosen over auth-plus-quotas (product
complexity a demo does not need) and per-session-only storage (which loses
shareable named scenes); durable storage and any auth revisit belong to the
deferred deployment effort.

## Consequences

- Anonymous visitors can delete any scene; acceptable for a showcase, bounded
  by the caps.
- Scenes vanish on redeploy unless a future deployment attaches a volume and
  sets `SCENE_DIR`.
- Multi-machine scaling would give each node a divergent store; the showcase
  assumes a single node (sticky-session constraint already documented).