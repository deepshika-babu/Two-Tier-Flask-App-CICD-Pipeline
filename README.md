# GCP Two-Tier Flask App with Cloud Build

Automated CI/CD pipeline for a 2-tier Flask + MySQL application on Google Cloud Platform.

Push to GitHub → Cloud Build builds the image → Artifact Registry stores it → Compute Engine VM pulls and runs it with Docker Compose.

## Architecture

```
Developer → GitHub → Cloud Build → Artifact Registry
                         ↓
              GCE VM (SSH deploy as ubuntu)
                    ├── Flask container
                    └── MySQL container
```

## Free tier fit

This setup stays within GCP Always Free limits when configured correctly:

- **VM:** 1× `e2-micro` in `us-central1`, `us-east1`, or `us-west1`
- **Cloud Build:** 2,500 build-minutes/month
- **Artifact Registry:** 500 MB storage/month
- **MySQL:** runs in Docker on the VM (no Cloud SQL cost)

Stay in a free-tier region, use `e2-micro` only, and stop the VM when not in use.

## Prerequisites

- GCP account with free trial / billing enabled
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) or [Cloud Shell](https://shell.cloud.google.com)
- GitHub repository for this project

Set these variables once (Cloud Shell or local terminal):

```bash
export PROJECT_ID=your-gcp-project-id
export REGION=us-central1
export ZONE=us-central1-a
export VM_NAME=two-tier-vm
export REPOSITORY=flask-app

gcloud config set project $PROJECT_ID
```

## Step 1: Enable APIs

```bash
gcloud services enable \
  cloudbuild.googleapis.com \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com
```

## Step 2: Create Artifact Registry

Create the repository in a free-tier region (`us-central1`, `us-east1`, or `us-west1`):

```bash
gcloud artifacts repositories create $REPOSITORY \
  --repository-format=docker \
  --location=$REGION \
  --description="Flask app images"
```

## Step 3: Create firewall rule

Only port **5000** is required for the web app. SSH is already allowed on the default VPC via `default-allow-ssh` — you do not need a custom SSH firewall rule unless you want to restrict access to your IP.

```bash
gcloud compute firewall-rules create allow-flask-5000 \
  --allow=tcp:5000 \
  --target-tags=flask-app \
  --description="Allow Flask app traffic"
```

## Step 4: Create the VM

```bash
gcloud compute instances create $VM_NAME \
  --zone=$ZONE \
  --machine-type=e2-micro \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=30GB \
  --tags=flask-app \
  --scopes=cloud-platform
```

The `cloud-platform` scope lets the VM's service account authenticate to Artifact Registry via the metadata server.

## Step 5: Bootstrap the VM

### 5a. Copy and run the setup script

From Cloud Shell (clone your repo first if needed):

```bash
git clone https://github.com/YOUR_USERNAME/YOUR_REPO.git
cd YOUR_REPO

gcloud compute scp scripts/vm-setup.sh ubuntu@$VM_NAME:~/vm-setup.sh --zone=$ZONE

gcloud compute ssh ubuntu@$VM_NAME --zone=$ZONE --command="
  export PROJECT_ID=${PROJECT_ID}
  export REGION=${REGION}
  bash ~/vm-setup.sh
"
```

The script installs Docker, Docker Compose, the gcloud CLI, and configures Artifact Registry auth for both `ubuntu` and `root`.

### 5b. Verify Docker works

```bash
gcloud compute ssh ubuntu@$VM_NAME --zone=$ZONE --command="sudo docker run hello-world"
```

### 5c. Grant the VM permission to pull images

Run from **Cloud Shell** (not on the VM). Both project-level **and** repository-level IAM are required:

```bash
bash scripts/grant-vm-ar-access.sh
```

Or manually:

```bash
VM_SA=$(gcloud compute instances describe $VM_NAME --zone=$ZONE \
  --format='value(serviceAccounts[0].email)')

echo "VM service account: ${VM_SA}"
```

Confirm this prints an email like `123456789012-compute@developer.gserviceaccount.com`. If it is blank, check `$VM_NAME` and `$ZONE`.

```bash
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${VM_SA}" \
  --role="roles/artifactregistry.reader"

gcloud artifacts repositories add-iam-policy-binding $REPOSITORY \
  --location=$REGION \
  --member="serviceAccount:${VM_SA}" \
  --role="roles/artifactregistry.reader"
```

Wait ~60 seconds for IAM to propagate before testing pulls.

## Step 6: Configure Cloud Build IAM

Cloud Build needs permission to push images and SSH into the VM as `ubuntu`:

```bash
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')
CLOUD_BUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${CLOUD_BUILD_SA}" \
  --role="roles/compute.instanceAdmin.v1"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${CLOUD_BUILD_SA}" \
  --role="roles/iam.serviceAccountUser"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${CLOUD_BUILD_SA}" \
  --role="roles/artifactregistry.writer"
```

## Step 7: Connect GitHub and create trigger

1. Open [Cloud Build Triggers](https://console.cloud.google.com/cloud-build/triggers)
2. Click **Connect Repository** → GitHub → authorize and select your repo
3. Click **Create Trigger**:
   - **Name:** `deploy-flask-app`
   - **Event:** Push to branch
   - **Branch:** `^main$`
   - **Configuration:** Cloud Build configuration file
   - **Location:** `cloudbuild.yaml`
4. Add substitution variables (must match your infrastructure):
   - `_REGION` = `us-central1`
   - `_ZONE` = `us-central1-a`
   - `_VM_NAME` = `two-tier-vm`
   - `_REPOSITORY` = `flask-app`
   - `_SSH_USER` = `ubuntu`

## Step 8: Push code and deploy

```bash
git add .
git commit -m "Initial GCP Cloud Build pipeline"
git push origin main
```

Monitor the build in [Cloud Build History](https://console.cloud.google.com/cloud-build/builds).

## Step 9: Verify

Get the VM external IP:

```bash
gcloud compute instances describe $VM_NAME --zone=$ZONE \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
```

Open `http://<EXTERNAL_IP>:5000` in your browser.

On the VM:

```bash
gcloud compute ssh ubuntu@$VM_NAME --zone=$ZONE
sudo docker ps
curl http://localhost:5000/health
```

MySQL can take up to 60 seconds to pass its healthcheck before Flask starts.

## Manual deploy test (optional)

Use this to test the VM independently of Cloud Build. The deploy script must exist on the VM first.

```bash
gcloud compute scp scripts/deploy-on-vm.sh ubuntu@$VM_NAME:~/app/deploy-on-vm.sh --zone=$ZONE

gcloud compute ssh ubuntu@$VM_NAME --zone=$ZONE --command="
  chmod +x ~/app/deploy-on-vm.sh
  REGION=${REGION} IMAGE=${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/flask-app:latest ~/app/deploy-on-vm.sh
"
```

Or SSH into the VM and run directly:

```bash
export REGION=us-central1
export IMAGE=us-central1-docker.pkg.dev/your-project/flask-app/flask-app:latest
~/app/deploy-on-vm.sh
```

## Local development (optional)

```bash
docker build -t flask-app:local .
export IMAGE=flask-app:local
docker compose up -d
```

App: http://localhost:5000

## Pipeline overview (`cloudbuild.yaml`)

1. **Build** — Docker image tagged with `$COMMIT_SHA` and `latest`
2. **Push** — image pushed to Artifact Registry
3. **Prepare VM** — create `~/app` on the VM
4. **Copy files** — `docker-compose.yml` and `scripts/deploy-on-vm.sh` copied via SCP
5. **Deploy** — SSH as `ubuntu`, run `deploy-on-vm.sh` which:
   - Authenticates to Artifact Registry using the VM metadata token
   - Pulls the image
   - Writes a valid `docker-compose.yml` (avoids YAML issues with image tags)
   - Runs `docker compose up -d`

## Troubleshooting

| Issue | Fix |
|---|---|
| `$VM_SA` is empty | Use `serviceAccounts` (plural) in the `--format` flag. Verify `$VM_NAME` and `$ZONE` |
| `scp: /root/app/... No such file or directory` | Cloud Build connects as `ubuntu`, not `root`. Use `ubuntu@$VM_NAME` and ensure `~/app` exists |
| `deploy-on-vm.sh: No such file or directory` | Copy the script to the VM with `gcloud compute scp` before running it manually |
| `permission denied` on `docker.sock` | Deploy runs Docker with `sudo`. Verify with `sudo docker ps` on the VM |
| `Login Succeeded` then `Unauthenticated request` on pull | Grant IAM at **project and repository** level via `scripts/grant-vm-ar-access.sh`. Wait 60s for propagation |
| `go-yaml load error` / `mapping values are not allowed` | Docker image tags contain colons (`mysql:8.0`) and must be quoted in YAML. `deploy-on-vm.sh` writes a correct compose file on every deploy |
| Cloud Build SSH fails | Check IAM roles on the Cloud Build service account; verify trigger substitution variables |
| Flask unhealthy | Wait for MySQL healthcheck (~60s); check `sudo docker logs two-tier-app` |
| Port 5000 unreachable | Verify the `allow-flask-5000` firewall rule and VM tag `flask-app` |
| Build exceeds free tier | Use `e2-micro` only; stay in `us-central1`/`us-east1`/`us-west1`; delete old Artifact Registry images |

## Project structure

```
.
├── app.py                      # Flask application
├── cloudbuild.yaml             # CI/CD pipeline
├── docker-compose.yml          # Flask + MySQL (local dev; VM gets a generated copy on deploy)
├── Dockerfile
├── requirement.txt
├── message.sql
├── scripts/
│   ├── vm-setup.sh             # One-time VM bootstrap
│   ├── deploy-on-vm.sh         # Pull image and start containers on the VM
│   └── grant-vm-ar-access.sh   # Grant Artifact Registry read IAM to the VM
└── templates/
    └── index.html
```

## Reference

Based on [DevOps-Project-Two-Tier-Flask-App](https://github.com/
prashantgohel321/DevOps-Project-Two-Tier-Flask-App), adapted for GCP 
Cloud Build.