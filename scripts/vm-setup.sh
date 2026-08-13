#!/usr/bin/env bash
set -euo pipefail

# One-time bootstrap for the GCE VM.
# Run on the VM after SSH: curl -sSL <raw-url> | bash
# Or copy this file and run: bash vm-setup.sh

REGION="${REGION:-us-central1}"
PROJECT_ID="${PROJECT_ID:-}"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Set PROJECT_ID before running, e.g.:"
  echo "  export PROJECT_ID=my-gcp-project"
  exit 1
fi

echo "==> Updating packages..."
sudo apt-get update
sudo apt-get upgrade -y

echo "==> Installing Docker..."
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> Adding current user to docker group..."
sudo usermod -aG docker "$USER"

echo "==> Installing Google Cloud CLI..."
sudo apt-get install -y apt-transport-https ca-certificates gnupg
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | \
  sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
sudo apt-get update
sudo apt-get install -y google-cloud-cli

echo "==> Configuring Artifact Registry auth..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

echo "==> Creating app directory..."
mkdir -p ~/app

echo "==> Granting VM service account Artifact Registry read access (run from Cloud Shell if this fails)..."
echo "    gcloud projects add-iam-policy-binding ${PROJECT_ID} \\"
echo "      --member=\"serviceAccount:$(curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email)\" \\"
echo "      --role=\"roles/artifactregistry.reader\""

echo ""
echo "Setup complete. Log out and back in (or run: newgrp docker), then test with:"
echo "  docker run hello-world"
