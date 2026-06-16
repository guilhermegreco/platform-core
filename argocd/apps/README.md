# App delivery (platform-apps ApplicationSet)

The **consumer side** of the platform: deploys developer applications via the
`platform-app` chart (pulled from ECR), the counterpart to `argocd/applicationset.yaml`
(which deploys the capability RGDs).

## How it works

`applicationset.yaml` is a matrix of **(git files) × (clusters)**:

- **git** discovers each app's `values.yaml` under `argocd/apps/<env>/<app>/`.
- **clusters** selects the registered cluster by its `env` label and exposes the
  `platform.io/*` topology annotations (stamped onto the cluster Secret by
  `platform-control-plane` terraform) as template variables.

Each match becomes a multi-source Argo CD Application:

1. **source 1** (`ref: values`) — this Git repo, supplying the developer values file.
2. **source 2** — the `platform-app` chart from ECR (`oci://<acct>.dkr.ecr.<region>.amazonaws.com/plat-cp/charts`, `targetRevision: "1.*"`), with:
   - `valueFiles: [$values/argocd/apps/<env>/<app>/values.yaml]` — developer intent
   - `helm.parameters` — platform topology injected from the cluster annotations

`helm.parameters` take precedence over the values file, so **developers cannot
override platform-owned keys** (accountId/region/clusterName/platform.ingress.*).

## Adding an app (developer contract)

Create `argocd/apps/staging/<app>/values.yaml` with **intent only**:

```yaml
name: <app>
team: <team>
image: <image>
port: 8080
replicas: 2
route:
  enabled: true        # exposes <app> at <namespace>.<domain>/<app>
database: { enabled: false }
cache:    { enabled: false }
events:   { enabled: false }
```

Do **not** set `accountId`, `region`, `clusterName`, or `platform.ingress.*` —
those are injected. The app deploys into a namespace named after the directory.

> Prefix-awareness: the app is served under `/<name>` and the Auto Mode managed ALB
> does not rewrite the path — configure your framework's base path accordingly.
> See charts/platform-app/values.yaml.

## Prerequisites

- The `platform-control-plane` terraform must have stamped the topology annotations
  onto the ArgoCD cluster Secret (labels `argocd.argoproj.io/secret-type=cluster` +
  `env=<env>`, annotations `platform.io/*`).
- The `platform-app` chart must be published to ECR (done by its CI pipeline).
