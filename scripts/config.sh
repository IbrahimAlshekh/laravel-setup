#!/bin/bash

# Configuration variables for Laravel server setup
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