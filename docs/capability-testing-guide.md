# Capability Testing Guide

## Testing Pyramid

```
                    /\
                   /  \    Platform E2E (platform team, pre-release)
                  /    \    → Full workload + all capabilities + upgrade scenario
                 /______\    → Runs: before production promotion (release train)
                /        \
               / TIER 2:  \   Real AWS (capability team, on merge to main)
              / Chainsaw +  \   → k3d + real ACK controllers + OIDC → real AWS
             / Real ACK      \   → Provisions real resource, verifies, deletes
            /________________\   → Runs: on merge to main (~15-20 min)
           /                  \
          /  TIER 1: Fast      \  RGD Logic (capability team, on every PR)
         / k3d + kro + CRDs    \  → Validates RGD compiles and activates
        /________________________\  → Runs: on every PR push (~2 min)
       /                          \
      /  LINT: Helm validation     \  Chart syntax (always)
     / helm lint + helm template    \  → Validates YAML is correct
    /________________________________\  → Runs: always (~30 sec)
```

## What Each Layer Tests (In Practice)

### LINT — "Is my YAML valid?"

| What it does | What it catches | Example failure |
|---|---|---|
| `helm lint chart/` | Chart structure errors, missing Chart.yaml fields | `Chart.yaml: version is required` |
| `helm template test chart/` | Broken Go template syntax, bad variable references | `template: database-rgd.yaml:15: unexpected "}" in command` |

**Does NOT catch**: kro CEL errors, wrong ACK field names, invalid defaults.

### TIER 1 — "Will kro accept my RGD?"

| What it does | What it catches | Example failure |
|---|---|---|
| Deploys RGD to k3d cluster with kro | CEL syntax errors, wrong field references | `failed to build resource: error getting field schema for path spec.parameters: schema not found` |
| Checks RGD state == Active | CRD generation failures, incompatible schema changes | `RGD state: Inactive` |

**In practice**: A developer changes a CEL expression from `${schema.spec.size == "small" ? "db.t4g.micro" : "db.r6g.large"}` and makes a typo. kro can't compile it → RGD stays Inactive → Tier 1 fails in 2 minutes → developer fixes before merge.

**Does NOT catch**: Whether AWS actually accepts the spec (wrong instance class, invalid engine version).

### TIER 2 — "Does my abstraction work with real AWS?"

| What it does | What it catches | Example failure |
|---|---|---|
| Installs real ACK controller with OIDC credentials | Controller startup issues | `ACK controller CrashLoopBackOff` |
| Deploys previous RGD version (upgrade test) | — | — |
| Creates a real AWS resource via Chainsaw | Invalid AWS specs, wrong subnet, bad engine version | `ACK.Terminal: InvalidParameterCombination: Cannot find version 99.0 for postgres` |
| Waits for resource available (Chainsaw assert) | Provisioning failures, timeout issues | `assert timeout: dbInstanceStatus != available after 15m` |
| Verifies tags on real resource | Missing tags that IAM policy depends on | `assert failed: tags missing platform.io/workload` |
| Verifies defaults applied correctly | Wrong CEL mapping (size→instanceClass) | `assert failed: dbInstanceClass expected db.t4g.micro, got db.t4g.medium` |
| Verifies connection Secret created | kro didn't create Secret, wrong keys | `assert failed: Secret ci-real-test-db-conn not found` |
| Upgrades RGD and re-verifies | Breaking changes, lost fields after upgrade | `assert failed: tags disappeared after upgrade` |
| Deletes resource and verifies cleanup | Orphaned AWS resources, finalizer stuck | `error assert timeout: DBInstance still exists after 5m` |

**In practice**: A developer changes the default `engineVersion` from `"16.14"` to `"99.0"`. Tier 1 passes (kro doesn't validate AWS values). Tier 2 creates the real RDS instance → ACK returns `InvalidParameterCombination` → Chainsaw assertion fails → chart never reaches ECR.

### VERIFY-STAGING — "Did ArgoCD deploy it successfully? Are existing instances OK?"

| What it does | What it catches | Example failure |
|---|---|---|
| Waits for ArgoCD to sync the new chart | ECR pull errors, ArgoCD config issues | `ArgoCD sync timeout after 6 minutes` |
| Checks RGD Active in staging | Breaking CRD changes that kro rejects on update | `RGD state: Inactive in staging` |
| Checks existing instances not ERROR | Upgrade broke running workloads | `Instance orders-db state: ERROR` |

**In practice**: The team's chart published to ECR. ArgoCD syncs it to staging. There are 5 real Database instances running in staging. The verify-staging step confirms none of them went ERROR after the new RGD was applied.

### PLATFORM E2E — "Does the full developer experience work?"

| What it does | What it catches | Example failure |
|---|---|---|
| Deploys ALL capability RGDs together | Cross-capability conflicts | `RGD eventbus.kro.run not Active (depends on missing CRD)` |
| Deploys a full workload (Helm chart with database + cache + events) | Helm chart incompatible with new RGD schema | `Database CR rejected: unknown field readReplicas` |
| Verifies pods running with correct env vars | Connection Secret wiring broken | `Pod CreateContainerConfigError: secret db-conn not found` |
| Verifies IAM policy correct | Tag-based policy doesn't match | `Pod can't access RDS: AccessDenied` |
| Upgrades a capability RGD, verifies workload survives | Upgrade breaks the developer's app | `Pod restarted, DATABASE_HOST empty` |

**In practice**: The platform team runs this before promoting staging → production. It proves: "a developer's app with all three capabilities still works after all the capability teams' recent changes."

---

## Pipeline Structure

### Governed vs Capability Team

The pipeline has two layers:

| Layer | Owned by | Lives in | Can capability team modify? |
|-------|----------|----------|---------------------------|
| **Reusable Workflow** | Platform team | `platform-core/.github/workflows/capability-pipeline.yaml` | No |
| **Shared Action** | Platform team | `platform-core/.github/actions/setup-platform-ci/action.yaml` | No |
| **Caller Workflow** | Capability team | `platform-capability-*/.github/workflows/pipeline.yaml` | Only inputs (name, controllers, timeouts) |
| **Test Data** | Capability team | `platform-capability-*/tests/tier2/` | Yes (instance, assertions, cleanup) |
| **Chart (RGD)** | Capability team | `platform-capability-*/chart/` | Yes |

### What the Platform Team Controls

- Pipeline logic (lint → tier1 → tier2 → publish → verify-staging)
- Chainsaw test structure (generated at runtime, not in team's repo)
- Tool versions (kro, ACK, k3d, Chainsaw — pinned in shared action)
- Timeouts enforcement
- Upgrade path testing logic
- Cleanup safety net

### What the Capability Team Controls

- Their RGD (the Helm chart)
- Test instance (`tests/tier2/instance.yaml`)
- Assertions (`tests/tier2/assertions/*.yaml`)
- Cleanup definition (`tests/tier2/cleanup.yaml`)
- Timeout values (passed as inputs to the reusable workflow)
- Which ACK controllers they need

## Pipeline Flow

```
┌─────────────────────────────────────────────────────────────────┐
│  PR (every push)                                               │
│                                                                 │
│  lint → tier1                                                  │
│                                                                 │
│  lint:                                                         │
│    helm lint chart/                                            │
│    helm template test chart/ > /dev/null                       │
│                                                                 │
│  tier1 (k3d + kro + ACK CRDs only):                           │
│    Deploy RGD                                                  │
│    Verify RGD is Active (kro compiled CEL successfully)        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  MERGE TO MAIN                                                 │
│                                                                 │
│  lint → tier1 → real-infra-test → publish → verify-staging    │
│                                                                 │
│  real-infra-test (k3d + real ACK + OIDC + Chainsaw):          │
│                                                                 │
│    Phase 1: Provision                                          │
│    ├── Deploy previous RGD from ECR (or current if first time)│
│    ├── Chainsaw: apply instance.yaml                          │
│    └── Chainsaw: assert assertions/available.yaml (wait 15m)  │
│                                                                 │
│    Phase 2: Upgrade (if previous version existed)              │
│    ├── Apply NEW RGD (from current branch)                    │
│    └── kro reconciles existing instance with new spec         │
│                                                                 │
│    Phase 3: Assertions + Cleanup                               │
│    ├── Chainsaw: assert assertions/*.yaml (all files)         │
│    ├── Chainsaw: delete cleanup.yaml                          │
│    └── Chainsaw: error assertions/available.yaml (verify gone)│
│                                                                 │
│  publish:                                                      │
│    helm push to ECR                                           │
│                                                                 │
│  verify-staging:                                               │
│    Connect to real EKS cluster                                │
│    Wait for ArgoCD to sync                                    │
│    Verify RGD Active in staging                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## How to Add Tests (for Capability Teams)

### Required Files

```
tests/tier2/
├── instance.yaml        ← The CR to create (your capability kind)
├── assertions/          ← What to verify on the provisioned resource
│   ├── available.yaml   ← REQUIRED: proves the resource is ready
│   ├── tags.yaml        ← Verifies platform tags are set
│   ├── secret.yaml      ← Verifies connection Secret exists
│   └── (custom).yaml   ← Add any additional assertions
└── cleanup.yaml         ← The CR to delete (same as instance.yaml)
```

### Example: Database Team

**`instance.yaml`** — what to create:
```yaml
apiVersion: kro.run/v1alpha1
kind: Database
metadata:
  name: ci-real-test-db
  namespace: default
spec:
  name: ci-real-test
  namespace: default
  size: small
```

**`assertions/available.yaml`** — proves resource provisioned:
```yaml
apiVersion: rds.services.k8s.aws/v1alpha1
kind: DBInstance
metadata:
  name: ci-real-test-db
  namespace: default
status:
  dbInstanceStatus: available
```

**`assertions/tags.yaml`** — proves tags are correct:
```yaml
apiVersion: rds.services.k8s.aws/v1alpha1
kind: DBInstance
metadata:
  name: ci-real-test-db
  namespace: default
spec:
  tags:
    - key: platform.io/capability
      value: database
    - key: platform.io/workload
      value: ci-real-test
```

**`assertions/defaults.yaml`** — proves CEL/defaults work:
```yaml
apiVersion: rds.services.k8s.aws/v1alpha1
kind: DBInstance
metadata:
  name: ci-real-test-db
  namespace: default
spec:
  engine: postgres
  dbInstanceClass: db.t4g.micro
  storageType: gp3
  publiclyAccessible: false
```

**`assertions/secret.yaml`** — proves connection Secret created:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ci-real-test-db-conn
  namespace: default
```

**`cleanup.yaml`** — what to delete:
```yaml
apiVersion: kro.run/v1alpha1
kind: Database
metadata:
  name: ci-real-test-db
  namespace: default
```

### How Assertions Work (Chainsaw)

- Assertions use **partial matching** — only the fields you specify are checked
- Chainsaw **retries automatically** until the assertion becomes true or timeout expires
- You don't need sleep/wait logic — just declare the desired state
- `assertions/available.yaml` is special: it's used for both "wait until ready" AND "verify deletion"

### Adding Custom Assertions

Just add a new YAML file in `assertions/`:

```yaml
# assertions/encryption.yaml
apiVersion: rds.services.k8s.aws/v1alpha1
kind: DBInstance
metadata:
  name: ci-real-test-db
  namespace: default
spec:
  storageEncrypted: true
```

The pipeline discovers it automatically — no workflow changes needed.

## Caller Workflow (what capability teams write)

```yaml
# .github/workflows/pipeline.yaml (the ONLY pipeline file in your repo)
name: Database Capability Pipeline
on:
  push:
    branches: [main]
    paths: ['chart/**', 'tests/**']
  pull_request:
    paths: ['chart/**', 'tests/**']

permissions:
  id-token: write
  contents: read

jobs:
  pipeline:
    uses: guilhermegreco/platform-core/.github/workflows/capability-pipeline.yaml@main
    with:
      chart-path: chart
      tests-path: tests/tier2
      capability-name: database
      ack-controllers: rds
      assert-timeout: "15m"
      delete-timeout: "5m"
    secrets: inherit
```

### Available Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `chart-path` | yes | `chart` | Path to the Helm chart |
| `tests-path` | yes | `tests/tier2` | Path to test data files |
| `capability-name` | yes | — | Name of the capability (database, cache, pubsub) |
| `ack-controllers` | yes | `rds` | Comma-separated ACK controllers to install |
| `assert-timeout` | no | `15m` | How long to wait for resource to be available |
| `delete-timeout` | no | `5m` | How long to wait for deletion to complete |

### ACK Controllers Available

| Controller | For |
|-----------|-----|
| `rds` | Database (RDS) |
| `elasticache` | Cache (ElastiCache) |
| `sns` | Events (SNS Topics) |
| `sqs` | Events (SQS Queues) |

## Onboarding a New Capability

1. Create repo `platform-capability-{name}`
2. Add `chart/` with your RGD Helm chart
3. Create `tests/tier2/` with instance + assertions + cleanup
4. Add the caller workflow (copy template above, change inputs)
5. Set repo variables: `ECR_PUSH_ROLE`, `ECR_REGISTRY`, `PROJECT`
6. Push — pipeline runs automatically

## Upgrade Testing

The pipeline automatically tests upgrades:

- **First time** (nothing in ECR): deploys current RGD, provisions resource, asserts
- **Subsequent runs**: deploys PREVIOUS version from ECR, provisions resource, then applies NEW version on top, and asserts on the upgraded state

This proves your RGD change doesn't break existing instances. No extra configuration needed.
