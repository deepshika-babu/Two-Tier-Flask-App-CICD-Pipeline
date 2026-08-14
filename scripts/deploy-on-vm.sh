#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:?REGION is required}"
IMAGE="${IMAGE:?IMAGE is required}"

TOKEN=$(curl -sf -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
  | python3 -c "import sys, json; print(json.load(sys.stdin)['access_token'])")

echo "${TOKEN}" | sudo docker login -u oauth2accesstoken --password-stdin \
  "https://${REGION}-docker.pkg.dev"

sudo docker pull "${IMAGE}"

mkdir -p ~/app
cat > ~/app/docker-compose.yml << 'EOF'
services:
  mysql:
    container_name: mysql
    image: "mysql:8.0"
    environment:
      MYSQL_ROOT_PASSWORD: "root"
      MYSQL_DATABASE: "devops"
    ports:
      - "3306:3306"
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - two-tier-nt
    restart: always
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-uroot", "-proot"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 60s

  flask-app:
    container_name: two-tier-app
    image: "${IMAGE}"
    ports:
      - "5000:5000"
    environment:
      - MYSQL_HOST=mysql
      - MYSQL_USER=root
      - MYSQL_PASSWORD=root
      - MYSQL_DB=devops
      - FLASK_DEBUG=false
    networks:
      - two-tier-nt
    depends_on:
      mysql:
        condition: service_healthy
    restart: always
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:5000/health || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 60s

volumes:
  mysql_data:

networks:
  two-tier-nt:
EOF

cd ~/app
export IMAGE
sudo -E docker compose config >/dev/null
sudo -E docker compose up -d
