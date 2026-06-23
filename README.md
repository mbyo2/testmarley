Marley Health Deployment (Frappe v16)

This repository contains the files needed to automate a complete, production-ready installation of Frappe v16, ERPNext, and the Marley Health module. It is designed specifically for Ubuntu servers and handles all system dependencies smoothly.

Out-of-the-Box IP Access (No Domain Required)

This setup is configured to work immediately on any server using just the public IP address. You do not need a registered domain name (URL) to install, test, or use the system.

Prerequisites

OS: A fresh Ubuntu 22.04 LTS or 24.04 LTS server.

Resources: Minimum 2 CPU Cores, 4GB RAM (the script automatically creates a 2GB swap file to assist smaller servers).

Access: Root access (or a user with full sudo privileges).

How to Install

Clone this repository to your Ubuntu server:

git clone git@github.com:mbyo2/testmarley.git
cd testmarley


Configure your settings:
Open config.env using nano or your preferred text editor. You can update the default passwords. You can leave SITE_NAME=marley.local exactly as it is—the script automatically sets it as the default site so your IP address routes to it correctly.

nano config.env


Make the script executable:

chmod +x install.sh


Run the installation command:

sudo ./install.sh


Grab a cup of coffee. The script will take about 10–15 minutes to configure MariaDB, Redis, install Python, Node, Yarn, compile the assets, and finalize the web server configurations.

Post-Installation

Once the script finishes, it will print out your Administrator login details.

Open your web browser and type in your Server's Public IP Address (e.g., http://192.168.1.50 or http://104.25.x.x).

Log in using the Administrator credentials.

Search for the Healthcare Settings and Medical Departments to begin tailoring the system for your Diagnostic Center and Dental Hospital.

Adding a Domain and SSL (Later)

When you are ready to use a real URL (e.g., health.mydomain.com), you can easily add it later:

Point your domain's DNS A-record to your server's IP address.

Run these commands to add the domain and secure it with a free SSL certificate:

su - frappe
cd frappe-bench
bench setup add-domain <your-new-domain.com> --site marley.local
sudo bench setup lets-encrypt marley.local --custom-domain <your-new-domain.com>
