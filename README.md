Marley Health Deployment (Frappe v16)

This repository contains the files needed to automate a complete, production-ready installation of Frappe v16, ERPNext, and the Marley Health module. It is designed specifically for Ubuntu servers and handles all system dependencies smoothly.

Prerequisites

OS: A fresh Ubuntu 22.04 LTS or 24.04 LTS server.

Resources: Minimum 2 CPU Cores, 4GB RAM (the script automatically creates a 2GB swap file to assist smaller servers).

Access: Root access (or a user with full sudo privileges). 

How to Install

Clone this repository to your Ubuntu server:

git clone git@github.com:mbyo2/testmarley.git
cd testmarley


Configure your settings:
Open config.env using nano or your preferred text editor and update the default passwords and your domain name:

nano config.env


Note: If you do not have a live domain name yet, you can leave SITE_NAME=marley.local and access the server using your server's Public IP address.

Make the script executable:

chmod +x install.sh


Run the installation command:

sudo ./install.sh


Grab a cup of coffee. The script will take about 10–15 minutes to configure MariaDB, Redis, install Python, Node, Yarn, compile the assets, and finalize the web server configurations.

Post-Installation

Once the script finishes, it will print out your Administrator login details.

Log in to your instance via your browser.

Search for the Healthcare Settings and Medical Departments to begin tailoring the system for your Diagnostic Center and Dental Hospital.

Setting up SSL (HTTPS)

If you set your SITE_NAME to a real domain (e.g., health.mydomain.com) and have pointed your DNS A-records to this server's IP address, you can generate a free SSL certificate by running:

su - frappe
cd frappe-bench
sudo bench setup lets-encrypt <your-site-name>
