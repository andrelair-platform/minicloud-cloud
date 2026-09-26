# ADR-0002 — Always-free external heartbeat + public status page (external observability anchor)

**Status:** Proposed (decision) · **provisioning NOT started** (plan only — awaiting owner approval)
**Date:** 2026-09-26
**Context:** Reliability audit (2026-09-26) found an **external-observability blind spot**: monitoring
(Prometheus/Grafana/Alertmanager) runs *inside* the cluster, and CoreDNS + the API server are both on
the single control-plane node `set-hog`. **A cluster cannot monitor its own death** — if `set-hog`, the
LAN, the home ISP, or power fails, the in-cluster stack goes dark *with* the platform and no signal
leaves the failure domain. Realises "Anchor 1" from the hybrid-cloud discussion and the always-free
tier of `.claude/rules/cloud-adoption.md` (*3-tier free model*).

## Decision

Run a small **external heartbeat** in a **different failure domain** that probes the platform's public
endpoints on a schedule, records state in an always-free store, and renders a **public status page**.
It answers, from *outside* the house: *is the site up right now?* — covering audit Scenarios **C**
(control-plane node down), **G** (DNS down), **K** (ingress node down) and **L** (total site/power loss),
none of which the in-cluster monitors can report once they're down too.

**Scope (deliberately minimal):** black-box *availability* probing + a status page + an alert on
transition to DOWN. It does **not** replace in-cluster Prometheus (white-box metrics) — it is the
outside vantage that Prometheus structurally cannot be.

## Why this passes the `cloud-adoption.md` gate

| Gate | Satisfied |
|---|---|
| Real need | External-observability blind spot (audit §11) — no failure signal leaves the single site today |
| Justification | **DORA Art. 11–12** (business-continuity monitoring) + operational: detect total-site outage from outside |
| Free / in-cap | **Always-free** (see options) — €0 steady state; covered by the existing €15 AWS budget + €1-tripwire pattern |
| Layer-routed | ktayl-IS layer (infrastructure observability); documented here in `minicloud-cloud` |
| Terraform + destroyable | OpenTofu in this repo, gated behind `enable_*` like the OCI node; one-flag teardown |

## Options considered (per `ai-native-engineering.md` — I recommend, the owner decides)

### Option A — Reuse the OCI DR node (systemd timer + script)
A cron/systemd timer on the existing always-free OCI A1 node (ADR-0001) curls the public URLs and
pushes to Healthchecks.io / writes a static status file.
- **+** Zero new provider lane, zero new cost, reuses standing compute.
- **−** The monitor shares a failure domain with the **DR target itself**. OCI always-free has a
  documented **idle-reclaim + ARM-capacity** caveat (ADR-0001) — if the DR node is reclaimed or
  unreachable, you lose the monitor *and* the restore landing zone together. A monitor should be the
  most independent thing you own.

### Option B — AWS serverless (Lambda + EventBridge + DynamoDB + CloudFront)  ✅ **recommended**
A scheduled Lambda probes the endpoints, writes status to DynamoDB, and a static status page is served
from S3-behind-CloudFront (or CloudFront Function). Entirely on the AWS **always-free** tier.
- **+** A **third, fully independent failure domain** (not home, not OCI). Zero-maintenance (no VM to
  patch). Matches the AWS *serverless/IAM* lane in `cloud-adoption.md`. Survives every credit/12-month
  cliff — all pieces are perpetual-free.
- **−** One more small IaC surface (Lambda + a table + a distribution). A public status page is a
  public surface → security review item (below).

**Recommendation: Option B.** The entire value of an external monitor is *independence*; hosting it on
the DR node (Option A) couples the two most safety-critical externals. Keep A in your pocket as a
zero-effort fallback if AWS ever falls out of scope.

## Design (Option B — always-free primitives only)

```
 EventBridge (rate: 5 min)                         Cloudflare Tunnel → ingress-nginx → apps
        │                                                      ▲  (probed from outside)
        ▼                                                      │
   Lambda  probe_targets ─────── HTTPS GET ───────────────────┘
        │   (ktayl.devandre.sbs, argocd/grafana.devandre.sbs, a /healthz)
        ▼
   DynamoDB  minicloud-status   ◄── last state + last-change per target (25 GB always-free)
        │
        ├─► on UP→DOWN transition: SNS → email  (1M/mo always-free)
        ▼
   S3 (static JSON+HTML) ── CloudFront ──►  https://status.devandre.sbs  (1 TB egress always-free)
```

- **Probe targets:** the *public* URLs (through Cloudflare) — this exercises the **whole external path**
  (Cloudflare → tunnel → ingress → svc → pod), which is exactly what an internal probe can't see. Include
  a lightweight app `/healthz` and 2–3 representative apps; keep the list in a variable.
- **State in DynamoDB** (not a file): one item per target with `status`, `lastChange`, `lastError` →
  enables "down for N minutes" and a history without any server. Always-free 25 GB is effectively unlimited here.
- **Alert on transition only** (UP→DOWN / DOWN→UP), not every tick → SNS→email. Complements the existing
  Healthchecks.io heartbeats (`[[reference_healthchecks_io]]`) rather than duplicating them: Healthchecks
  watches *the controller pushing out*; this watches *the site answering from outside*.
- **Status page:** a static HTML/JSON on S3+CloudFront — stays up **even when all 6 laptops are down**
  (the recruiter/DR-visibility win). Public-read only; no write path from the internet.
- **Credentials & IaC:** AWS creds already flow from Vault `secret/platform/cloud-providers`
  (`scripts/load-env.sh`); add an `enable_external_heartbeat` bool (default `false`) so it ships dark and
  is torn down with one flag, exactly like `enable_oci_dr_node`.

### Proposed repo layout (no `apply` in this ADR)
```
minicloud-cloud/
  aws-heartbeat.tf        # lambda + eventbridge rule + dynamodb table + sns topic + s3/cloudfront
  modules/heartbeat/      # (optional) if it grows; else keep flat like oci-dr-node.tf
  lambda/heartbeat/       # handler (Python 3.12 — probe → dynamodb → sns), zipped by archive_file
  variables.tf            # + enable_external_heartbeat, heartbeat_targets[], heartbeat_alert_email
```
Static validation only until approved: `tofu fmt && tofu init -backend=false && tofu validate && tflint`.

## Security review items (public surface — clear before `apply`)
- **Status page leaks nothing sensitive:** publish only `name + up/down + since` — never internal IPs,
  versions, or error bodies (truncate/whitelist `lastError`). CloudFront **public-read S3 only**, OAC, no
  bucket write from the edge.
- **Lambda egress is outbound HTTPS only**; least-privilege IAM (put/get on the one table, publish to the
  one SNS topic, nothing else). No inbound.
- **No secrets in the probe:** hit public health endpoints; do not embed tokens to reach auth-gated apps
  (probe the SSO login returning 200/302, not behind it).

## Cost & exit test
- **Cost:** €0 steady-state (all always-free); bounded by the existing €15 AWS budget (`budgets.tf`).
  5-min probes ≈ 8.6k Lambda invokes/mo ≪ 1M free; DynamoDB/CloudFront/SNS all ≪ free limits.
- **Exit test (mandatory, per `cloud-adoption.md`):**
  `tofu apply -var=enable_external_heartbeat=false` (or `-target` destroy) removes Lambda/table/topic/
  distribution. **Check the laptop cluster is unaffected:** it never was a dependency — the heartbeat only
  *reads* public URLs; removing it changes nothing in-cluster (verify: `kubectl get nodes`,
  in-cluster monitoring unchanged). This is a pure add-on observer with zero coupling to the primary platform.

## Consequences
- **+** A failure signal finally leaves the single failure domain; total-site outage is *detected*, and
  the public status/portfolio stays reachable during it. Closes audit §11's external blind spot at €0 forever.
- **+** Independent of home **and** of the OCI DR node — no shared-fate with the thing it might monitor.
- **−** A new (small) AWS IaC surface + a public page to keep boring/safe (security items above).
- **−** Black-box only — it says *down*, not *why*; root-cause still needs the in-cluster stack once it's back.

## ⛔ Prerequisites (owner, before provisioning)
1. Approve **Option B** (or pick A).
2. Decide the **public hostname** (`status.devandre.sbs`) + add the Cloudflare DNS/tunnel or CloudFront CNAME.
3. Confirm the **probe target list** (which apps represent "the platform is up").
4. Then: implement `lambda/heartbeat/` + `aws-heartbeat.tf`, `tofu plan` for review, and only then `apply`
   with `enable_external_heartbeat=true`. Pair this ADR with an org-docs pointer page (`documentation.md`).
