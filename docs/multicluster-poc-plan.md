# Implementation Plan — Repeatable Multi-Cluster Hub-Spoke PoC

## 1. Verdict

**The design is sound for a single-account PoC.** Treating cluster provisioning as just another kro capability (`kind: Runtime` → ACK `eks.services.k8s.aws` CRs) reuses one mental model and one toolchain (RGD authoring, the `lint→tier1→tier2→publish→bump` pipeline, version pinning) for everything from a database to a whole cluster. Phase 1 already proved the make-or-break unknown: the hub's ACK can create a 2nd cluster, land a `Capability` on it, and register it as an ArgoCD spoke.

**Simplify for the PoC (do these):**
- **Shrink to 1 control plane + 1 runtime first.** The 5-cluster matrix (stag+prod CPs × stag/dev/prod runtimes) multiplies cost/operational surface without de-risking anything Phase 1 didn't already prove. Close the loop once on `1 CP → 1 runtime → 1 app`, then fan out.
- **In-runtime topology injection: DECIDED** — two-secret split (Option A), validated live (see §7). The Runtime RGD emits an `in-cluster` deploy Secret + a uniquely-named `*-topology` annotations Secret per spoke.
- **Keep `RETAIN` + an explicit documented reset runbook** (not auto-delete) — matches the production-safety rule and the design decision.

Everything else in the design (two-ArgoCD split, single shared VPC, pin-everywhere, RGD-as-capability) is appropriate as a PoC.

---

## 2. The Abstraction Promotion Lifecycle — the operating model the platform ENFORCES

> This is the spine of the PoC. The point is **not** "deploy the platform" — it is to show **how the platform team enforces the promotion of abstractions (capability RGDs) from tested → staging → production**, while capability teams retain autonomy up to ECR. The existing single-cluster model (see `platform-core/docs/platform-strategy.html` — "Capability Lifecycle: Tested → Published → Deployed", "Automated: Staging / Controlled: Production") is the contract; the multi-cluster topology must preserve it 1:1, just with **runtime clusters** as the promotion targets instead of one shared cluster.

### Two ownership gates (the autonomy boundary)

| Gate | Owner | Question it answers | Mechanism (REUSED, unchanged) | Artifact |
|---|---|---|---|---|
| **Gate 1 — Publish** | **Capability team** (autonomous) | "Is my abstraction correct?" | `capability-pipeline.yaml`: `lint → tier1 → real-infra-test → publish` (the team's 25-line caller is their only pipeline code; the platform OWNS the pipeline logic — `platform-strategy.html` "Platform Team Owns the Capability Pipeline" / "Governed Upgrade Path") | versioned chart in ECR, e.g. `team-database:1.2.0` |
| **Gate 2 — Promote** | **Platform team** (controlled) | "Is this version safe to run on production runtimes?" | a reviewed PR bumping the pin in `runtimes/<env>/Chart.yaml` (the **production** pattern from `argocd/production/Chart.yaml`) | the pin advancing per runtime |

Capability teams **cannot** promote to production — their authority ends at ECR. The platform team **cannot** publish an untested abstraction — Gate 1's `real-infra-test` blocks anything that didn't provision real AWS and pass. The gates are mutually constraining by construction; this is the enforcement.

### The flow, mapped onto the multi-cluster topology

```
CAPABILITY TEAM (autonomous, up to ECR)         PLATFORM TEAM (owns promotion lifecycle)
─────────────────────────────────────           ──────────────────────────────────────────
RGD change → PR → lint / tier1 / tier2  ──┐
  (real RDS provisioned, asserted, deleted)│
publish → team-database:1.2.0 in ECR  ─────┘
                                            │
              ┌── AUTOMATED ───────────────►│  bump-staging PR (auto-merged) bumps
              │   (no human)                │  runtimes/staging/Chart.yaml → hub ArgoCD
              │                             │  syncs 1.2.0 into the STAGING RUNTIME
              │                             │
              │   STAGING RUNTIME = the platform team's validation environment:
              │   the abstraction runs live + the platform-app E2E (Tier 3) proves a
              │   workload can CONSUME it end-to-end, BEFORE any prod exposure.
              │                             │
              └── CONTROLLED ──────────────►│  platform team copies the proven version
                  (deliberate, reviewed PR) │  into runtimes/prod/Chart.yaml (dev, uat, prod
                                            │  runtimes) → hub ArgoCD syncs → live for users
```

This is the literal multi-cluster translation of the HTML doc's model:
- **"Automated: Staging"** → the `bump-staging` job (in `capability-pipeline.yaml`) auto-PRs the version into the **staging runtime's** umbrella `Chart.yaml`. The staging runtime always holds the latest *tested* version of every capability — it is where the platform team (and the Tier-3 E2E) validate the abstraction **before** production.
- **"Controlled: Production"** → promotion to `runtimes/prod/Chart.yaml` is a **deliberate, reviewed, platform-team-only PR** — the release gate. "Any cluster with users = production for the platform team," so dev/uat/prod **runtimes** all promote through this gate.
- **"Rollback = version revert"** → revert the pin in `runtimes/<env>/Chart.yaml`; hub ArgoCD re-syncs the old RGD; kro reconciles. Git is the source of truth, per runtime.

### What this PoC must demonstrate (the actual deliverable)

The headline demo is **not** "a runtime came up." It is: **a capability team publishes `team-database:1.3.0` autonomously → it auto-lands in the staging runtime → the platform team promotes it, via one reviewed PR, to the production runtime → and can roll it back by reverting the pin** — all without the capability team touching production, and without the platform team touching capability code. That is the operating model the platform enforces.

### What changes vs. today (mechanics, mostly reuse)

- **REUSED unchanged:** `capability-pipeline.yaml` (Gate 1 in full), the version-from-PR-label publish, the umbrella-`Chart.yaml`-pinning model, ArgoCD-syncs-on-git-change, rollback-by-revert.
- **The one real change:** the `bump-staging` job today targets `platform-core/argocd/staging/Chart.yaml` (the single staging *cluster*). It must target the **staging runtime's** umbrella `Chart.yaml` in the new platform GitOps repo (`runtimes/staging/Chart.yaml`). Production promotion stays a manual platform-team PR into `runtimes/prod/Chart.yaml`. (Per §3/Phase 5: extend `bump-staging` to the runtime path, or document the manual runbook.)
- **CODEOWNERS** on the platform GitOps repo is the enforcement teeth: `runtimes/**` and `control-plane/**` are platform-team-owned; `apps/**` is developer-owned. A capability team's only write path to production is opening a PR a platform-team owner must approve — the gate is a branch-protection rule, not a convention.

### PoC scope note

The single account means staging and production runtimes are **co-located** — fine for demonstrating the *promotion gate mechanics*, but the PoC does **not** prove environment isolation (a prod-account boundary). The lifecycle/enforcement model is what's being validated here, not the isolation.

---

## 3. Phased Plan (Phase 1 cross-cluster proof is DONE)

### Phase 2 — Make the hub repeatable from code (no new capability yet)
**Goal:** A fresh `terraform apply` + one bootstrap command produces a working hub with no hand-stitching. This is the single biggest gap today (zero bootstrap glue exists; CI only runs `terraform validate`).

**Steps (all in `platform-control-plane/terraform/poc/`):**
1. **Move the out-of-band EKS IAM into Terraform.** Add an `aws_iam_role_policy` (or attach `AmazonEKSClusterPolicy`) on `aws_iam_role.ack` (`main.tf:241`) granting `eks:CreateCluster/DescribeCluster/DeleteCluster`, `eks:CreateCapability/DescribeCapability/DeleteCapability`, `eks:CreateAccessEntry/DescribeAccessEntry/DeleteAccessEntry`, plus `ec2:Describe*` for subnets/SGs. **Note:** `iam:PassRole` is already covered by the attached `AmazonIAMFullAccess` (`main.tf:273`) — do **not** chase it as missing; the genuinely-absent pieces are the `eks:*` actions + `AmazonEKSClusterPolicy`.
2. **Add `team-eks` to the ECR toset** (`main.tf:227-233`) so the new capability has a repo to publish to.
3. **DONE — deleted the dead `platform-capabilities.yaml` ApplicationSet** (not "migrated" as originally planned). It was never applied, used floating `1.*` (contradicts pin-everywhere), and duplicated the job already done correctly by the **pinned umbrella** `platform-core/argocd/staging/Chart.yaml` (deployed by the live `platform-environments` ApplicationSet, `platform-staging` Synced/Healthy, RGDs Active). Capability delivery is the pinned umbrella — there is no second capability path. Stale CLAUDE.md reference fixed.
4. **Write one bootstrap orchestrator** (`platform-control-plane/bootstrap.sh` or a `Makefile`): `terraform apply` → read outputs (`cluster_arn`, `ecr_registry`, subnet group names, topology annotations from `outputs.tf`) → `kubectl apply` the ArgoCD entrypoints. There are **two entrypoints** (the dead `platform-capabilities.yaml` was removed in step 3): `platform-core/argocd/applicationset.yaml` (`platform-environments` → the pinned `argocd/staging` umbrella = capabilities) and `platform-core/argocd/apps/applicationset.yaml` (the app layer). Both already use real values / annotation injection, so the orchestrator is mostly ordering + the cluster-Secret prerequisite, not value-rendering.
5. **Delete the duplicate Terraform root** `platform-core/terraform/poc/` (contradicts CLAUDE.md "platform-control-plane = control-plane Terraform only"). It still re-declares the same VPC/EKS/IAM roles/SSO literals (globally-unique-name collision hazard), even though its ECR block was already de-duplicated. If any of its resources are in a live state file, `terraform state rm` them from that root first.

**Reused:** all of `main.tf` (VPC/EKS/capability/vended-logs/ECR), `argocd-cluster.tf`, `outputs.tf`, `apps/applicationset.yaml` injection pattern.
**New:** the EKS IAM policy block, `bootstrap.sh`, `bootstrap.sh`.
**Exit check:** From a clean account (or after a clean destroy), `terraform apply && ./bootstrap.sh` brings up a hub whose `kubectl get applicationsets -n argocd` shows all three syncing, capability RGDs land in `platform-system`, and `kubectl get rgd` shows `database/cache/eventbus` Active.

### Phase 3 — Build `platform-capability-eks` (the Runtime RGD), hand-applied first
**Goal:** A `kind: Runtime` RGD that provisions a spoke and registers it, validated incrementally.

**Steps:**
1. **Clone the repo:** `cp -r platform-capability-pubsub platform-capability-eks`. It is the only repo with the full local harness.
2. **Hand-apply the raw ACK graph FIRST** (Phase 1 proved the raw CRs work). Given the ~4-15 min cluster-create feedback loop and "CEL errors only surface at tier1+", confirm `Cluster + Capability×3 (each with roleARN) + AccessEntry + Secret` by hand on the live hub before wrapping in CEL.
3. **Author `chart/templates/runtime-rgd.yaml`** (see §4). Compose from two existing RGDs: take `tenant-rgd.yaml`'s heterogeneous-resource skeleton (it already templates plain `Namespace`, `v1` `ResourceQuota`, `networking.k8s.io` kinds — proof kro emits arbitrary k8s kinds) for the spoke Secret + app-of-apps; take `eventbus-rgd.yaml`'s cross-resource CEL wiring (`eventbus-rgd.yaml:75,101-103` reference other resources' `status.ackResourceMetadata.arn`) for `Capability.clusterName → Cluster` and `Secret.server → Cluster ARN`.
4. **Rename five knobs:** `chart/Chart.yaml` name → `team-eks`; `Makefile:42` wait target → `runtime.kro.run`; `Makefile:26-29` `local-up` CRD URLs → `eks.services.k8s.aws` CRDs; caller `.github/workflows/pipeline.yaml` inputs → `capability-name: runtime`, `ack-controllers: eks,iam`, longer `assert-timeout` (≥20m); `tests/tier2/{instance,assertions,cleanup}`.

**Reused byte-for-byte:** `hack/versions.sh`, `hack/lint-rgd.sh`, `hack/local-tier2.sh` (Chainsaw phase generation), `fake-status-controller.yaml` RBAC + Job scaffold.
**New / cannot reuse byte-for-byte:** `hack/local-ack.sh` is SNS/SQS+ministack-specific (`for ctrl in sns sqs`, `--allow-unsafe-aws-endpoint-urls`) — there is **no ministack equivalent that provisions real EKS clusters**, so the local-emulator tier2 path does not apply; the `runtime-rgd.yaml` body; the EKS status-patch payloads in the fake-status controller.
**Exit check:** Hand-applied raw graph reaches a registered, hub-deployable spoke (re-confirms Phase 1 with `roleARN` on every Capability). Then `helm template` of the RGD applies clean.

### Phase 4 — Wire CI for `platform-capability-eks`
**Goal:** The capability publishes through the existing pipeline unchanged.

**Steps:**
1. **One edit to `platform-core/.github/actions/setup-platform-ci/action.yaml`:** add `ACK_EKS_CHART_VERSION=<pin>` (the version Phase 1 verified) next to the pins at lines 24-31, and append the `eks.services.k8s.aws` CRD apply lines to the fake-mode block (lines 56-67) so tier1 recognizes `Cluster/Capability/AccessEntry`. `ACK_IAM_CHART_VERSION=1.3.15` is already there (line 30) for the roleARN the Capability requires; the real-mode install loop (lines 73-89) is controller-agnostic, so `ack-controllers: eks,iam` just works.
2. **Do NOT touch `capability-pipeline.yaml`** — it is fully generic: `publish` derives `CHART_NAME` via `yq '.name'` (line 258), `bump-staging` bumps the matching dependency by name (line 305).
3. **Build the tier1 fake-status patcher for EKS** — read the pinned ACK EKS CRD schema and enumerate every `status` field the RGD's `readyWhen` gates reference (`Cluster.status` → `ACTIVE`, `Capability.status`, `AccessEntry`). Reuse the `fake-status-controller.yaml` ClusterRole + kubectl-loop scaffold verbatim; rewrite only the per-kind patch JSON. Wrong/incomplete payloads = tier1 hangs to its 90s timeout (`Makefile:42`).

**Reused:** `capability-pipeline.yaml` (0 edits), caller workflow shape, version-from-label/publish/bump flow.
**New:** EKS pin + CRD lines in the action; the EKS fake-status payloads.
**Exit check:** A PR to `platform-capability-eks` runs `lint→tier1` green; merge runs `real-infra-test` (creates a real spoke, asserts ACTIVE, deletes) and publishes `team-eks` to ECR.

### Phase 5 — Provision the first runtime via a `Runtime` CR and close the app loop
**Goal:** `kubectl apply` a `Runtime` CR on the hub → spoke comes up → hub deploys the platform layer → runtime's own ArgoCD deploys one `platform-app`.

**Steps:**
1. Create the **new "platform" GitOps repo** with `control-plane/<env>/`, `runtimes/<env>/`, `apps/<env>/<app>/`. **Partition by CODEOWNERS** so a developer app PR cannot touch control-plane/runtime config.
2. Apply `Runtime{environment: staging}` on the hub. Hub ACK creates the spoke; the RGD emits the spoke ArgoCD Secret + app-of-apps.
3. **Resolve the in-runtime injection mechanism** (decided in Phase 0/§7) and wire the runtime's own `apps/applicationset.yaml` (clone of `platform-core/argocd/apps/applicationset.yaml`, retargeted to the runtime's local cluster).
4. Pin all versions in `runtimes/staging/Chart.yaml` (production pattern — `argocd/production/Chart.yaml` is the model). The `bump-staging` job only auto-bumps **hub** `platform-core/argocd/staging/Chart.yaml`; runtime promotion is **manual** (matches "pin everywhere, no float"). Document or extend the bump job to target `runtimes/<env>/Chart.yaml` if auto-promotion is wanted.

**Reused:** `tenant-rgd.yaml` (per-namespace IngressClass/Quota/RBAC inside the spoke), `platform-app` chart, `apps/applicationset.yaml` injection pattern, umbrella `Chart.yaml` pinning.
**New:** the platform GitOps repo, runtime-side ApplicationSet retargeting, the injection-mechanism fix.
**Exit check:** `Runtime` CR ACTIVE; hub `kubectl get applications -n argocd` shows the spoke synced; on the spoke, capability RGDs Active + one `platform-app` reachable through its per-namespace ALB.

### Phase 6 — Fan out (only after Phase 5 closes)
Add stag+prod control planes and dev/prod runtimes by re-instantiating Terraform with a parameterized `var.environment` (see §6).

---

## 4. The `platform-capability-eks` Runtime RGD (sketch)

Schema follows the `tenant-rgd.yaml`/`eventbus-rgd.yaml` conventions (`type | default=`, status from `${resource.status...}`). Environment/topology come from **chart `values.yaml` defaults** injected into the schema `default=` at `helm template` time (the proven `pubsub` `defaults.clusterName` idiom; per-env overrides live in the pinned umbrella `argocd/staging/Chart.yaml`), so they are upgrade-safe (changing a default is safe) and not new required fields.

```yaml
apiVersion: kro.run/v1alpha1
kind: ResourceGraphDefinition
metadata:
  name: runtime.kro.run            # CI tier1 waits on this (capability-name: runtime)
spec:
  schema:
    apiVersion: v1alpha1
    kind: Runtime
    spec:
      name: string
      environment: string | default="staging"     # only developer-facing knob
      # platform-fixed, injected from chart values.yaml defaults (NOT user-set):
      # vpcId, subnetIds, k8sVersion, hubArgoCdRoleArn, runtimeCapabilityRoleArn,
      # ecrRegistry, accountId, region
    status:
      clusterArn:  ${cluster.status.ackResourceMetadata.arn}
      clusterName: ${cluster.spec.name}
      state:       ${cluster.status.status}        # surfaces ACTIVE

  resources:
    # (1) the runtime EKS cluster
    - id: cluster
      readyWhen:
        - ${cluster.status.status == "ACTIVE"}     # ~4-15 min — slow CEL loop
      template:
        apiVersion: eks.services.k8s.aws/v1alpha1
        kind: Cluster
        metadata: { name: ${schema.spec.name}, namespace: platform-system }
        spec:
          name: ${schema.spec.name}
          roleARN: ${schema.spec.runtimeCapabilityRoleArn}
          version: ${schema.spec.k8sVersion}
          resourcesVPCConfig:
            subnetIDs: ${schema.spec.subnetIds}
          tags:
            platform.io/capability: runtime
            platform.io/workload: ${schema.spec.name}
            platform.io/environment: ${schema.spec.environment}

    # (2) Capability x3 — kro / ack / argocd — each REQUIRES roleARN even for KRO
    #     (Phase-1 verified: first apply failed without it). clusterName points at
    #     the runtime cluster so they land ON the spoke, not the hub.
    - id: capKro
      readyWhen: [ '${capKro.status.status == "ACTIVE"}' ]
      template:
        apiVersion: eks.services.k8s.aws/v1alpha1
        kind: Capability
        metadata: { name: ${schema.spec.name}-kro, namespace: platform-system }
        spec:
          clusterName: ${cluster.spec.name}        # gated by cluster readyWhen
          name: platform-kro
          type: KRO
          roleARN: ${schema.spec.runtimeCapabilityRoleArn}
    - id: capAck      # same shape, type: ACK
    - id: capArgocd   # same shape, type: ARGOCD (+ argo_cd config like main.tf:143)

    # (3) AccessEntry — grants the HUB ArgoCD role access to the runtime
    - id: hubAccess
      readyWhen: [ '${has(hubAccess.status.ackResourceMetadata.arn)}' ]
      template:
        apiVersion: eks.services.k8s.aws/v1alpha1
        kind: AccessEntry
        metadata: { name: ${schema.spec.name}-hub-access, namespace: platform-system }
        spec:
          clusterName: ${cluster.spec.name}
          principalARN: ${schema.spec.hubArgoCdRoleArn}
          # + accessPolicies / kubernetesGroups as Phase-1 verified

    # (4) spoke registration Secret — direct CEL translation of argocd-cluster.tf.
    #     server MUST be the cluster ARN; carries platform.io/* topology annotations.
    - id: spokeSecret
      template:
        apiVersion: v1
        kind: Secret
        metadata:
          name: ${schema.spec.name}-cluster
          namespace: argocd                        # hub argocd ns
          labels:
            argocd.argoproj.io/secret-type: cluster
            env: ${schema.spec.environment}        # cluster-generator selector
          annotations:
            platform.io/account-id:   ${schema.spec.accountId}
            platform.io/region:       ${schema.spec.region}
            platform.io/cluster-name: ${cluster.spec.name}
            # ... ingress-* annotations as in argocd-cluster.tf:41-58
        stringData:
          name:   ${schema.spec.name}              # UNIQUE ARN-named — avoids the
          server: ${cluster.status.ackResourceMetadata.arn}   # in-cluster collision
          config: "..."

    # (5) app-of-apps — hub deploys platform layer into the spoke (capability RGDs
    #     + the runtime's own app ApplicationSet). Plain ArgoCD Application kind,
    #     same as tenant-rgd emits plain k8s kinds.
    - id: appOfApps
      template:
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        # destination.name = ${cluster.status.ackResourceMetadata.arn} (the spoke)
```

**Phase-1 learnings baked in:** every `Capability` carries `roleARN` (KRO included); `readyWhen` on `Cluster.status.status == "ACTIVE"` gates the Capabilities (a 4-min wait — keep the chain shallow, hand-apply before CEL-wrapping); **delete ordering** is handled by kro's dependency graph (Capabilities depend on `cluster` via `${cluster.spec.name}`, so kro tears them down before the Cluster — matching the finalizer rule that a Cluster won't delete until its Capabilities are gone).

**Composition note (de-risk):** consider splitting cluster+capabilities (slow) from spoke-registration+app-of-apps (fast) into two graphs behind a thin `kind: Runtime` façade, so a CEL/reference bug in registration doesn't block the 4-15 min cluster create and each half has an independently-testable tier1.

---

## 5. How existing code is reused

| Asset | Reuse |
|---|---|
| `platform-capability-pubsub/` (Makefile + `hack/{versions,lint-rgd,local-tier2}.sh`) | `cp -r` to `platform-capability-eks`; rename 5 knobs. `versions.sh`/`lint-rgd.sh`/`local-tier2.sh` reused as-is. **`local-ack.sh` is NOT reusable** (SNS/SQS+ministack-specific; no EKS emulator). |
| `capability-pipeline.yaml` | **0 edits.** Generic inputs; derives chart name via `yq`; publish/tag/bump flow works for `team-eks`. |
| `tenant-rgd.yaml` | Structural model for the Runtime RGD's heterogeneous graph (plain Namespace/Secret/Application kinds). Also reused **inside each spoke** for per-namespace IngressClass+IngressClassParams (ALB grouping — `tenant-rgd.yaml:47-83`), ResourceQuota, RBAC, NetworkPolicy. |
| `eventbus-rgd.yaml` | Model for cross-resource CEL wiring (`:75,:101-103`) and Secret generation with `platform.io/*` labels (`:105-118`). |
| `argocd-cluster.tf` | Direct CEL translation into the Runtime RGD's spoke Secret (same `name=in-cluster`-style, `server=ARN`, `env` label, `platform.io/*` annotations). |
| `platform-core/argocd/apps/applicationset.yaml` | Clone + retarget for the runtime-side app delivery (goTemplate matrix git×clusters, `helm.parameters` topology injection). Keep `goTemplate: true` semantics (`{{index .metadata.annotations "..."}}`). |
| `argocd/{staging,production}/Chart.yaml` | Umbrella pinning model; runtimes follow the **production** (pinned, manual) pattern. |
| per-namespace IngressClass (`tenant-rgd.yaml` + `platform-ingress/`) | Reused inside each spoke for one-ALB-per-namespace (annotation `group.name` is ignored on Auto Mode — must live in IngressClassParams; verified). |

---

## 6. Repeatability — tear down + recreate deterministically

1. **Move out-of-band EKS IAM into Terraform** (Phase 2 step 1). Until then a fresh apply yields a hub that physically cannot create a runtime — the headline demo is non-reproducible from code.
2. **Bootstrap orchestrator** (Phase 2 step 4) — the only thing turning "TF outputs" into "applied ArgoCD manifests". Today there is zero glue.
3. **Parameterize the environment dimension.** `var.environment` exists (`variables.tf:36`) but is used **only** as the ArgoCD Secret `env` label (`argocd-cluster.tf:37`) — never in resource names. Two control planes in one account collide on globally-unique names (IAM roles `plat-cp-capability-*`, subnet groups `plat-cp-db-subnets`, cluster `plat-cp-cluster`). Build composite names (`plat-cp-${var.environment}-*`) for VPC/cluster/IAM roles/subnet groups before claiming two control planes.
4. **Make hardcoded IDs variables:** SSO instance ARN (`main.tf:147`) + SSO identity (`main.tf:152`) are literals with no indirection — make them no-default variables; `admin_role_arn` is already required.
5. **RETAIN cleanup contract.** All three capabilities and the planned runtime Cluster CRs set `delete_propagation_policy=RETAIN` (`main.tf:121,131,141`). `terraform destroy` leaves them behind; a re-apply then hits pre-existing globally-named survivors. **Pair RETAIN with a documented reset runbook** (or a `make destroy-hard` that flips propagation to DELETE, gated behind explicit confirmation per the production-safety rule) plus an import/ignore path for survivors. The current live state was reached by hand-import (`argocd-cluster.tf:18-20`, the `state rm` note) — codify that so it's reproducible.
6. **Local Terraform state** is acceptable for a single PoC operator but combined with RETAIN means a lost state file orphans the retained resources. Document as a known non-repeatable edge; move to S3+locking before fan-out.

---

## 7. In-runtime topology injection — DECIDED & VALIDATED (was the biggest risk)

**The risk:** inside each runtime, app delivery is the single-cluster local case, where the managed-ArgoCD `in-cluster` collision recurs — the clusters generator is unusable for the local cluster because the ARN-named `in-cluster` Secret + ArgoCD's implicit `in-cluster` row produce a duplicate-name error (verified earlier; renaming `data.name` broke `platform-staging` — `platform-app-ingress-design.md:16`). If unsolved, a runtime's own app ApplicationSet can't read its own topology and `platform-app` breaks.

**DECISION: Two-secret split (Option A).** Separate the *deploy target* from the *topology source*:
- Keep the `in-cluster`-named cluster Secret as the deploy destination (unchanged — existing destinations keep working).
- Add a **second, uniquely-named** cluster Secret (e.g. `<cluster>-topology`, `data.name` ≠ `in-cluster`) carrying the `platform.io/*` annotations, labeled `platform.io/topology: "true"`.
- The runtime's app ApplicationSet uses a **clusters generator selecting on `platform.io/topology: "true"`** (reads annotations from the topology secret only — one row, no collision) and sets `destination.name: in-cluster` (deploys to the local cluster). `helm.parameters` inject the annotations, overriding chart defaults.

**VALIDATED LIVE (on `plat-cp-cluster`, the single-cluster local case = exactly what each runtime faces):** added `plat-cp-topology` alongside `local-cluster`; the generator selected it cleanly ("All applications generated successfully", no duplicate); the `platform.io/*` annotations were injected into the generated Application (`account-id`, `ingress-domain`); the app still resolved `destination.name: in-cluster`; and **`platform-staging` stayed Synced/Healthy** (no regression). Test artifacts cleaned up.

**Implication for the Runtime RGD (§4):** the `Runtime` graph emits BOTH cluster Secrets per spoke — the `in-cluster` registration AND the `<cluster>-topology` secret (annotations). The runtime's `apps/applicationset.yaml` (clone of `platform-core/argocd/apps/applicationset.yaml`) selects the topology secret by label. This is no longer a gate — it is a known, proven pattern to implement.

### Remaining biggest risk (now that injection is settled)
**Cross-resource CEL on the Runtime RGD's slow graph.** The graph wires `Capability.clusterName`/`AccessEntry`/Secret to a `Cluster` that takes ~4 min to go ACTIVE, with `readyWhen` gates and `roleARN` on every Capability. CEL errors only surface at tier1+, and the feedback loop is minutes-long. **De-risk: hand-apply the raw ACK graph first (Phase 3 step 2 — Phase 1 already proved the raw CRs), then wrap in CEL incrementally**, keeping the dependency chain shallow.

---

## 8. PoC shortcuts acceptable now — MUST harden for real

| Shortcut (OK for PoC) | Why OK now | Harden before prod |
|---|---|---|
| **Single AWS account** (CPs, runtimes, envs co-located) | Just to see the loop work | The PoC will **not** exercise cross-account `AccessEntry`, cross-account ECR pull, or account-boundary isolation — the things most likely to break in a real multi-env rollout. Flag as **non-representative**; plan a follow-on slice with an account boundary between prod and non-prod. |
| **Single shared VPC, fixed `10.0.0.0/16`, single NAT** (`main.tf:41,48`) | Cost | Per-runtime VPC (or at least per-env) — today all runtimes share fate (one NAT, one CIDR, no network isolation). |
| **Broad ACK IAM** — `RDS/ElastiCache/SNS/SQS FullAccess` + `IAMFullAccess` + `SecretsManagerReadWrite` (`main.tf:253-281`), plus the new broad `eks:*` | Fast | Scope to least-privilege: constrain `iam:PassRole` to a role-path/tag, `eks:*` to the runtime cluster-name pattern, replace `IAMFullAccess`/`SecretsManagerReadWrite` with inline policies conditioned on the `platform.io/*` tags the resources already carry. `IAMFullAccess`+broad `eks:*` in a shared prod+dev account is a real escalation primitive. |
| **App-delivery injection mechanism deferred** | Decided at PoC start (§7) | The chosen mechanism (two-secret vs controller) must be the supported, documented golden path, not a one-off. |
| **`platform-app` topology defaults hardcoded** — `clusterName: plat-cp-cluster`, `accountId: "279051970617"`, `region: us-east-1` (`values.yaml:11-13`) | Injection path overrides them | Any render path that bypasses the injecting ApplicationSet (local `helm template`, tier tests, a not-yet-wired runtime) silently targets the original PoC account → wrong-cluster PodIdentityAssociations. Remove the defaults or fail-closed once every delivery path injects. (`platform.ingress.*` is already empty/injected — not a leak.) |
| **Local Terraform state** | Single operator | S3 + locking before fan-out (§6.6). |
| **Pin-everywhere with manual runtime promotion** | Safe | Add per-runtime bump automation (extend `bump-staging` to target `runtimes/<env>/Chart.yaml`) or document the manual runbook — 3+ runtimes otherwise = a hand-edited promotion matrix. |

**Cleanup also worth doing:** remove the dead `kro.run/workloads` verbs from the tenant RGD `workload-manager` Role (`tenant-rgd.yaml:116-118`) — there is no Workload RGD — and refresh CLAUDE.md for multi-cluster + ingress (it self-admits staleness).

---

**Key files to touch (all absolute):**
- `/Users/guilhg/Library/CloudStorage/WorkDocsDrive-Documents/Documents/Bradesco/tech-products/platform-control-plane/terraform/poc/main.tf` (EKS IAM, ECR toset, parameterize names, SSO vars)
- ~~`platform-control-plane/argocd/applicationsets/platform-capabilities.yaml`~~ — **DELETED** (dead/redundant; capabilities use the pinned `argocd/staging` umbrella)
- `/Users/guilhg/Library/CloudStorage/WorkDocsDrive-Documents/Documents/Bradesco/tech-products/platform-core/.github/actions/setup-platform-ci/action.yaml` (add `ACK_EKS_CHART_VERSION` + EKS CRD lines)
- New repo `platform-capability-eks/` cloned from `/Users/guilhg/Library/CloudStorage/WorkDocsDrive-Documents/Documents/Bradesco/tech-products/platform-capability-pubsub/`
- New `platform-control-plane/bootstrap.sh`; new "platform" GitOps repo
- Delete `/Users/guilhg/Library/CloudStorage/WorkDocsDrive-Documents/Documents/Bradesco/tech-products/platform-core/terraform/poc/`
---

