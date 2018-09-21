#!/bin/bash

# Owner: Chris Goodson (chris@goodson.systems)
# Purpose: Connect CentOS 7 to Active Directory for centralized authentication using sssd and realmd.
# OS Requirements: CentOS 7
# Actions: Joins MS Active Directory domain and adds Domain Admins to sudoers

# Determine distro
if [ -f "/etc/os-release" ]; then
	distroname=$(grep PRETTY_NAME /etc/os-release | sed 's/PRETTY_NAME=//g' | tr -d '="')
else
	distroname="$(uname -s) $(uname -r)"
fi

# Validate distro
supported_distros=("CentOS Linux 7 (Core)" "Ubuntu 16.04.5 LTS")

function match_distro() {
    local n=$#
    local value=${!n}
    for ((i=1;i < $#;i++)) {
        if [ "${!i}" == "${value}" ]; then
            echo "y"
            return 0
        fi
    }
    echo "n"
    return 1
}

if [ "$(match_distro "${supported_distros[@]}" "$distroname")" != "y" ]; then
    echo "Unsupported distro: $distroname"
    exit 1
fi

# Check for root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Ask for domain
while true; do
	read -p "Domain (i.e. mydomain.local): " -e domain_answer
  domain=$(echo $domain_answer | tr "[a-z]" "[A-Z]")
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
	if [[ $answer =~ ^[Yy]$ ]]; then
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

if [ "$distroname" == "CentOS Linux 7 (Core)" ]; then
  yum install realmd sssd oddjob oddjob-mkhomedir adcli samba-common samba-common-tools ntpdate ntp -y
elif [ "$distroname" == "Ubuntu 16.04.5 LTS" ]; then
  apt-get install realmd sssd sssd-tools samba-common krb5-user packagekit samba-common-bin samba-libs adcli -y
fi


# Configure NTP
if [ "$distroname" == "CentOS Linux 7 (Core)" ]; then
  echo
  echo "Configuring NTP"
  systemctl enable ntpd
  ntpdate $ntp_fqdn
  systemctl start ntpd
elif [ "$distroname" == "Ubuntu 16.04.5 LTS" ]; then
  if timedatectl | grep "Network time on: yes" && timedatectl | grep "NTP synchronized: yes"; then
    echo "NTP enabled"
  else
    timedatectl set-ntp on
    ntpattempts=0
    sleep 10
    while true; do
      if timedatectl | grep "Network time on: yes" && timedatectl | grep "NTP synchronized: yes"; then
        break
      else
        if [[ $ntpattempts -le 10 ]]; then
        ((ntpattempts+=1))
        sleep 30
        continue
        else
          echo "NTP Configuration Error - Aborting"
          exit 1
        fi
      fi
    done
  fi
fi

# Edit RealmD configuration
if [ "$distroname" == "Ubuntu 16.04.5 LTS" ]; then
  cat >/etc/realmd.conf <<EOL
  [users]
  default-home = /home/%U
  default-shell = /bin/bash
  [active-directory]
  default-client = sssd
  os-name = Ubuntu Server
  os-version = 16.04
  [service]
  automatic-install = no
  [$domain]
  fully-qualified-names = no
  automatic-id-mapping = yes
  user-principal = yes
  manage-system = no
EOL
fi

# Join to domain
echo
echo "Attempting to join domain..."
if errormessage=$(echo $password | realm join --user=$auth_user $domain > /dev/null 2>&1); then
  echo "Joined to domain: $domain"
else
  echo "Unable to join domain"
  echo $errormessage
fi

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
