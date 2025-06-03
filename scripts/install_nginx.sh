#!/bin/bash

# Nginx installation and configuration script for Laravel server setup
print_header "Installing Nginx"
print_status "Installing Nginx web server..."

# Install Nginx
sudo apt install -y nginx

if [ $? -ne 0 ]; then
    print_error "Failed to install Nginx"
    exit 1
fi

print_status "Nginx installed successfully"

# Configure Nginx for Laravel
print_header "Configuring Nginx for Laravel"
print_status "Setting up Nginx configuration for domain: $DOMAIN"

# Add rate limiting zones to nginx.conf
if ! grep -q "limit_req_zone" /etc/nginx/nginx.conf; then
    sudo sed -i '/http {/a\\n    # Rate limiting zones\n    limit_req_zone $binary_remote_addr zone=login:10m rate=10r/m;\n    limit_req_zone $binary_remote_addr zone=api:10m rate=100r/m;' /etc/nginx/nginx.conf
fi

# Create the site configuration
cat << EOF | sudo tee /etc/nginx/sites-available/$DOMAIN
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    root $WEB_ROOT/public;
    index index.php index.html index.htm;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;

    # Hide Nginx version
    server_tokens off;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/javascript
        application/xml+rss
        application/json;

    # Main location block
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # PHP processing
    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }

    # Static files
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # Rate limiting for login
    location /login {
        limit_req zone=login burst=5 nodelay;
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # Rate limiting for API
    location /api {
        limit_req zone=api burst=20 nodelay;
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # Security: deny access to hidden files
    location ~ /\. {
        deny all;
    }
}
EOF

# Enable the site
sudo ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Test Nginx configuration
print_status "Testing Nginx configuration..."
if sudo nginx -t; then
    print_status "Nginx configuration is valid"
    sudo systemctl restart nginx
else
    print_error "Nginx configuration test failed"
    exit 1
fi

# Create web directory if it doesn't exist
print_status "Setting up web directory..."
sudo mkdir -p $WEB_ROOT
sudo chown -R $USER:$WEB_USER $WEB_ROOT
sudo chmod -R 755 $WEB_ROOT

print_status "Nginx configured successfully for $DOMAIN"