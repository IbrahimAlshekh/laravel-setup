#!/bin/bash

# Security configuration script for Laravel server setup
source "$(dirname "$0")/bootstrap.sh"
print_header "Configuring UFW Firewall"
print_status "Setting up firewall rules..."

sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow $SSH_PORT/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

print_status "Enabling firewall..."
sudo ufw --force enable

if [ $? -eq 0 ]; then
    print_status "Firewall configured and enabled successfully"
    sudo ufw status
else
    print_error "Failed to configure firewall"
    exit 1
fi

# Configure fail2ban
print_header "Configuring Fail2ban"
print_status "Setting up fail2ban for intrusion prevention..."

sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

cat << EOF | sudo tee /etc/fail2ban/jail.d/custom.conf
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 3
bantime = 3600

[nginx-limit-req]
enabled = true
filter = nginx-limit-req
logpath = /var/log/nginx/error.log
maxretry = 10
bantime = 600
EOF

sudo systemctl enable fail2ban
sudo systemctl restart fail2ban

if [ $? -eq 0 ]; then
    print_status "Fail2ban configured and started successfully"
else
    print_error "Failed to configure fail2ban"
    exit 1
fi

# Configure SSH security
print_header "Configuring SSH Security"
print_status "Hardening SSH configuration..."

sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

cat << EOF | sudo tee /etc/ssh/sshd_config.d/security.conf
# Security configurations
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 2
Protocol 2
EOF

print_status "Restarting SSH service to apply changes..."
sudo systemctl restart ssh

if [ $? -eq 0 ]; then
    print_status "SSH security configured successfully"
    print_warning "SSH port has been changed to: $SSH_PORT"
    print_warning "Make sure to update your SSH client configuration"
else
    print_error "Failed to configure SSH security"
    exit 1
fi

print_header "Security Configuration Complete"
print_status "Firewall, fail2ban, and SSH security have been configured"