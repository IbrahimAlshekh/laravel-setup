#!/bin/bash

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Importiere die Funktionen, falls noch nicht geschehen
if [[ "$(type -t print_status)" != "function" ]]; then
  source "$SCRIPT_ROOT/utils/functions.sh"
fi

# Importiere die Konfiguration, falls noch nicht geschehen
if [[ -z "$WEB_ROOT" ]]; then

  if [[ -z "$GREEN" ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
  fi

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
fi
