#!/bin/bash

# System update script for Laravel server setup

# Source utility functions and configuration
source "$(dirname "$0")/utils/functions.sh"
source "$(dirname "$0")/config.sh"

# Check if running as root and if user has sudo privileges
check_not_root
check_sudo_privileges

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