{{/*
Per-cluster-qualified AWS IAM names for the app's workload role + policy.

WHY: IAM is account-global, not cluster-scoped. The app's role/policy were named
`<name>-role` / `<name>-workload-policy` off the app name alone, so two runtimes (hub +
any spoke, or two spokes) each running an app with the same `.Values.name` resolve to the
SAME account-global IAM role. Combined with `adopt-or-create`, the second runtime silently
ADOPTS the first's role instead of getting its own — a cross-runtime privilege-bleed /
collision. Qualifying the AWS name by `clusterName` (injected per-cluster from each cluster
Secret's platform.io/cluster-name annotation by the platform-apps ApplicationSet) makes each
runtime's role/policy distinct.

SCOPE: only the AWS `spec.name` + the ARNs built from it are qualified. The Kubernetes
`metadata.name` stays `<name>-role`/`-workload-policy` — a CR name is already unique per
cluster (separate API servers), and keeping it stable avoids churn on the CR object itself.

LENGTH: IAM role names cap at 64 chars. `platform-app.iamStem` keeps the natural
`<clusterName>-<name>` when it fits (stem <= 45, so stem + "-workload-policy" (16) <= 61 and
stem + "-role" (5) <= 50), else falls back to `<name truncated>-<8-char hash of the full
stem>` — deterministic and unique, still under the cap.
*/}}
{{- define "platform-app.iamStem" -}}
{{- $stem := printf "%s-%s" .Values.clusterName .Values.name -}}
{{- if le (len $stem) 45 -}}
{{- $stem -}}
{{- else -}}
{{- $hash := $stem | sha256sum | trunc 8 -}}
{{- printf "%s-%s" (.Values.name | trunc 36 | trimSuffix "-") $hash -}}
{{- end -}}
{{- end -}}

{{/* AWS IAM role name for the workload (account-global, cluster-qualified). */}}
{{- define "platform-app.roleName" -}}
{{- printf "%s-role" (include "platform-app.iamStem" .) -}}
{{- end -}}

{{/* AWS IAM policy name for the workload (account-global, cluster-qualified). */}}
{{- define "platform-app.policyName" -}}
{{- printf "%s-workload-policy" (include "platform-app.iamStem" .) -}}
{{- end -}}
