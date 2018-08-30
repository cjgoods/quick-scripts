#!/bin/bash

# Owner: Chris Goodson (chris@goodson.systems)
# Purpose: Connect CentOS 7 to Active Directory for centralized authentication using sssd and realmd.
# OS Requirements: CentOS 7
# Actions: Joins MS Active Directory domain and adds Domain Admins to sudoers

# Check for root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Ask for domain
while true; do
	read -p "Domain (i.e. mydomain.local): " -e domain
	read -p "Confirm domain: $domain (Y/n):" -n 1 -r -e answer
	if [[ $answer =~ ^[Yy]$ ]]
	then
		break
	fi
done


# Ask for username
while true; do
	read -p "Enter $domain username required for authentication: " -e domain_user
	auth_user=$domain_user@$domain
	read -p "Confirm user: $auth_user (Y/n):" -n 1 -r -e answer
	if [[ $answer =~ ^[Yy]$ ]]
	then
		read -s -p "Enter password: " -e password
		break
	fi
done

# Ask for DC address
echo
echo "Enter domain controller FQDN required for NTP service:"
read ntp_fqdn

# Install deps
echo
echo "Installing dependencies"
yum install realmd sssd oddjob oddjob-mkhomedir adcli samba-common samba-common-tools ntpdate ntp -y

# Configure NTP
echo
echo "Configuring NTP"
systemctl enable ntpd
ntpdate $ntp_fqdn
systemctl start ntpd

# Join to domain
echo
echo "Attempting to join domain..."
echo $password | realm join --user=$auth_user $domain > /dev/null 2>&1

# Edit SSSD configuration
echo
echo "Updating SSSD configuration"
sed -i.bak 's/use_fully_qualified_names = True/use_fully_qualified_names = False/' /etc/sssd/sssd.conf
sed -i 's/fallback_homedir = \/home\/%u@%d/fallback_homedir = \/home\/%u/' /etc/sssd/sssd.conf
sed -i "/services = nss, pam/a\default_domain_suffix = $domain" /etc/sssd/sssd.conf
sed -i 's/access_provider = ad/access_provider = simple/' /etc/sssd/sssd.conf

# Edit Sudoers
echo
echo "Updating sudoers"
echo "%Domain\ Admins@$domain  ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/DomainAdmins

# All done
echo
echo "Domain join complete. Attempt to log in with domain credentials to verify configuration."

exit 0
