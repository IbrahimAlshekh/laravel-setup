#!/bin/bash

# PHP installation script for Laravel server setup
load_scripts
print_header "Installing PHP 8.3 and Extensions"
print_status "Adding PHP repository and installing PHP 8.3 with extensions..."

# Add PHP repository
sudo add-apt-repository ppa:ondrej/php -y
sudo apt update

# Install PHP and extensions
sudo apt install -y \
    php8.3 \
    php8.3-fpm \
    php8.3-mysql \
    php8.3-mbstring \
    php8.3-xml \
    php8.3-bcmath \
    php8.3-curl \
    php8.3-gd \
    php8.3-zip \
    php8.3-intl \
    php8.3-soap \
    php8.3-redis \
    php8.3-imagick \
    php8.3-cli \
    php8.3-common \
    php8.3-opcache

if [ $? -eq 0 ]; then
    print_status "PHP 8.3 and extensions installed successfully"
else
    print_error "Failed to install PHP 8.3 and extensions"
    exit 1
fi

# Configure PHP-FPM
print_header "Configuring PHP-FPM"
print_status "Optimizing PHP configuration for Laravel..."

# Adjust PHP settings for Laravel
sudo sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/' /etc/php/8.3/fpm/php.ini
sudo sed -i 's/upload_max_filesize = 2M/upload_max_filesize = 64M/' /etc/php/8.3/fpm/php.ini
sudo sed -i 's/post_max_size = 8M/post_max_size = 64M/' /etc/php/8.3/fpm/php.ini
sudo sed -i 's/max_execution_time = 30/max_execution_time = 300/' /etc/php/8.3/fpm/php.ini
sudo sed -i 's/memory_limit = 128M/memory_limit = 512M/' /etc/php/8.3/fpm/php.ini

# Configure OPcache for better performance
print_status "Configuring OPcache for better performance..."

cat << EOF | sudo tee -a /etc/php/8.3/fpm/conf.d/10-opcache.ini
opcache.enable=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=4000
opcache.revalidate_freq=2
opcache.fast_shutdown=1
opcache.enable_cli=1
opcache.validate_timestamps=0
EOF

# Restart PHP-FPM to apply changes
sudo systemctl restart php8.3-fpm

if [ $? -eq 0 ]; then
    print_status "PHP-FPM configured successfully"
    php -v
else
    print_error "Failed to configure PHP-FPM"
    exit 1
fi