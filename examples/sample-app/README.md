# Sample App — Platform PoC

A simple Flask API that validates platform resource injection (database, cache, events).

## Endpoints

| Endpoint | What it does |
|----------|-------------|
| `GET /` | Shows all injected env vars (DATABASE_HOST, CACHE_HOST, etc.) |
| `GET /health` | Health check |
| `GET /db` | Connects to the database and returns PostgreSQL version |
| `GET /cache` | Pings Redis and returns version |
| `GET /events/publish` | Publishes a test message to SNS |

## Deploy

### 1. Build and push the container image

```bash
# Login to ECR
aws ecr get-login-password --region us-east-1 --profile account-a | \
  docker login --username AWS --password-stdin 279051970617.dkr.ecr.us-east-1.amazonaws.com

# Create the ECR repo (one-time)
aws ecr create-repository --repository-name sample-app --profile account-a

# Build and push
docker build -t sample-app .
docker tag sample-app:latest 279051970617.dkr.ecr.us-east-1.amazonaws.com/sample-app:latest
docker push 279051970617.dkr.ecr.us-east-1.amazonaws.com/sample-app:latest
```

### 2. Create the team namespace (if not already done)

```bash
kubectl apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: Tenant
metadata:
  name: commerce
  namespace: platform-system
spec:
  team: commerce
  environments: ["dev", "prod"]
EOF
```

### 3. Deploy the workload

```bash
kubectl apply -f workload.yaml
```

### 4. Verify

```bash
# Check workload status
kubectl get workload sample-app -n team-commerce-dev

# Check all resources created
kubectl get databases -n team-commerce-dev
kubectl get caches -n team-commerce-dev
kubectl get eventbuses -n team-commerce-dev
kubectl get deployments -n team-commerce-dev

# Test the app
kubectl port-forward svc/sample-app -n team-commerce-dev 8080:80
curl http://localhost:8080/       # shows injected env vars
curl http://localhost:8080/db     # connects to RDS
curl http://localhost:8080/cache  # pings Redis
curl http://localhost:8080/events/publish  # publishes to SNS
```

## What this proves

1. Developer writes ONE manifest (workload.yaml)
2. Platform provisions: RDS + ElastiCache + SNS/SQS + IAM + Pod Identity
3. Connection details are auto-injected as env vars
4. App connects to real AWS resources without any infra knowledge
