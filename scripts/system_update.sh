#!/bin/bash

# System update script for Laravel server setup
load_scripts
print_header "System Update"
print_status "Updating system packages..."

# Update package lists and upgrade installed packages
sudo apt update && sudo apt upgrade -y

if [ $? -eq 0 ]; then
    print_status "System update completed successfully"
else
    print_error "System update failed"
    exit 1
fi