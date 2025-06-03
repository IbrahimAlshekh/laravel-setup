#!/bin/bash

# Configuration variables for Laravel server setup

# Source utility functions and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/scripts/utils/functions.sh"

# Check if running as root and if user has sudo privileges
check_not_root
check_sudo_privileges

# Domain and application settings
if [[ -z "$DOMAIN" ]]; then
  print_status "Enter the Domain for your Laravel project:"
  read -p "Domain: " DOMAIN
fi

if [[ -z "$REPO_URL" ]]; then
  print_status "Enter the Git repository URL for your Laravel project:"
  read -p "Repository URL: " REPO_URL
fi

if [[ -z "$DB_PASSWORD" || -z "$DB_ROOT_PASSWORD" ]]; then
  DB_PASSWORD="$(openssl rand -base64 16)"
  DB_ROOT_PASSWORD="$(openssl rand -base64 16)"
fi

DB_NAME="production_db"
DB_USER="db_user"
WEB_USER="www-data"

# Security settings
SSH_PORT="2222"  # Change default SSH port for security

# Path settings
WEB_ROOT="/var/www/$DOMAIN"