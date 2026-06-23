#!/bin/bash
# ==============================================================================
# Marley Health (Frappe v16) Automated Installer for Ubuntu 22.04 / 24.04
# ==============================================================================
set -e

# Colors for console output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================================================${NC}"
echo -e "${GREEN}  Starting Automated Setup for Frappe v16 + ERPNext + Marley Health  ${NC}"
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

# 2. Prevent UI prompts during package installation
export DEBIAN_FRONTEND=noninteractive

# 3. Swap Check (Prevents Out-Of-Memory crashes during yarn build on small servers)
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
SWAP_MEM=$(free -m | awk '/^Swap:/{print $2}')
if [ "$TOTAL_MEM" -lt 3000 ] && [ "$SWAP_MEM" -eq 0 ]; then
    echo -e "${BLUE}➡️ Memory is below 3GB. Creating 2GB swap file to prevent build crashes...${NC}"
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 4. System Update & Dependencies
echo -e "${BLUE}➡️ Updating system packages...${NC}"
apt-get update -q && apt-get upgrade -yq

echo -e "${BLUE}➡️ Installing system prerequisites (Git, Curl, Wget, GCC, etc)...${NC}"
apt-get install -yq curl git wget xvfb libfontconfig cron build-essential gcc software-properties-common pkg-config
apt-get install -yq mariadb-server mariadb-client libmariadb-dev redis-server
apt-get install -yq supervisor nginx certbot python3-certbot-nginx
apt-get install -yq python3-dev python3-pip python3-venv python3-setuptools pipx

# 5. Database Configuration (MariaDB)
echo -e "${BLUE}➡️ Configuring MariaDB for Frappe...${NC}"
cat > /etc/mysql/mariadb.conf.d/frappe.cnf <<EOF
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF

systemctl restart mariadb
systemctl enable mariadb

echo -e "${BLUE}➡️ Setting MariaDB Root Password...${NC}"
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MARIADB_ROOT_PASS}';" || true
mysql -u root -p"${MARIADB_ROOT_PASS}" -e "FLUSH PRIVILEGES;" || true

# 6. Node.js & Yarn
echo -e "${BLUE}➡️ Installing Node.js (v20 LTS) & Yarn...${NC}"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -yq nodejs
npm install -g yarn

# 7. wkhtmltopdf (For PDF Generation)
echo -e "${BLUE}➡️ Installing wkhtmltopdf...${NC}"
wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
apt-get install -yq ./wkhtmltox_0.12.6.1-2.jammy_amd64.deb || true
rm wkhtmltox_0.12.6.1-2.jammy_amd64.deb

# 8. User Setup
echo -e "${BLUE}➡️ Setting up Frappe system user...${NC}"
if ! id "$FRAPPE_USER" &>/dev/null; then
    useradd -m -s /bin/bash $FRAPPE_USER
    usermod -aG sudo $FRAPPE_USER
    # Allow frappe user to run sudo without password for production setup
    echo "$FRAPPE_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$FRAPPE_USER
fi

# 9. Frappe Bench Installation
echo -e "${BLUE}➡️ Installing Frappe Bench CLI...${NC}"
su - $FRAPPE_USER -c "pipx ensurepath"
su - $FRAPPE_USER -c "pipx install frappe-bench"

# Symlink bench globally to avoid PATH issues in the script
ln -sf /home/$FRAPPE_USER/.local/bin/bench /usr/local/bin/bench

echo -e "${BLUE}➡️ Initializing Frappe Bench Environment (Branch: ${FRAPPE_BRANCH})...${NC}"
su - $FRAPPE_USER -c "bench init frappe-bench --frappe-branch ${FRAPPE_BRANCH}"

# 10. Fetching Apps
echo -e "${BLUE}➡️ Fetching ERPNext...${NC}"
su - $FRAPPE_USER -c "cd frappe-bench && bench get-app --branch ${FRAPPE_BRANCH} erpnext"

echo -e "${BLUE}➡️ Fetching Marley Health...${NC}"
su - $FRAPPE_USER -c "cd frappe-bench && bench get-app https://github.com/earthians/marley.git"

# 11. Creating the Site
echo -e "${BLUE}➡️ Creating Site: ${SITE_NAME}...${NC}"
su - $FRAPPE_USER -c "cd frappe-bench && bench new-site ${SITE_NAME} --mariadb-root-password '${MARIADB_ROOT_PASS}' --admin-password '${ADMIN_PASS}'"

# 12. Installing Apps to Site
echo -e "${BLUE}➡️ Installing ERPNext to site...${NC}"
su - $FRAPPE_USER -c "cd frappe-bench && bench --site ${SITE_NAME} install-app erpnext"

echo -e "${BLUE}➡️ Installing Marley Health to site...${NC}"
# The app folder is dynamically checked to ensure compatibility with recent repo renames
su - $FRAPPE_USER -c "cd frappe-bench && if [ -d apps/marley ]; then bench --site ${SITE_NAME} install-app marley; else bench --site ${SITE_NAME} install-app healthcare; fi"

# 13. Production Setup
echo -e "${BLUE}➡️ Configuring NGINX and Supervisor for Production...${NC}"
su - $FRAPPE_USER -c "cd frappe-bench && bench use ${SITE_NAME}"
su - $FRAPPE_USER -c "cd frappe-bench && sudo bench setup production ${FRAPPE_USER}"
su - $FRAPPE_USER -c "cd frappe-bench && bench --site ${SITE_NAME} enable-scheduler"

# Ensure services are active
systemctl restart supervisor
systemctl restart nginx

echo -e "${BLUE}======================================================================${NC}"
echo -e "${GREEN}✅ Installation Successfully Completed!${NC}"
echo -e "You can now access your system via a web browser."
echo -e ""
echo -e "🔗 ${GREEN}URL:${NC}        http://${SITE_NAME} (Or your server's Public IP)"
echo -e "👤 ${GREEN}Username:${NC}   Administrator"
echo -e "🔑 ${GREEN}Password:${NC}   ${ADMIN_PASS}"
echo -e "${BLUE}======================================================================${NC}"
