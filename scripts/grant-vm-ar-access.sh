#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID is required}"
VM_NAME="${VM_NAME:-two-tier-vm}"
ZONE="${ZONE:-us-central1-a}"
REGION="${REGION:-us-central1}"
REPOSITORY="${REPOSITORY:-flask-app}"

VM_SA=$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" \
  --format='value(serviceAccounts[0].email)')

if [[ -z "$VM_SA" ]]; then
  echo "ERROR: Could not resolve VM service account for ${VM_NAME}" >&2
  exit 1
fi

echo "VM service account: ${VM_SA}"

echo "==> Granting project-level Artifact Registry reader..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VM_SA}" \
  --role="roles/artifactregistry.reader"

echo "==> Granting repository-level Artifact Registry reader..."
gcloud artifacts repositories add-iam-policy-binding "$REPOSITORY" \
  --location="$REGION" \
  --member="serviceAccount:${VM_SA}" \
  --role="roles/artifactregistry.reader"

echo "==> Current IAM roles for VM service account:"
gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:${VM_SA}" \
  --format="table(bindings.role)"

echo ""
echo "Done. Wait ~60 seconds for IAM to propagate, then test:"
echo "  gcloud compute ssh ubuntu@${VM_NAME} --zone=${ZONE} --command='bash ~/app/deploy-on-vm.sh' \\"
echo "    -- -e REGION=${REGION} IMAGE=${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/flask-app:latest"
echo ""
echo "Or copy deploy-on-vm.sh to the VM first if not yet deployed via Cloud Build."
