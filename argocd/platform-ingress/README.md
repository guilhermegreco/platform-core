# Platform Ingress (shared ALB, EKS Auto Mode)

Cluster-scoped, **platform-owned** wiring for the developer-facing ingress pattern. Applied
**once per cluster** by the platform team — developers never touch these.

## The pattern

**One FQDN per namespace, routed by path to the microservices in that namespace, on one shared ALB.**

```
team-shop-prod.<domain>/orders     -> orders Service     (ns: team-shop-prod)
team-shop-prod.<domain>/payments   -> payments Service   (ns: team-shop-prod)
team-blog-prod.<domain>/posts      -> posts Service      (ns: team-blog-prod)
```

- **Namespace = application/tenant boundary → owns the FQDN** (`<namespace>.<domain>`).
- **Path = microservice within the namespace** (`/<name>`, defaults from the release name).
- All `platform-app` releases in a namespace **merge onto one ALB** via an IngressGroup
  (`group.name = <groupPrefix>-<namespace>`), so the developer never coordinates with peers.

## What's here

| File | Resource | Role |
|------|----------|------|
| `staging/ingressclass.yaml`, `production/ingressclass.yaml` | `IngressClass` `platform-alb` + `IngressClassParams` `platform-alb-params` | Binds the class to Auto Mode's managed ALB controller (`eks.amazonaws.com/alb`) and sets the LB scheme. The chart references `ingressClassName: platform-alb`. |

Apply once per cluster, e.g.:

```bash
kubectl apply -f argocd/platform-ingress/staging/ingressclass.yaml
```

## Developer contract (consumed via the `platform-app` chart)

Developers only set intent:

```yaml
route:
  enabled: true
  path: ""          # defaults to "/<name>"
```

The platform injects topology (per environment, e.g. via the ApplicationSet / per-env values):

```yaml
platform:
  ingress:
    domain: apps.staging.example.com   # FQDN = <namespace>.<domain>
    groupPrefix: platform              # one shared ALB per namespace, per env
    scheme: internal
    className: platform-alb
```

## ⚠️ Prefix-awareness is mandatory (no edge rewrite)

EKS Auto Mode's managed ALB **silently drops** the `transforms` (path-rewrite) annotation
(verified empirically). The `/<name>` prefix is **not** stripped — your service receives
`/<name>/...`. Each microservice MUST serve under its base path (Spring `context-path`,
Express `app.use(prefix)`, FastAPI `root_path`, Next.js `basePath`, Django `FORCE_SCRIPT_NAME`),
including probe paths, redirects, cookie scope, and static assets.

## Limits & sharding

- ~**100 rules / 100 target groups per ALB** → ~99 microservices per shared ALB (≈1 rule each).
- Shard (new IngressGroup → new ALB) before ~70 rules, or immediately for a differing
  `scheme` / WAF / non-wildcard cert. `groupPrefix` is per-environment so staging and
  production never share an ALB.

## TLS (deferred)

These manifests are HTTP today. The wildcard-cert (`*.<domain>`) HTTPS listener
(`certificate-arn` + `listen-ports` on `IngressClassParams`) is a planned follow-up.
