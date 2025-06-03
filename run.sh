#!/bin/bash

# Laravel Production Server Setup Script for Ubuntu 24.04
# Main script that orchestrates the entire setup process

set -e  # Exit on any error

# Define script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/bootstrap.sh"

# Print welcome message
print_header "Laravel Production Server Setup"
print_status "Setting up server for domain: $DOMAIN"
print_status "Running as user: $USER"

# Check if running as root and if user has sudo privileges
check_not_root
check_sudo_privileges

# Function to run a script and check its exit status
run_script() {
    local script_name="$1"
    local script_path="$SCRIPT_DIR/scripts/$script_name"
    
    print_header "Running $script_name"
    
    if [ -f "$script_path" ]; then
        chmod +x "$script_path"
        "$script_path"
        
        if [ $? -ne 0 ]; then
            print_error "Script $script_name failed"
            exit 1
        fi
    else
        print_error "Script $script_name not found at $script_path"
        exit 1
    fi
}

# Main setup process
print_header "Starting Laravel Server Setup Process"
print_status "This script will set up a complete Laravel production server"
print_status "The setup process is divided into several steps:"
print_status "1. System update"
print_status "2. Installing essential packages"
print_status "3. Installing PHP 8.3 and extensions"
print_status "4. Installing and configuring MySQL"
print_status "5. Installing and configuring Nginx"
print_status "6. Configuring security (firewall, fail2ban, SSH)"
print_status "7. Setting up Laravel application"
print_status "8. Configuring and starting services"
print_status ""
print_warning "This process may take some time. Please be patient."
print_warning "You will be prompted for input at certain stages."
print_status ""
read -p "Press Enter to begin the setup process..."

# Run each script in sequence
run_script "system_update.sh"
run_script "install_essentials.sh"
run_script "install_php.sh"
run_script "install_mysql.sh"
run_script "install_nginx.sh"
run_script "configure_security.sh"
run_script "setup_laravel.sh"
run_script "configure_services.sh"

# Final message
print_header "Setup Complete!"
print_status "Laravel production server has been successfully set up"
print_status "Server information has been saved to: /home/$USER/server_info.txt"
print_status "MySQL credentials have been saved to: /home/$USER/mysql_credentials.txt"
print_warning "Remember to:"
print_warning "1. Point your domain DNS to this server"
print_warning "2. Set up SSL certificate if you haven't already"
print_warning "3. Change SSH port in your SSH client to: $SSH_PORT"

echo -e "${GREEN}Your Laravel production server is ready!${NC}"