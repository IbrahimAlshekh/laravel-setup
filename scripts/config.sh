#!/bin/bash

# Configuration variables for Laravel server setup
# Domain and application settings
print_status "Enter the Domain for your Laravel project:"
read -pr "Domain: " DOMAIN
print_status "Enter the Git repository URL for your Laravel project:"
read -pr "Repository URL: " REPO_URL
DB_NAME="production_db"
DB_USER="db_user"
DB_PASSWORD="$(openssl rand -base64 16)"
DB_DB_ROOT_PASSWORD="$(openssl rand -base64 16)"
WEB_USER="www-data"

# Security settings
SSH_PORT="2222"  # Change default SSH port for security

# Path settings
WEB_ROOT="/var/www/$DOMAIN"