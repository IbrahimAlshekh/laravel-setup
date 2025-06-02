#!/bin/bash

# Configuration variables for Laravel server setup

# Domain and application settings
DOMAIN="example.com"
DB_NAME="production_db"
DB_USER="db_user"
WEB_USER="www-data"

# Security settings
SSH_PORT="2222"  # Change default SSH port for security

# Path settings
WEB_ROOT="/var/www/$DOMAIN"