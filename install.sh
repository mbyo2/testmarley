#!/bin/bash
# ==============================================================================
# Marley Health Dockerized Installer (Frappe v16 + ERPNext)
# ==============================================================================
set -e

# Colors for console output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================================================${NC}"
echo -e "${GREEN}  Starting Docker Setup for Frappe v16 + ERPNext + Marley Health  ${NC}"
echo -e "${BLUE}======================================================================${NC}"

# 1. Pre-flight Checks
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Please run this script as root (e.g., sudo ./install.sh)${NC}"
  exit 1
fi

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [ ! -f "$DIR/config.env" ]; then
    echo -e "${RED}Error: config.env not found! Please ensure it is in the same directory.${NC}"
    exit 1
fi

# Load Configuration
export $(grep -v '^#' "$DIR/config.env" | xargs)

# 2. Swap Check
SWAP_MEM=$(free -m | awk '/^Swap:/{print $2}')
if [ "$SWAP_MEM" -eq 0 ]; then
    echo -e "${BLUE}➡️ No swap memory detected. Creating 4GB swap file...${NC}"
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 3. Clean up legacy services
echo -e "${BLUE}➡️ Stopping local services if they exist...${NC}"
systemctl stop nginx mariadb redis-server 2>/dev/null || true
systemctl disable nginx mariadb redis-server 2>/dev/null || true

# 4. Install Docker & Docker Compose
if ! command -v docker &> /dev/null; then
    echo -e "${BLUE}➡️ Installing Docker Engine...${NC}"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
fi
apt-get update -q && apt-get install -yq docker-compose-plugin

# 5. Setup Docker Project Directory
PROJECT_DIR="/opt/marley-health"
echo -e "${BLUE}➡️ Setting up Docker workspace at ${PROJECT_DIR}...${NC}"
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR
cp "$DIR/config.env" .env

# 6. Pull Official Base Image
echo -e "${BLUE}➡️ Pulling official frappe/erpnext:version-16 image...${NC}"
docker pull frappe/erpnext:version-16

# 7. Create Custom Dockerfile
echo -e "${BLUE}➡️ Generating Dockerfile...${NC}"
cat > Dockerfile <<EOF
FROM frappe/erpnext:version-16
USER root
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
USER frappe
EOF

# 8. Create Docker Compose Configuration
echo -e "${BLUE}➡️ Generating docker-compose.yml...${NC}"
cat > docker-compose.yml <<EOF
services:
  backend:
    build: .
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs
    environment:
      - DB_HOST=db
      - DB_PORT=3306
      - REDIS_CACHE=redis-cache:6379
      - REDIS_QUEUE=redis-queue:6379
      - REDIS_SOCKETIO=redis-socketio:6379

  configurator:
    build: .
    entrypoint: [ "bash", "-c" ]
    command:
      - >
        bench set-config -g db_host db;
        bench set-config -g redis_cache "redis://redis-cache:6379";
        bench set-config -g redis_queue "redis://redis-queue:6379";
        bench set-config -g redis_socketio "redis://redis-socketio:6379";
        bench get-app https://github.com/earthians/marley.git;
    environment:
      - MARIADB_ROOT_PASS=\${MARIADB_ROOT_PASS}
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs

  frontend:
    build: .
    command: [ "nginx-entrypoint.sh" ]
    ports:
      - "80:8080"
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs

  db:
    image: mariadb:10.6
    environment:
      - MYSQL_ROOT_PASSWORD=\${MARIADB_ROOT_PASS}
    volumes:
      - db-data:/var/lib/mysql
  redis-cache:
    image: redis:7-alpine
  redis-queue:
    image: redis:7-alpine
  redis-socketio:
    image: redis:7-alpine

  worker:
    build: .
    command: [ "bench", "worker" ]
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs

volumes:
  db-data:
  sites:
  logs:
EOF

# 9. Build and Launch
echo -e "${BLUE}➡️ Building containers...${NC}"
docker compose build
docker compose up -d db redis-cache redis-queue redis-socketio
echo -e "${BLUE}➡️ Waiting 20s for DB...${NC}"
sleep 20
docker compose run --rm configurator
docker compose up -d backend frontend worker

# 10. Site Initialization
echo -e "${BLUE}➡️ Setting up Site...${NC}"
if ! docker compose exec backend ls -1 sites | grep -q "^${SITE_NAME}$"; then
    docker compose exec backend bench new-site ${SITE_NAME} --mariadb-root-password "${MARIADB_ROOT_PASS}" --admin-password "${ADMIN_PASS}"
    docker compose exec backend bench --site ${SITE_NAME} install-app erpnext
    docker compose exec backend bench --site ${SITE_NAME} install-app marley
    docker compose exec backend bench --site ${SITE_NAME} build
    docker compose exec backend bench use ${SITE_NAME}
fi

echo -e "${GREEN}✅ Installation Complete!${NC}"
