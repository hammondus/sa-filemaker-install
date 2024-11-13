#!/bin/bash
# I like to setup up with a temp hostname first. This lets me get the new server up
# and running with SSL where I can test filemaker first before moving production data to it.
#
# CERTBOT_HOSTNAME_SETUP below is used for this purpose.

# Once i'm happy, I move production data to it.
# I change the Elastic IP address from the old server to the new.
# The last thing this install script needs to do is get another SSL cert for the production host name.
# CERTBOT_HOSTNAME_PROD is used as this final host name.

# Required
# ALL The following variables are required to be uncommented and set correctly for the script to work
DOWNLOAD=https://downloads.claris.com/filemaker.zip
CERTBOT_HOSTNAME_SETUP=fm.domain.com
#CERTBOT_HOSTNAME_PROD=fm.hammond.zone
CERTBOT_EMAIL=me@you.com
HOSTNAME=fm.domain.com
TIMEZONE=Australia/Melbourne
FM_ADMIN_USER=admin
FM_ADMIN_PASSWORD=pass
FM_ADMIN_PIN=1234
HOME_LOCATION=/home/ubuntu
STATE=$PWD/state
ASSISTED_FILE=$HOME_LOCATION/fminstall/AssInst.txt

#Be careful with the drive settings. The script doesn't check that what you have put in is correct.
#Only put in devices that are completely blank. Devices listed below will be partitioned and formatted.
DRIVE_DATABASES=/dev/nvme1n1
DRIVE_CONTAINERS=/dev/nvme2n1
DRIVE_BACKUPS=/dev/nvme3n1

################################### END OF REQUIRED VARIABLES ########################

# Optional
# Install optional programs I find handy. Comment these out if not needed
GLANCES=Yes
NCDU=Yes
IOTOP=Yes

#echo "If this install asks you to reboot and rerun the script, it is copied to ~/fm_install.sh"
#read -p "Press return to continue "

# Copy this script to the home directory so it can easily be run it after login
if [ ! -f ~/fm_install.sh ]; then
  ln -s $PWD/fm_install.sh $HOME_LOCATION/fm_install.sh
fi


# The state directory is used so that this script can keep track of where it is up to between reboots
if [ ! -d $STATE ]; then
  echo "creating state directory"
  mkdir $STATE || { echo "Couldn't create state directory"; exit 1; }
fi


#Check we are on the correct version of Ubuntu
if [ -f /etc/os-release ]; then
  . /etc/os-release
  VER=$VERSION_ID
  if [ "$VER" != "22.04" ]; then
    echo "Wrong version of Ubuntu. Must be 22.04"
    echo "You are running" $VER 
    exit 1
  else
    echo "Good. You are Ubuntu" $VER
  fi
fi

#Make sure the system is up to date and reboot if necessary
if [ ! -f $STATE/apt-upgrade ]; then
  echo 'apt update/upgrade not done. doing it now'
  sudo apt update && sudo apt upgrade -y || { echo "Error running apt update / upgrade"; exit 1; }
  touch $STATE/apt-upgrade
  if [ -f /var/run/reboot-required ]; then
    echo "Reboot is required. Reboot then rerun this script"
    exit 1
  fi
fi

if [ ! -f $STATE/timezone-set ]; then 
  sudo timedatectl set-timezone $TIMEZONE || { echo "Error setting timezone"; exit 1; }
  timedatectl
  touch $STATE/timezone-set
fi

if [ ! -f $STATE/hostname-set ]; then
  sudo hostnamectl set-hostname $HOSTNAME || { echo "Error setting hostname"; exit 1; }
  touch $STATE/hostname-set
fi

#Install unzip if it's not installed. Not optional
#The download from claris needs to be unzipped.
type unzip > /dev/null 2>&1 || sudo apt install unzip -y

#Install optional software if they have been selected
if [ "$GLANCES" = "Yes" ]; then
  type glances > /dev/null 2>&1 || sudo apt install glances -y || { echo "Error installing Glances"; exit 9; }
fi
if [ $NCDU = "Yes" ]; then
  type ncdu > /dev/null 2>&1 || sudo apt install ncdu -y || { echo "Error installing NCDU"; exit 9; }
fi
if [ $IOTOP = "Yes" ]; then
  type iotop > /dev/null 2>&1 || sudo apt install iotop-c -y || { echo "Error installing iotop-c"; exit 9; }
fi


# Partition, format and attached the additional drives.
#

if [ ! -f $STATE/drive-setup ]; then
  echo "Format the database drive"
  sudo parted -s $DRIVE_DATABASES mklabel gpt
  sudo parted -s $DRIVE_DATABASES mkpart Databases 0% 100%
  sudo mkfs.ext4 -m 0 ${DRIVE_DATABASES}p1

  echo "Format the database drive"
  sudo parted -s $DRIVE_CONTAINERS mklabel gpt
  sudo parted -s $DRIVE_CONTAINERS mkpart Containers 0% 100%
  sudo mkfs.ext4 -m 0 ${DRIVE_CONTAINERS}p1

  echo "Format the database drive"
  sudo parted -s $DRIVE_BACKUPS mklabel gpt
  sudo parted -s $DRIVE_BACKUPS mkpart Backups 0% 100%
  sudo mkfs.ext4 -m 0 ${DRIVE_BACKUPS}p1

  touch $STATE/drive-setup
fi


DATABASE_UUID=$(blkid -o value -s UUID ${DRIVE_DATABASES}p1)
CONTAINER_UUID=$(blkid -o value -s UUID ${DRIVE_CONTAINERS}p1)
BACKUP_UUID=$(blkid -o value -s UUID ${DRIVE_BACKUPS}p1)


#Download filemaker
if [ ! -f $STATE/filemaker-downloaded ]; then
  rm -rf $PWD/fmdownload
  if mkdir $PWD/fmdownload; then
    cd $PWD/fmdownload
    if wget $DOWNLOAD; then
      unzip ./fms*
    else
      echo "Error downloading filemaker."
      exit 9
    fi
    touch $STATE/filemaker-downloaded
  else
    echo "Error creating Filemaker install directory at $HOME_LOCATION/fminstall"
    exit 9
  fi
fi

exit 99



#Install filemaker
if [ ! -f $STATE/filemaker-installed ]; then
  cd $HOME_LOCATION/fminstall
  # Create the assisted install file.
  echo "[Assisted Install]" > $ASSISTED_FILE
  echo "License Accepted=1" >> $ASSISTED_FILE
  echo "Deployment Options=0" >> $ASSISTED_FILE
  echo "Admin Console User=$FM_ADMIN_USER" >> $ASSISTED_FILE
  echo "Admin Console Password=$FM_ADMIN_PASSWORD" >> $ASSISTED_FILE
  echo "Admin Console PIN=$FM_ADMIN_PIN" >> $ASSISTED_FILE
  echo "Filter Databases=0" >> $ASSISTED_FILE
  echo "Remove Sample Database=1" >> $ASSISTED_FILE
  echo "Use HTTPS Tunneling=1" >> $ASSISTED_FILE
  echo "Swap File Size=4G" >> $ASSISTED_FILE
  echo "Swappiness=10" >> $ASSISTED_FILE

  sudo FM_ASSISTED_INSTALL=$ASSISTED_FILE apt install ./filemaker-server*.deb -y || { echo "Error installing Filemaker"; exit 9; }
  touch $STATE/filemaker-installed
fi

if [ ! -f $STATE/certbot-installed ]; then
  sudo snap install --classic certbot || { echo "Error installing Certbot"; exit 9; }
  sudo ln -s /snap/bin/certbot /usr/bin/certbot
  touch $STATE/certbot-installed
fi


# For this to work:
# You need a DNS host record for $CERTBOT_HOSTNAME_SETUP pointing to the public IP address of this server
# You need port 80 & 443 open

# if [ ! -f $STATE/certbot-cert ]; then
#   sudo certbot certonly --webroot -w "/opt/FileMaker/FileMaker Server/NginxServer/htdocs/httpsRoot" -d $CERTBOT_HOSTNAME_SETUP \
#     --agree-tos -m $CERTBOT_EMAIL || { echo "Error getting certbot certificate. Make sure DNS and firewall is set correctly"; exit 9; }
#   touch $STATE/certbot-cert
# fi
