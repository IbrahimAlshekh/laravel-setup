#!/bin/bash

# Services configuration script for Laravel server setup
print_header "Configuring and Starting Services"

# Enable and start Nginx
print_status "Enabling and starting Nginx..."
sudo systemctl enable nginx
sudo systemctl restart nginx

if [ $? -ne 0 ]; then
    print_error "Failed to start Nginx"
    exit 1
fi

# Enable and start PHP-FPM
print_status "Enabling and starting PHP-FPM..."
sudo systemctl enable php8.3-fpm
sudo systemctl restart php8.3-fpm

if [ $? -ne 0 ]; then
    print_error "Failed to start PHP-FPM"
    exit 1
fi

# Enable and start MySQL
print_status "Enabling and starting MySQL..."
sudo systemctl enable mysql
sudo systemctl restart mysql

if [ $? -ne 0 ]; then
    print_error "Failed to start MySQL"
    exit 1
fi

# Enable and start Redis
print_status "Enabling and starting Redis..."
sudo systemctl enable redis-server
sudo systemctl restart redis-server

if [ $? -ne 0 ]; then
    print_error "Failed to start Redis"
    exit 1
fi

# Enable and start Supervisor
print_status "Enabling and starting Supervisor..."
sudo systemctl enable supervisor
sudo systemctl restart supervisor

if [ $? -ne 0 ]; then
    print_error "Failed to start Supervisor"
    exit 1
fi

# Setup SSL certificate
print_header "Setting up SSL Certificate"
print_warning "Make sure your domain DNS is pointing to this server before running SSL setup"
read -p "Do you want to setup SSL certificate now? (y/n): " setup_ssl

if [[ $setup_ssl == "y" || $setup_ssl == "Y" ]]; then
    sudo certbot --nginx -d $DOMAIN -d www.$DOMAIN
    
    if [ $? -eq 0 ]; then
        print_status "SSL certificate installed successfully"
        
        # Setup auto-renewal
        echo "0 12 * * * /usr/bin/certbot renew --quiet" | sudo crontab -
        print_status "SSL auto-renewal configured"
    else
        print_error "Failed to install SSL certificate"
        print_warning "You can try again later with: sudo certbot --nginx -d $DOMAIN -d www.$DOMAIN"
    fi
else
    print_warning "SSL certificate setup skipped"
    print_warning "You can set it up later with: sudo certbot --nginx -d $DOMAIN -d www.$DOMAIN"
fi

# Create server information file
print_header "Creating Server Information File"
print_status "Saving server information to file..."

cat << EOF > /home/$USER/server_info.txt
===========================================
Laravel Production Server Setup Complete
===========================================

Domain: $DOMAIN
Web Directory: $WEB_ROOT

Database Information:
- Database Name: $DB_NAME
- Database User: $DB_USER
- Database Password: See mysql_credentials.txt file

Important Security Notes:
- SSH Port changed to: $SSH_PORT
- Firewall (UFW) is enabled
- Fail2ban is configured

Service Status Commands:
- sudo systemctl status nginx
- sudo systemctl status php8.3-fpm
- sudo systemctl status mysql
- sudo systemctl status redis-server
- sudo systemctl status supervisor

Log Locations:
- Nginx: /var/log/nginx/
- PHP-FPM: /var/log/php8.3-fpm.log
- MySQL: /var/log/mysql/
- Laravel: $WEB_ROOT/storage/logs/

Security Tools:
- UFW Firewall: sudo ufw status
- Fail2ban: sudo fail2ban-client status

SSH Connection (remember the new port):
ssh -p $SSH_PORT $USER@your-server-ip
EOF

chmod 600 /home/$USER/server_info.txt

print_header "Services Configuration Complete"
print_status "All services have been configured and started"
print_status "Server information saved to: /home/$USER/server_info.txt"