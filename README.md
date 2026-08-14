# GCP Two-Tier Flask App with Cloud Build

Automated CI/CD pipeline for a 2-tier Flask + MySQL application on Google Cloud Platform.

| Original (AWS) | This project (GCP) |
|---|---|
| AWS EC2 | Compute Engine VM (`e2-micro`) |
| Jenkins | Cloud Build |
| `Jenkinsfile` | `cloudbuild.yaml` |
| Docker Compose on VM | Docker Compose on VM |

## Architecture

```
Developer → GitHub → Cloud Build → Artifact Registry
                         ↓
                    GCE VM (SSH deploy)
                    ├── Flask container
                    └── MySQL container
```

## Free tier fit

This setup stays within GCP Always Free limits when configured correctly:

- **VM:** 1× `e2-micro` in `us-central1`, `us-east1`, or `us-west1`
- **Cloud Build:** 2,500 build-minutes/month
- **Artifact Registry:** 500 MB storage/month
- **MySQL:** runs in Docker on the VM (no Cloud SQL cost)

## Prerequisites

- GCP account with free trial / billing enabled
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) installed locally
- GitHub repository for this project
- Git installed locally

Set your project ID once:

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

```bash
gcloud artifacts repositories create $REPOSITORY \
  --repository-format=docker \
  --location=$REGION \
  --description="Flask app images"
```

## Step 3: Create firewall rules

```bash
gcloud compute firewall-rules create allow-flask-5000 \
  --allow=tcp:5000 \
  --target-tags=flask-app \
  --description="Allow Flask app traffic"

gcloud compute firewall-rules create allow-ssh \
  --allow=tcp:22 \
  --source-ranges=YOUR_IP/32 \
  --description="Allow SSH from your IP"
```

Replace `YOUR_IP` with your public IP (find it at https://ifconfig.me).

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

## Step 5: Bootstrap the VM

SSH into the VM:

```bash
gcloud compute ssh $VM_NAME --zone=$ZONE
```

On the VM, install Docker and configure Artifact Registry:

```bash
export PROJECT_ID=your-gcp-project-id
export REGION=us-central1

# Copy vm-setup.sh to the VM, or paste its contents and run:
bash scripts/vm-setup.sh
```

Log out and back in so Docker group membership applies:

```bash
exit
gcloud compute ssh $VM_NAME --zone=$ZONE
newgrp docker
```

Grant the VM service account permission to pull images:

```bash
# Run from Cloud Shell or local machine (not on VM)
VM_SA=$(gcloud compute instances describe $VM_NAME --zone=$ZONE \
  --format='value(serviceAccounts[0].email)')

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${VM_SA}" \
  --role="roles/artifactregistry.reader"
```

Verify the binding (should list `artifactregistry.reader`):

```bash
echo "VM service account: ${VM_SA}"
gcloud projects get-iam-policy $PROJECT_ID \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:${VM_SA}" \
  --format="table(bindings.role)"
```

Test pull on the VM (run after at least one successful Cloud Build push):

```bash
gcloud compute ssh ubuntu@$VM_NAME --zone=$ZONE --command="
  gcloud auth print-access-token | sudo docker login -u oauth2accesstoken --password-stdin https://${REGION}-docker.pkg.dev
  sudo docker pull ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/flask-app:latest
"
```

Create the app directory on the VM:

```bash
mkdir -p ~/app
```

## Step 6: Configure Cloud Build IAM

Cloud Build needs permission to SSH into the VM and push images.

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

Optional but recommended for SSH without opening port 22 publicly:

```bash
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${CLOUD_BUILD_SA}" \
  --role="roles/iap.tunnelResourceAccessor"
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
4. Add substitution variables (must match your VM):
   - `_REGION` = `us-central1`
   - `_ZONE` = `us-central1-a`
   - `_VM_NAME` = `two-tier-vm`
   - `_REPOSITORY` = `flask-app`

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

On the VM, confirm containers are running:

```bash
docker ps
curl http://localhost:5000/health
```

## Local development (optional)

Build and run locally without GCP:

```bash
docker build -t flask-app:local .
export IMAGE=flask-app:local
docker compose up -d --build
```

App: http://localhost:5000

## Pipeline overview (`cloudbuild.yaml`)

1. **Build** — Docker image tagged with `$COMMIT_SHA` and `latest`
2. **Push** — image pushed to Artifact Registry
3. **Copy** — `docker-compose.yml` copied to VM via `gcloud compute scp`
4. **Deploy** — SSH into VM, pull image, `docker compose up -d`

## Troubleshooting

| Issue | Fix |
|---|---|
| `scp: /root/app/... No such file or directory` | Cloud Build SSHs as `ubuntu`, not `root`. Ensure `vm-setup.sh` ran as ubuntu and `~/app` exists: `mkdir -p ~/app` on the VM |
| `permission denied` on `docker.sock` | Non-interactive SSH may not load the `docker` group. Deploy uses `sudo docker compose`. Verify on VM: `sudo docker ps` |
| Cloud Build SSH fails | Check IAM roles on Cloud Build SA; verify VM name/zone substitutions |
| VM cannot pull image | Grant `artifactregistry.reader` to the **VM** service account (not Cloud Build). Test: `gcloud auth print-access-token \| sudo docker login ...` then `sudo docker pull ...` |
| Flask unhealthy | Wait for MySQL healthcheck (~60s); check `docker logs two-tier-app` |
| Port 5000 unreachable | Verify firewall rule and VM tag `flask-app` |
| Build exceeds free tier | Use `e2-micro` only; stay in `us-central1`/`us-east1`/`us-west1`; delete old AR images |

## Project structure

```
.
├── app.py                 # Flask application
├── cloudbuild.yaml        # CI/CD pipeline (replaces Jenkinsfile)
├── docker-compose.yml     # Flask + MySQL on VM
├── Dockerfile
├── requirement.txt
├── message.sql
├── scripts/
│   └── vm-setup.sh        # One-time VM bootstrap
└── templates/
    └── index.html
```

## Reference

Based on [DevOps-Project-Two-Tier-Flask-App](https://github.com/prashantgohel321/DevOps-Project-Two-Tier-Flask-App), adapted for GCP Cloud Build.