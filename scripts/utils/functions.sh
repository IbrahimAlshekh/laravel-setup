#!/bin/bash

# Utility functions for Laravel server setup scripts

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}"
}

print_information(){
      echo -e "${GREEN}================================${NC}"
      echo -e "${GREEN}$1${NC}"
      echo -e "${GREEN}================================${NC}"
}

# Function to check if script is run as root
check_not_root() {
    if [[ $EUID -eq 0 ]]; then
        print_error "This script should not be run as root for security reasons"
        print_warning "Please create a regular user first:"
        print_warning "  adduser username"
        print_warning "  usermod -aG sudo username"
        print_warning "  su - username"
        print_warning "Then run this script as that user"
        exit 1
    fi
}

# Function to check if user has sudo privileges
check_sudo_privileges() {
    if ! sudo -n true 2>/dev/null; then
        print_error "This user doesn't have sudo privileges"
        print_warning "Please add this user to the sudo group:"
        print_warning "  sudo usermod -aG sudo $USER"
        exit 1
    fi
}