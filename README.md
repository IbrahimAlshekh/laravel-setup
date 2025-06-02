# Laravel Server Setup Scripts

A collection of shell scripts to prepare and set up a fresh Ubuntu server for Laravel deployment with MySQL and security configurations.

## Overview

This project provides a modular approach to setting up a production-ready Laravel server on Ubuntu. Instead of a single monolithic script, it's divided into smaller, focused scripts that handle specific aspects of the setup process. This makes the project more maintainable and easier to customize.

## Features

- System updates and essential packages installation
- PHP 8.3 with all necessary extensions for Laravel
- MySQL 8.0 database server with secure configuration
- Nginx web server with optimized settings for Laravel
- Security hardening (firewall, fail2ban, SSH configuration)
- Laravel application setup and deployment
- Service configuration and management
- SSL certificate setup with Let's Encrypt

## Directory Structure

```
laravel-setup/
├── run.sh                  # Main script that orchestrates the entire setup
├── scripts/
│   ├── config.sh           # Configuration variables
│   ├── system_update.sh    # System update script
│   ├── install_essentials.sh # Essential packages installation
│   ├── install_php.sh      # PHP installation and configuration
│   ├── install_mysql.sh    # MySQL installation and configuration
│   ├── install_nginx.sh    # Nginx installation and configuration
│   ├── configure_security.sh # Security configuration
│   ├── setup_laravel.sh    # Laravel application setup
│   ├── configure_services.sh # Service configuration and startup
│   └── utils/
│       └── functions.sh    # Utility functions used by all scripts
```

## Usage

1. Clone this repository to your Ubuntu server:
   ```
   git clone https://github.com/IbrahimAlshekh/laravel-setup.git
   cd laravel-setup
   ```

2. Make the main script executable:
   ```
   chmod +x run.sh
   ```

3. Review and modify the configuration in `scripts/config.sh` to match your requirements:
   ```
   nano scripts/config.sh
   ```

4. Run the setup script:
   ```
   ./run.sh
   ```

5. Follow the prompts during the installation process.

## Script Descriptions

- **run.sh**: The main script that orchestrates the entire setup process.
- **config.sh**: Contains all configuration variables used throughout the scripts.
- **system_update.sh**: Updates the system packages.
- **install_essentials.sh**: Installs essential packages, Composer, and Node.js.
- **install_php.sh**: Installs PHP 8.3 and all required extensions for Laravel.
- **install_mysql.sh**: Installs and configures MySQL for Laravel.
- **install_nginx.sh**: Installs and configures Nginx for Laravel.
- **configure_security.sh**: Configures firewall, fail2ban, and SSH security.
- **setup_laravel.sh**: Sets up the Laravel application.
- **configure_services.sh**: Configures and starts all services.

## Customization

You can customize the setup by:

1. Modifying the configuration variables in `scripts/config.sh`
2. Editing individual scripts to add or remove specific functionality
3. Adding new scripts for additional components

## Requirements

- Ubuntu 24.04 (may work on other Ubuntu versions with minor modifications)
- A non-root user with sudo privileges
- Internet connection

## Security Notes

- The script changes the default SSH port for better security
- Root login is disabled
- UFW firewall is configured to allow only necessary ports
- Fail2ban is set up to prevent brute force attacks

## License

This project is open-source and available under the MIT License.