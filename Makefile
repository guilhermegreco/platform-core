# Platform Control Plane - Operations

REGISTRY ?= $(shell terraform -chdir=terraform/poc output -raw ecr_registry)
PROJECT ?= platform-control-plane

## --- Platform Team Commands ---

.PHONY: publish-database publish-cache publish-pubsub publish-workload
publish-database: ## Publish database team chart to ECR
	helm package charts/team-database
	helm push team-database-$$(yq '.version' charts/team-database/Chart.yaml).tgz oci://$(REGISTRY)/$(PROJECT)/charts

publish-cache: ## Publish cache team chart to ECR
	helm package charts/team-cache
	helm push team-cache-$$(yq '.version' charts/team-cache/Chart.yaml).tgz oci://$(REGISTRY)/$(PROJECT)/charts

publish-pubsub: ## Publish pub/sub team chart to ECR
	helm package charts/team-pubsub
	helm push team-pubsub-$$(yq '.version' charts/team-pubsub/Chart.yaml).tgz oci://$(REGISTRY)/$(PROJECT)/charts

publish-workload: ## Publish workload DSL chart to ECR
	helm package charts/application-rgd
	helm push application-rgd-$$(yq '.version' charts/application-rgd/Chart.yaml).tgz oci://$(REGISTRY)/$(PROJECT)/charts

.PHONY: publish-all
publish-all: publish-database publish-cache publish-pubsub publish-workload ## Publish all charts

## --- Inspection Commands ---

.PHONY: status
status: ## Show all RGDs and their state
	@echo "=== ResourceGraphDefinitions ==="
	@kubectl get resourcegraphdefinitions
	@echo ""
	@echo "=== Instances by Type ==="
	@echo "Databases:"; kubectl get databases -A --no-headers 2>/dev/null | wc -l | xargs echo " "
	@echo "Caches:"; kubectl get caches -A --no-headers 2>/dev/null | wc -l | xargs echo " "
	@echo "EventBuses:"; kubectl get eventbuses -A --no-headers 2>/dev/null | wc -l | xargs echo " "
	@echo "Workloads:"; kubectl get workloads -A --no-headers 2>/dev/null | wc -l | xargs echo " "

.PHONY: status-database
status-database: ## Show all Database instances (DB team view)
	@echo "=== Database Product ==="
	@kubectl get databases -A -o custom-columns=\
	'NAMESPACE:.metadata.namespace,NAME:.metadata.name,ENGINE:.spec.engine,VERSION:.spec.engineVersion,SIZE:.spec.size,HA:.spec.highAvailability,STATUS:.status.status'

.PHONY: status-cache
status-cache: ## Show all Cache instances (Cache team view)
	@echo "=== Cache Product ==="
	@kubectl get caches -A -o custom-columns=\
	'NAMESPACE:.metadata.namespace,NAME:.metadata.name,ENGINE:.spec.engine,VERSION:.spec.engineVersion,SIZE:.spec.size,STATUS:.status.status'

.PHONY: status-pubsub
status-pubsub: ## Show all EventBus instances (Pub/Sub team view)
	@echo "=== EventBus Product ==="
	@kubectl get eventbuses -A -o custom-columns=\
	'NAMESPACE:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,DLQ:.spec.dlq,TOPIC_ARN:.status.topicArn'

.PHONY: status-workloads
status-workloads: ## Show all Workloads (developer view)
	@kubectl get workloads -A

.PHONY: versions
versions: ## Show chart versions deployed vs available in ECR
	@echo "=== Deployed RGD Versions (from ArgoCD) ==="
	@kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,REVISION:.status.sync.revision,STATUS:.status.sync.status' 2>/dev/null || echo "ArgoCD not accessible"

## --- Testing Commands ---

.PHONY: test-database test-cache test-pubsub
test-database: ## Run Chainsaw tests for database RGD
	chainsaw test charts/team-database/tests/

test-cache: ## Run Chainsaw tests for cache RGD
	chainsaw test charts/team-cache/tests/

test-pubsub: ## Run Chainsaw tests for pub/sub RGD
	chainsaw test charts/team-pubsub/tests/

## --- Tenant Management ---

.PHONY: onboard-team
onboard-team: ## Onboard a new team (usage: make onboard-team TEAM=commerce ENVS="dev prod")
	@kubectl apply -f - <<< '{"apiVersion":"kro.run/v1alpha1","kind":"Tenant","metadata":{"name":"$(TEAM)","namespace":"platform-system"},"spec":{"team":"$(TEAM)","environments":$(shell echo '$(ENVS)' | jq -R 'split(" ")')}}'
	@echo "✅ Team $(TEAM) onboarded with namespaces: $(ENVS)"

## --- ECR Login ---

.PHONY: ecr-login
ecr-login: ## Login to ECR for Helm push
	aws ecr get-login-password | helm registry login --username AWS --password-stdin $(REGISTRY)

## --- Help ---

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
