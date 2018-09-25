#!/bin/bash

# Owner: Chris Goodson (chris@goodson.systems)
# Purpose: Connect CentOS 7 or Ubuntu 16.04 to Active Directory for centralized authentication using sssd and realmd.
# OS Requirements: CentOS 7 or Ubuntu 16.04 (Tested on 64bit only)
# Actions: Joins MS Active Directory domain and adds Domain Admins to sudoers
# Notes: This script assumes that the system hostname and all networking parameters are configured correctly.

# Determine distro
if [ -f "/etc/os-release" ]; then
	osfamily=$(grep ID= /etc/os-release | grep -v VERSION | sed 's/ID=//g' | tr -d '="')
	osversion=$(grep VERSION_ID /etc/os-release | sed 's/VERSION_ID=//g' | tr -d '="')
	distroname=$osfamily$osversion
	echo "Discovered distro: $distroname"
else
	distroname="$(uname -s) $(uname -r)"
fi

# Validate distro
supported_distros=("centos7" "ubuntu14.04" "ubuntu16.04" "ubuntu18.04")

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
    echo "Supported distros:"
    printf '%s\n' "${supported_distros[@]}"
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
		break
	fi
done

# Ask for password
while true; do
	read -s -p "Enter password: " -e password && echo
	read -s -p "Confirm password: " -e confirmpassword
	if [[ "$password" == "$confirmpassword" ]] > /dev/null 2>&1 ; then
		break
	else
		echo "Passwords do not match, try again"
	fi
done

# Ask for DC address
echo
while true; do
  read -p "Enter primary domain controller hostname: " -e dc_host_1
	read -p "Confirm primary domain controller: $dc_host_1@$domain (Y/n):" -n 1 -r -e dc1_answer
	if [[ $dc1_answer =~ ^[Yy]$ ]]
	then
		break
	fi
done
while true; do
  read -p "Enter secondary domain controller hostname: " -e dc_host_2
	read -p "Confirm secondary domain controller: $dc_host_2@$domain (Y/n):" -n 1 -r -e dc2_answer
	if [[ $dc2_answer =~ ^[Yy]$ ]]
	then
		break
	fi
done

# Install deps
echo
echo "Installing dependencies"

if [ "$osfamily" == "centos" ]; then
  yum install realmd sssd oddjob oddjob-mkhomedir adcli samba-common samba-common-tools ntpdate ntp -y
elif [ "$osfamily" == "ubuntu" ]; then
	export DEBIAN_FRONTEND=noninteractive
  if ! apt-get install realmd sssd sssd-tools samba-common krb5-user packagekit samba-common-bin samba-libs adcli -y; then
		if ! add-apt-repository universe -y; then
			echo "Error adding universe repository"
			exit 1
		fi
		if ! apt-get install realmd sssd sssd-tools samba-common krb5-user packagekit samba-common-bin samba-libs adcli -y; then
			echo "Error installing required packages"
			exit 1
		fi
	fi
fi

# Configure NTP
if [ "$osfamily" == "centos" ]; then
  echo
  echo "Configuring NTP"
  systemctl enable ntpd
  ntpdate $dc_host_1@$domain
  systemctl start ntpd
elif [ "$osfamily" == "ubuntu" ]; then
	if [ "$osversion" == "14.04" ]; then
		if timedatectl | grep "NTP enabled: yes"; then
		 	timesync=enabled
		fi
  elif [ "$osversion" == "16.04" ]; then
		if timedatectl | grep "Network time on: yes"; then
			timesync=enabled
		fi
  elif [ "$osversion" == "18.04" ]; then
		if timedatectl | grep "systemd-timesyncd.service active: yes"; then
			timesync=enabled
		fi
	fi
  if [ "$osfamily" == "ubuntu" ]; then
		if [ "$timesync" == "enabled" ]; then
	    echo "Time sync enabled"
	  else
	    timedatectl set-ntp true
	    ntpattempts=0
	    sleep 10
	    while true; do
	      if timedatectl | grep "Network time on: yes" && timedatectl | grep "NTP synchronized: yes"; then
	        break
	      else
	        if [[ $ntpattempts -le 10 ]]; then
	        ((ntpattempts+=1))
	        sleep 30
					echo "Waiting for network time to syncronize... Attempt $ntpattempts/10"
	        continue
	        else
	          echo "NTP Configuration Error - Aborting"
	          exit 1
	        fi
	      fi
	    done
	  fi
	fi
fi

# Edit RealmD configuration - Ubuntu
if [ "$osfamily" == "ubuntu" ]; then
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
if errormessage=$(echo $password > /dev/null 2>&1 | realm join --user=$auth_user $domain > /dev/null 2>&1); then
  echo "Joined to domain: $domain"
else
  echo "Unable to join domain"
  echo $errormessage
fi

# Update Kerberos configuration
if [ "$osfamily" == "ubuntu" ]; then
  mv /etc/krb5.conf /etc/krb5.conf.bak
  cat >/etc/krb5.conf <<EOL
[libdefaults]
      default_realm = $domain
      ticket_lifetime = 24h
      renew_lifetime = 7d


[realms]
        $domain = {
                kdc = $dc_host_1.$domain_answer
                kdc = $dc_host_2.$domain_answer
                admin_server = $dc_host_1.$domain_answer
                default_domain = $domain_answer
        }

[domain_realm]
        $domain_answer = $domain
        .$domain_answer = $domain
EOL
fi


# Edit SSSD configuration
echo
echo "Updating SSSD configuration"

if [ "$osfamily" == "centos" ]; then
  sed -i.bak 's/use_fully_qualified_names = True/use_fully_qualified_names = False/' /etc/sssd/sssd.conf
  sed -i 's/fallback_homedir = \/home\/%u@%d/fallback_homedir = \/home\/%u/' /etc/sssd/sssd.conf
  sed -i "/services = nss, pam/a\default_domain_suffix = $domain" /etc/sssd/sssd.conf
  sed -i 's/access_provider = ad/access_provider = simple/' /etc/sssd/sssd.conf
elif [ "$osfamily" == "ubuntu" ]; then
  mv /etc/sssd/sssd.conf /etc/sssd/sssd.conf.bak
  cat >/etc/sssd/sssd.conf <<EOL
[sssd]
services = nss,pam
config_file_version = 2
domains = $domain

[domain/$domain]
id_provider = ad
access_provider = ad
override_homedir = /home/%u
enumerate = true
use_fully_qualified_names = false
subdomains_provider = none
override_shell = /bin/bash
EOL
fi

# Configure Samba
if [ "$osfamily" == "ubuntu" ]; then
  mv /etc/samba/smb.conf /etc/samba/smb.conf.bak
  cat >/etc/samba/smb.conf <<EOL
[global]

   client signing = yes
   client use spnego = yes
   kerberos method = secrets and keytab
   realm = $domain
   security = ads
   server string = %h
   dns proxy = no
   log file = /var/log/samba/log.%m
   max log size = 1000
   syslog = 0
   panic action = /usr/share/samba/panic-action %d
   server role = standalone server
   obey pam restrictions = yes
   unix password sync = yes
   passwd program = /usr/bin/passwd %u
   passwd chat = *Enter\snew\s*\spassword:* %n\n *Retype\snew\s*\spassword:* %n\n *password\supdated\ssuccessfully* .
   pam password change = yes
   map to guest = bad user
   usershare allow guests = yes
EOL
chmod 600 /etc/sssd/sssd.conf
fi

# Edit Sudoers
echo
echo "Updating sudoers"
if [ "$osfamily" == "centos" ]; then
  echo "%Domain\ Admins@$domain  ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/DomainAdmins
elif [ "$osfamily" == "ubuntu" ]; then
  echo "%domain\ admins  ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/DomainAdmins
fi

# Allow home directory - Ubuntu
if [ "$osfamily" == "ubuntu" ]; then
  sed -i.bak "/session[[:blank:]]*optional[[:blank:]]*pam_sss.so/a\session required pam_mkhomedir.so skel=\/etc\/skel\/ umask=0077" /etc/pam.d/common-session
fi

# Restarting SSSD
service sssd restart

# All done
echo
  echo "Domain join complete. Attempt to log in with domain credentials to verify configuration."

exit 0
