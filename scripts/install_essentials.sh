#!/bin/bash

# Essential packages installation script for Laravel server setup
print_header "Installing Essential Packages"
print_status "Installing essential system packages..."

# Install essential packages
sudo apt install -y \
    curl \
    wget \
    git \
    unzip \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    ufw \
    fail2ban \
    htop \
    tree \
    vim \
    supervisor \
    redis-server \
    certbot \
    python3-certbot-nginx

if [ $? -eq 0 ]; then
    print_status "Essential packages installed successfully"
else
    print_error "Failed to install essential packages"
    exit 1
fi

# Install Composer
print_header "Installing Composer"
print_status "Downloading and installing Composer..."

curl -sS https://getcomposer.org/installer | php
sudo mv composer.phar /usr/local/bin/composer
sudo chmod +x /usr/local/bin/composer

if [ $? -eq 0 ]; then
    print_status "Composer installed successfully"
else
    print_error "Failed to install Composer"
    exit 1
fi

# Install Node.js and npm
print_header "Installing Node.js and npm"
print_status "Adding Node.js repository and installing Node.js..."

curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs

if [ $? -eq 0 ]; then
    print_status "Node.js and npm installed successfully"
    print_status "Node.js version: $(node -v)"
    print_status "npm version: $(npm -v)"
else
    print_error "Failed to install Node.js and npm"
    exit 1
fi