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

# 2. Swap Check (Docker builds still require RAM to compile JS assets)
SWAP_MEM=$(free -m | awk '/^Swap:/{print $2}')
if [ "$SWAP_MEM" -eq 0 ]; then
    echo -e "${BLUE}➡️ No swap memory detected. Creating 4GB swap file...${NC}"
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 3. Clean up legacy services (Frees up ports 80, 443, 3306 for Docker)
echo -e "${BLUE}➡️ Stopping local services (NGINX, MariaDB, Redis) if they exist...${NC}"
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

# Copy config variables for Docker Compose to use natively
cp "$DIR/config.env" .env

# 6. Pull Official Base Image
echo -e "${BLUE}➡️ Pulling official frappe/erpnext:version-16 image...${NC}"
docker pull frappe/erpnext:version-16

# 7. Create Custom Dockerfile for Marley Health
echo -e "${BLUE}➡️ Generating Dockerfile to inject Marley Health...${NC}"
cat > Dockerfile <<EOF
FROM frappe/erpnext:version-16

# Switch to root to install Node & Git (needed to fetch and compile Marley)
USER root
RUN apt-get update && \\
    apt-get install -y git curl && \\
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \\
    apt-get install -y nodejs && \\
    npm install -g yarn && \\
    rm -rf /var/lib/apt/lists/*

# Switch back to the unprivileged frappe user
USER frappe

# Download Marley and compile the frontend assets directly into the image
RUN bench get-app https://github.com/earthians/marley.git && \\
    bench build
EOF

# 8. Create Docker Compose Configuration
echo -e "${BLUE}➡️ Generating docker-compose.yml...${NC}"
cat > docker-compose.yml <<EOF
services:
  backend:
    build: .
    restart: on-failure
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
    restart: "no"
    entrypoint: [ "bash", "-c" ]
    command:
      - >
        ls -1 apps > sites/apps.txt;
        bench set-config -g db_host db;
        bench set-config -g redis_cache "redis://redis-cache:6379";
        bench set-config -g redis_queue "redis://redis-queue:6379";
        bench set-config -g redis_socketio "redis://redis-socketio:6379";
        bench set-config -g root_login root;
        bench set-config -g root_password "\$\${MARIADB_ROOT_PASS}";
    environment:
      - MARIADB_ROOT_PASS=\${MARIADB_ROOT_PASS}
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs

  frontend:
    build: .
    restart: on-failure
    command: [ "nginx-entrypoint.sh" ]
    environment:
      - BACKEND=backend:8000
      - FRAPPE_SITE_NAME_HEADER=\$\$host
      - SOCKETIO=websocket:9000
      - UPSTREAM_REAL_IP_ADDRESS=127.0.0.1
      - UPSTREAM_REAL_IP_HEADER=X-Forwarded-For
      - UPSTREAM_REAL_IP_RECURSIVE=off
    ports:
      - "80:8080"
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs

  websocket:
    build: .
    restart: on-failure
    command: [ "node", "/home/frappe/frappe-bench/apps/frappe/socketio.js" ]
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs

  db:
    image: mariadb:10.6
    restart: on-failure
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --skip-character-set-client-handshake
      - --skip-innodb-read-only-compressed
    environment:
      - MYSQL_ROOT_PASSWORD=\${MARIADB_ROOT_PASS}
    volumes:
      - db-data:/var/lib/mysql

  redis-cache:
    image: redis:7-alpine
    restart: on-failure
  redis-queue:
    image: redis:7-alpine
    restart: on-failure
  redis-socketio:
    image: redis:7-alpine
    restart: on-failure

  queue-default:
    build: .
    restart: on-failure
    command: [ "bench", "worker", "--queue", "default" ]
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs

  queue-short:
    build: .
    restart: on-failure
    command: [ "bench", "worker", "--queue", "short" ]
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs

  queue-long:
    build: .
    restart: on-failure
    command: [ "bench", "worker", "--queue", "long" ]
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs

  scheduler:
    build: .
    restart: on-failure
    command: [ "bench", "schedule" ]
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs

volumes:
  db-data:
  sites:
  logs:
EOF

# 9. Build and Launch
echo -e "${BLUE}➡️ Building Custom Image (Injecting Marley into ERPNext)...${NC}"
docker compose build

echo -e "${BLUE}➡️ Starting Database and Redis...${NC}"
docker compose up -d db redis-cache redis-queue redis-socketio

echo -e "${BLUE}➡️ Waiting 15 seconds for Database to initialize...${NC}"
sleep 15

echo -e "${BLUE}➡️ Configuring Bench Environment inside Docker...${NC}"
docker compose run --rm configurator

echo -e "${BLUE}➡️ Starting Frappe Web & Worker Containers...${NC}"
docker compose up -d

# 10. Site Initialization
echo -e "${BLUE}➡️ Creating Site: ${SITE_NAME}...${NC}"
# Use grep to check if the site folder already exists inside the container's volume
if ! docker compose exec backend ls -1 sites | grep -q "^${SITE_NAME}$"; then
    docker compose exec backend bench new-site ${SITE_NAME} \
        --mariadb-root-password "${MARIADB_ROOT_PASS}" \
        --admin-password "${ADMIN_PASS}"
        
    echo -e "${BLUE}➡️ Installing ERPNext to site...${NC}"
    docker compose exec backend bench --site ${SITE_NAME} install-app erpnext

    echo -e "${BLUE}➡️ Installing Marley Health to site...${NC}"
    docker compose exec backend bench --site ${SITE_NAME} install-app marley
    
    echo -e "${BLUE}➡️ Setting default site routing...${NC}"
    docker compose exec backend bench use ${SITE_NAME}
else
    echo -e "${BLUE}➡️ Site ${SITE_NAME} already exists in volumes. Skipping site creation.${NC}"
fi

echo -e "${BLUE}======================================================================${NC}"
echo -e "${GREEN}✅ Docker Installation Successfully Completed!${NC}"
echo -e "You can now access your system via a web browser."
echo -e ""
echo -e "🔗 ${GREEN}URL:${NC}        http://${SITE_NAME} (Or your server's Public IP)"
echo -e "👤 ${GREEN}Username:${NC}   Administrator"
echo -e "🔑 ${GREEN}Password:${NC}   ${ADMIN_PASS}"
echo -e ""
echo -e "🛠  ${BLUE}To manage your containers, use the following commands:${NC}"
echo -e "   cd /opt/marley-health"
echo -e "   docker compose ps         # View running services"
echo -e "   docker compose logs -f    # View live system logs"
echo -e "${BLUE}======================================================================${NC}"
