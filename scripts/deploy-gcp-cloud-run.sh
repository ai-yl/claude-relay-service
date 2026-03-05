#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

generate_alnum() {
  local len="$1"
  local out=""
  while [ "${#out}" -lt "$len" ]; do
    out="${out}$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
    out="${out:0:$len}"
  done
  echo "$out"
}

ensure_secret() {
  local name="$1"
  local value="$2"
  local project="$3"

  if gcloud secrets describe "$name" --project "$project" >/dev/null 2>&1; then
    echo "Secret exists: $name"
    return 0
  fi

  echo -n "$value" | gcloud secrets create "$name" --project "$project" --data-file=-
  echo "Created secret: $name"
}

require_cmd gcloud
require_cmd openssl
require_cmd tr
require_cmd cut

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
REGION="${REGION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:-claude-relay-service}"
REDIS_INSTANCE="${REDIS_INSTANCE:-${SERVICE_NAME}-redis}"
VPC_NETWORK="${VPC_NETWORK:-default}"
VPC_CONNECTOR="${VPC_CONNECTOR:-crs-connector}"
CONNECTOR_SUBNET="${CONNECTOR_SUBNET:-${VPC_CONNECTOR}-subnet}"
CONNECTOR_SUBNET_RANGE="${CONNECTOR_SUBNET_RANGE:-172.16.0.0/28}"
PRIVATE_SERVICE_RANGE_NAME="${PRIVATE_SERVICE_RANGE_NAME:-google-managed-services-${VPC_NETWORK}}"
PRIVATE_SERVICE_CIDR="${PRIVATE_SERVICE_CIDR:-172.20.0.0}"
PRIVATE_SERVICE_PREFIX_LEN="${PRIVATE_SERVICE_PREFIX_LEN:-16}"
RUNTIME_SA_NAME="${RUNTIME_SA_NAME:-${SERVICE_NAME}-runtime}"

SECRET_JWT="${SECRET_JWT:-${SERVICE_NAME}-jwt-secret}"
SECRET_ENCRYPTION="${SECRET_ENCRYPTION:-${SERVICE_NAME}-encryption-key}"
SECRET_ADMIN_USERNAME="${SECRET_ADMIN_USERNAME:-${SERVICE_NAME}-admin-username}"
SECRET_ADMIN_PASSWORD="${SECRET_ADMIN_PASSWORD:-${SERVICE_NAME}-admin-password}"

MIN_INSTANCES="${MIN_INSTANCES:-0}"
MAX_INSTANCES="${MAX_INSTANCES:-10}"
CPU="${CPU:-1}"
MEMORY="${MEMORY:-1Gi}"

if [ -z "$PROJECT_ID" ]; then
  echo "PROJECT_ID is empty. Set PROJECT_ID env or run: gcloud config set project <PROJECT_ID>" >&2
  exit 1
fi

if ! echo "$VPC_CONNECTOR" | grep -Eq '^[a-z][-a-z0-9]{0,23}[a-z0-9]$'; then
  echo "Invalid VPC_CONNECTOR name: $VPC_CONNECTOR" >&2
  echo "It must match: ^[a-z][-a-z0-9]{0,23}[a-z0-9]$" >&2
  exit 1
fi

RUNTIME_SA_EMAIL="${RUNTIME_SA_EMAIL:-${RUNTIME_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com}"

echo "Project: $PROJECT_ID"
echo "Region: $REGION"
echo "Service: $SERVICE_NAME"
echo "Redis instance: $REDIS_INSTANCE"

gcloud config set project "$PROJECT_ID" >/dev/null

echo "Enabling required GCP APIs..."
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  servicenetworking.googleapis.com \
  redis.googleapis.com \
  vpcaccess.googleapis.com \
  compute.googleapis.com \
  --project "$PROJECT_ID" >/dev/null

if ! gcloud iam service-accounts describe "$RUNTIME_SA_EMAIL" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "Creating runtime service account: $RUNTIME_SA_EMAIL"
  gcloud iam service-accounts create "$RUNTIME_SA_NAME" \
    --project "$PROJECT_ID" \
    --display-name "Claude Relay Service runtime"
else
  echo "Runtime service account exists: $RUNTIME_SA_EMAIL"
fi

echo "Granting Secret Manager access to runtime service account..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:${RUNTIME_SA_EMAIL}" \
  --role "roles/secretmanager.secretAccessor" \
  --quiet >/dev/null

JWT_VALUE="${JWT_SECRET:-$(openssl rand -hex 64)}"
ENCRYPTION_VALUE="${ENCRYPTION_KEY:-$(openssl rand -hex 16)}"
ADMIN_USERNAME_VALUE="${ADMIN_USERNAME:-cr_admin_$(openssl rand -hex 4)}"
ADMIN_PASSWORD_VALUE="${ADMIN_PASSWORD:-$(generate_alnum 20)}"

echo "Ensuring secrets..."
ensure_secret "$SECRET_JWT" "$JWT_VALUE" "$PROJECT_ID"
ensure_secret "$SECRET_ENCRYPTION" "$ENCRYPTION_VALUE" "$PROJECT_ID"
ensure_secret "$SECRET_ADMIN_USERNAME" "$ADMIN_USERNAME_VALUE" "$PROJECT_ID"
ensure_secret "$SECRET_ADMIN_PASSWORD" "$ADMIN_PASSWORD_VALUE" "$PROJECT_ID"

CONNECTOR_STATE="$(gcloud compute networks vpc-access connectors describe "$VPC_CONNECTOR" \
  --region "$REGION" \
  --project "$PROJECT_ID" \
  --format='value(state)' 2>/dev/null || true)"

if [ "$CONNECTOR_STATE" = "READY" ]; then
  echo "VPC connector exists: $VPC_CONNECTOR"
else
  if [ "$CONNECTOR_STATE" = "ERROR" ]; then
    echo "Deleting VPC connector in ERROR state: $VPC_CONNECTOR"
    gcloud compute networks vpc-access connectors delete "$VPC_CONNECTOR" \
      --region "$REGION" \
      --project "$PROJECT_ID" \
      --quiet
  fi

  if ! gcloud compute networks subnets describe "$CONNECTOR_SUBNET" \
    --region "$REGION" \
    --project "$PROJECT_ID" >/dev/null 2>&1; then
    echo "Creating connector subnet: $CONNECTOR_SUBNET ($CONNECTOR_SUBNET_RANGE)"
    gcloud compute networks subnets create "$CONNECTOR_SUBNET" \
      --network "$VPC_NETWORK" \
      --region "$REGION" \
      --range "$CONNECTOR_SUBNET_RANGE" \
      --project "$PROJECT_ID"
  else
    echo "Connector subnet exists: $CONNECTOR_SUBNET"
  fi

  echo "Creating Serverless VPC connector: $VPC_CONNECTOR"
  gcloud compute networks vpc-access connectors create "$VPC_CONNECTOR" \
    --region "$REGION" \
    --subnet "$CONNECTOR_SUBNET" \
    --project "$PROJECT_ID"
fi

echo "Ensuring Private Service Access for Memorystore..."
if ! gcloud compute addresses describe "$PRIVATE_SERVICE_RANGE_NAME" \
  --global \
  --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud compute addresses create "$PRIVATE_SERVICE_RANGE_NAME" \
    --global \
    --purpose VPC_PEERING \
    --addresses "$PRIVATE_SERVICE_CIDR" \
    --prefix-length "$PRIVATE_SERVICE_PREFIX_LEN" \
    --network "$VPC_NETWORK" \
    --project "$PROJECT_ID"
else
  echo "Private service range exists: $PRIVATE_SERVICE_RANGE_NAME"
fi

if ! gcloud services vpc-peerings list \
  --network "$VPC_NETWORK" \
  --project "$PROJECT_ID" \
  --format='value(peering)' \
  --quiet | grep -q 'servicenetworking-googleapis-com'; then
  gcloud services vpc-peerings connect \
    --service servicenetworking.googleapis.com \
    --ranges "$PRIVATE_SERVICE_RANGE_NAME" \
    --network "$VPC_NETWORK" \
    --project "$PROJECT_ID" \
    --quiet
else
  echo "Private Service Access peering exists."
fi

if ! gcloud redis instances describe "$REDIS_INSTANCE" \
  --region "$REGION" \
  --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "Creating Redis instance: $REDIS_INSTANCE (this can take several minutes)"
  gcloud redis instances create "$REDIS_INSTANCE" \
    --region "$REGION" \
    --size 1 \
    --redis-version redis_7_0 \
    --tier basic \
    --network "$VPC_NETWORK" \
    --connect-mode private-service-access \
    --project "$PROJECT_ID"
else
  echo "Redis instance exists: $REDIS_INSTANCE"
fi

REDIS_HOST="$(gcloud redis instances describe "$REDIS_INSTANCE" --region "$REGION" --project "$PROJECT_ID" --format='value(host)')"

if [ -z "$REDIS_HOST" ]; then
  echo "Failed to resolve Redis host for instance: $REDIS_INSTANCE" >&2
  exit 1
fi

echo "Deploying Cloud Run service..."
gcloud run deploy "$SERVICE_NAME" \
  --source . \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --allow-unauthenticated \
  --port 3000 \
  --cpu "$CPU" \
  --memory "$MEMORY" \
  --min-instances "$MIN_INSTANCES" \
  --max-instances "$MAX_INSTANCES" \
  --vpc-connector "$VPC_CONNECTOR" \
  --vpc-egress private-ranges-only \
  --service-account "$RUNTIME_SA_EMAIL" \
  --set-env-vars "NODE_ENV=production,HOST=0.0.0.0,TRUST_PROXY=true,REDIS_HOST=${REDIS_HOST},REDIS_PORT=6379,REDIS_DB=0,CLEAR_CONCURRENCY_QUEUES_ON_STARTUP=false" \
  --set-secrets "JWT_SECRET=${SECRET_JWT}:latest,ENCRYPTION_KEY=${SECRET_ENCRYPTION}:latest,ADMIN_USERNAME=${SECRET_ADMIN_USERNAME}:latest,ADMIN_PASSWORD=${SECRET_ADMIN_PASSWORD}:latest"

SERVICE_URL="$(gcloud run services describe "$SERVICE_NAME" --project "$PROJECT_ID" --region "$REGION" --format='value(status.url)')"

echo
echo "Deployment completed."
echo "Service URL: ${SERVICE_URL}"
echo "Admin panel: ${SERVICE_URL}/admin-next/login"
