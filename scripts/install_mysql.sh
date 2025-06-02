#!/bin/bash

# MySQL installation and configuration script for Laravel server setup

# Source utility functions and configuration
source "$(dirname "$0")/utils/functions.sh"
source "$(dirname "$0")/config.sh"

# Check if running as root and if user has sudo privileges
check_not_root
check_sudo_privileges

print_header "Installing MySQL 8.0"
print_status "Installing MySQL server and client..."

# Install MySQL
sudo apt install -y mysql-server mysql-client

if [ $? -ne 0 ]; then
    print_error "Failed to install MySQL"
    exit 1
fi

print_status "MySQL installed successfully"

# Secure MySQL installation
print_header "Securing MySQL Installation"
print_warning "Please set a strong root password when prompted"
sudo mysql_secure_installation

# Configure MySQL for Laravel
print_header "Configuring MySQL for Laravel"
print_status "Configuring MySQL database and user..."
print_status "Creating database: $DB_NAME"
print_status "Creating user: $DB_USER"

# Configure MySQL using sudo (auth_socket)
sudo mysql << EOF
-- Create database
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Create Laravel user
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';

-- Create admin user for easier management
CREATE USER IF NOT EXISTS 'admin'@'localhost' IDENTIFIED BY '$DB_ROOT_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'localhost' WITH GRANT OPTION;

-- Secure the installation
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

-- Flush privileges
FLUSH PRIVILEGES;
EOF

if [ $? -eq 0 ]; then
    print_status "MySQL configured successfully"

    # Save credentials securely
    cat << EOF >> /home/$USER/mysql_credentials.txt
MySQL Credentials:
==================
Laravel Database: $DB_NAME
Laravel User: $DB_USER
Laravel Password: $DB_PASSWORD

Admin User: admin
Admin Password: $DB_ROOT_PASSWORD

Connection Examples:
mysql -u $DB_USER -p$DB_PASSWORD $DB_NAME
mysql -u admin -p$DB_ROOT_PASSWORD
EOF

    chmod 600 /home/$USER/mysql_credentials.txt
    print_status "MySQL credentials saved to ~/mysql_credentials.txt"
else
    print_error "Failed to configure MySQL"
    exit 1
fi

# Configure Redis (often used with MySQL for caching)
print_header "Configuring Redis"
print_status "Optimizing Redis configuration..."

sudo sed -i 's/# maxmemory <bytes>/maxmemory 256mb/' /etc/redis/redis.conf
sudo sed -i 's/# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
sudo systemctl enable redis-server
sudo systemctl restart redis-server

if [ $? -eq 0 ]; then
    print_status "Redis configured successfully"
else
    print_error "Failed to configure Redis"
    exit 1
fi