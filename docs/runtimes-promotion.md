# Design Note: Runtimes-Umbrella Promotion Gap

**Status:** Design only — no code/pipeline change in this PR.
**Related finding:** `docs/multicluster-poc-plan.md` (see the "FINDING — the runtimes
umbrella is a SECOND, un-automated promotion surface" note and the promotion table).
**Owner decision required:** platform team / release captain.

## Problem

The capability pipeline's `bump-staging` job
(`.github/workflows/capability-pipeline.yaml`) auto-bumps exactly one file when a
capability publishes a new chart version:

```
argocd/staging/Chart.yaml        # the staging HUB control-plane umbrella
```

It does **not** touch:

```
argocd/runtimes/<env>/Chart.yaml # what a runtime SPOKE actually runs
```

So a runtime spoke keeps running whatever versions are pinned in
`argocd/runtimes/<env>/Chart.yaml` until someone promotes them by hand. Today the
staging hub and the staging runtime can silently diverge — e.g. the hub is on
`team-cache 1.0.6` while `argocd/runtimes/staging/Chart.yaml` still pins
`team-cache 1.0.5`. Because "any cluster with users = production for the platform
team," a spoke running stale capability RGDs is a real (medium) production-readiness
gap: fixes/upgrades validated on the hub do not reach the surface that developer
workloads actually consume.

This is inherent to pin-everywhere (no floating `targetRevision`): every pinned
surface is its own promotion step. The runtimes umbrella is simply a promotion
surface that has no automation attached yet.

## Why this is NOT auto-fixed in this PR

The runtimes umbrella is deliberately modeled on the **production** pattern
(`argocd/production/Chart.yaml`): promotion is a reviewed, platform-team-only PR —
the release-captain gate (`docs/multicluster-poc-plan.md`, Gate 2). Auto-bumping
`runtimes/<env>` from CI would:

- couple a capability team's merge to what runtime spokes run, bypassing the
  release captain's review of "is this version safe to run on production runtimes?";
- multiply across 3+ runtimes (dev/uat/prod) into a hand-or-bot-edited promotion
  matrix that must stay consistent;
- interact with the future "platform" GitOps repo split
  (`multicluster-poc-plan.md`), where `runtimes/**` is CODEOWNERS-gated to the
  platform team.

Changing the bump logic therefore needs an explicit decision, not a drive-by edit.

## Options

### Option A — Keep runtime promotion fully manual (status quo, documented)
`bump-staging` continues to target only `argocd/staging/Chart.yaml`. Runtime
promotion is a documented manual runbook: after a hub bump soaks, a platform-team
member opens a reviewed PR bumping `argocd/runtimes/<env>/Chart.yaml`.

- Pros: preserves the release-captain gate exactly; zero new automation risk;
  matches the production-umbrella model already in use.
- Cons: relies on humans remembering; drift is invisible unless someone diffs
  the two umbrellas; scales poorly past a couple of runtimes.

### Option B — Auto-bump only the *staging* runtime; keep prod manual
Extend `bump-staging` to also open a bump PR against
`argocd/runtimes/staging/Chart.yaml` (staging runtime is the CI-owned, no-human
tier, symmetric with the staging hub). Non-staging runtimes (uat/prod) stay a
reviewed platform-team PR.

- Pros: closes the drift on the one tier that is already "no human" by design;
  keeps every production-grade runtime behind the release captain.
- Cons: a second auto-merged PR into `main` — must inherit the same
  branch-protection + CODEOWNERS gate recommended for the hub bump (see below);
  `bump-staging` must know which chart names belong in the runtime umbrella
  (e.g. `tenant` is in `runtimes/*` but not the hub umbrella), so the bump needs
  a per-target allowlist rather than blindly writing every chart name.

### Option C — Drift detector instead of auto-bump
Leave promotion manual (Option A) but add a scheduled/PR check that fails or
warns when `argocd/runtimes/<env>/Chart.yaml` pins lag the corresponding hub
umbrella beyond a threshold. Turns silent drift into a visible, actionable signal
without taking the promotion decision away from the release captain.

- Pros: keeps the human gate; makes drift observable; low blast radius.
- Cons: still needs a human to act; new check to maintain.

## Recommendation

Adopt **Option C now, Option B when staging-runtime cadence justifies it.** A
drift detector removes the "invisible" part of the gap (the actual production
risk) without weakening the release-captain gate, and it is safe to add
incrementally. Promote to Option B for the *staging* runtime only once the
staging runtime is a routine soak target and the hub bump PR is already protected
by branch protection + CODEOWNERS (so the second auto-PR inherits a review gate
rather than being a second unreviewed bot self-merge). Non-staging runtimes
should remain a reviewed platform-team PR under all options.

## Cross-references

- `docs/multicluster-poc-plan.md` — operating model, Gate 1/Gate 2, and the
  original finding + promotion-strategy table.
- `.github/workflows/capability-pipeline.yaml` — `bump-staging` job (the surface
  that would change under Option B) and the bot-self-merge hardening comments.
- `CODEOWNERS` — the `argocd/**` ownership that any runtime auto-bump PR must
  route through.
