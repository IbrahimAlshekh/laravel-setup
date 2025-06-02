#!/bin/bash

# Laravel application setup script

# Source utility functions and configuration
source "$(dirname "$0")/utils/functions.sh"
source "$(dirname "$0")/config.sh"

# Check if running as root and if user has sudo privileges
check_not_root
check_sudo_privileges

print_header "Setting Up Laravel Application"

# Configure Git and SSH for deployment
print_header "Configuring Git for Deployment"
print_status "Setting up SSH for Git..."

# Create SSH directory if it doesn't exist
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Add GitHub to known hosts
ssh-keyscan -H github.com >> ~/.ssh/known_hosts

print_warning "Please add your SSH public key to GitHub before proceeding"
print_warning "If you haven't generated SSH keys yet, run: ssh-keygen -t ed25519 -C 'your-email@example.com'"
print_warning "Then add the public key (~/.ssh/id_ed25519.pub) to your GitHub account"
read -p "Press Enter when you've added your SSH key to GitHub..."

# Clone the repository
print_header "Cloning Laravel Repository"
print_status "Cloning repository to $WEB_ROOT..."

# Remove existing directory if it exists
if [ -d "$WEB_ROOT" ]; then
    print_warning "Directory $WEB_ROOT already exists. Removing..."
    sudo rm -rf $WEB_ROOT
fi

# Clone the repository
print_status "Enter the Git repository URL for your Laravel project:"
read -p "Repository URL: " REPO_URL

if [ -z "$REPO_URL" ]; then
    print_error "Repository URL cannot be empty"
    exit 1
fi

sudo git clone $REPO_URL $WEB_ROOT
if [ $? -ne 0 ]; then
    print_error "Failed to clone repository"
    exit 1
fi

# Set proper ownership and permissions
print_status "Setting proper ownership and permissions..."
sudo chown -R $USER:$WEB_USER $WEB_ROOT
sudo chmod -R 755 $WEB_ROOT
sudo chmod -R 775 $WEB_ROOT/storage
sudo mkdir -p $WEB_ROOT/bootstrap/cache
sudo chmod -R 775 $WEB_ROOT/bootstrap/cache

# Install Composer dependencies
print_header "Installing Composer Dependencies"
print_status "Installing Composer dependencies..."

cd $WEB_ROOT
composer install --no-dev --optimize-autoloader

if [ $? -ne 0 ]; then
    print_error "Failed to install Composer dependencies"
    exit 1
fi

# Configure Laravel environment
print_header "Configuring Laravel Environment"
print_status "Setting up .env file..."

if [ -f ".env.example" ]; then
    cp .env.example .env
else
    print_warning "No .env.example file found. Creating empty .env file..."
    touch .env
fi

# Update .env file with database credentials
sed -i "s/DB_DATABASE=laravel/DB_DATABASE=$DB_NAME/" .env
sed -i "s/DB_USERNAME=root/DB_USERNAME=$DB_USER/" .env
sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=\"$DB_PASSWORD\"|" .env
sed -i "s/CACHE_DRIVER=file/CACHE_DRIVER=redis/" .env
sed -i "s/SESSION_DRIVER=file/SESSION_DRIVER=redis/" .env
sed -i "s/QUEUE_CONNECTION=sync/QUEUE_CONNECTION=redis/" .env

# Generate application key
print_status "Generating application key..."
php artisan key:generate

# Run migrations
print_status "Running database migrations..."
php artisan migrate --force

# Configure Supervisor for Laravel Queue
print_header "Configuring Supervisor for Laravel Queue"
print_status "Setting up Supervisor for Laravel queue workers..."

cat << EOF | sudo tee /etc/supervisor/conf.d/laravel-worker.conf
[program:laravel-worker]
process_name=%(program_name)s_%(process_num)02d
command=php $WEB_ROOT/artisan queue:work --sleep=3 --tries=3 --max-time=3600
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=$WEB_USER
numprocs=2
redirect_stderr=true
stdout_logfile=$WEB_ROOT/storage/logs/worker.log
stopwaitsecs=3600
EOF

sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl start laravel-worker:*

print_header "Laravel Application Setup Complete"
print_status "Laravel application has been set up successfully at $WEB_ROOT"
print_status "You can now access your application at http://$DOMAIN"
print_warning "Remember to set up SSL certificate for HTTPS access"