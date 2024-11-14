#!/bin/bash
set -u  # treat unset variables as an error
set -o pipefail  #returns any error in the pipe, not just last command

# I like to setup up with a temp hostname first. This lets me get the new server up
# and running with SSL where I can test filemaker first before moving production data to it.
#
# CERTBOT_HOSTNAME_SETUP below is used for this purpose.

# Once i'm happy, I move production data to it.
# I change the Elastic IP address from the old server to the new.
# The last thing this install script needs to do is get another SSL cert for the production host name.
# CERTBOT_HOSTNAME_PROD is used as this final host name.

# Required
# ALL The following variables are required
# These variables won't work as is. They need to be set correctly
DOWNLOAD=https://downloads.claris.com/filemaker.zip
HOSTNAME=fm.example.com
CERTBOT_EMAIL=me@you.com

#
# These variables will work, but should be set to appropraite values.
TIMEZONE=Australia/Melbourne
FM_ADMIN_USER=admin
FM_ADMIN_PASSWORD=pass
FM_ADMIN_PIN=1234

#
# These can be changed to suit, but will work fine as they are.
HOME_LOCATION=/home/ubuntu
SCRIPT_LOCATION=$HOME_LOCATION/sa-filemaker-install
STATE=$SCRIPT_LOCATION/state
ASSISTED_FILE=$SCRIPT_LOCATION/fminstall/AssInst.txt


#
# These shouldn't be changed for this script to work
WEBROOTPATH="/opt/FileMaker/FileMaker Server/NginxServer/htdocs/httpsRoot/"

# Overrides with private data
DOWNLOAD=xxx
HOSTNAME=xxx
CERTBOT_EMAIL=xxx

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
  ln -s $SCRIPT_LOCATION/fm_install.sh $HOME_LOCATION/fm_install.sh
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

if [ ! -f $STATE/timezone-set ]; then 
  sudo timedatectl set-timezone $TIMEZONE || { echo "Error setting timezone"; exit 1; }
  timedatectl
  touch $STATE/timezone-set
fi

if [ ! -f $STATE/hostname-set ]; then
  sudo hostnamectl set-hostname $HOSTNAME || { echo "Error setting hostname"; exit 1; }
  touch $STATE/hostname-set
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
  echo "Label the drives"
  sudo parted -s $DRIVE_DATABASES mklabel gpt || { echo "error with mklabel on database drive"; exit 1; }
  sudo parted -s $DRIVE_CONTAINERS mklabel gpt || { echo "error with mklabel on containers drive"; exit 1; }
  sudo parted -s $DRIVE_BACKUPS mklabel gpt || { echo "error with mklabel on backup drive"; exit 1; }

  echo "Partition the drives"
  sudo parted -s $DRIVE_DATABASES mkpart Databases 0% 100% || { echo "error with mkpark on database drive"; exit 1; }
  sudo parted -s $DRIVE_CONTAINERS mkpart Containers 0% 100% || { echo "error with mkpart on containers drive"; exit 1; }
  sudo parted -s $DRIVE_BACKUPS mkpart Backups 0% 100% || { echo "error with mkpart on backup drive"; exit 1; }

  echo "Format the drives"
  sudo mkfs.ext4 -m 0 ${DRIVE_DATABASES}p1 || { echo "error with mkfs on database drive"; exit 1; }
  sudo mkfs.ext4 -m 0 ${DRIVE_CONTAINERS}p1 || { echo "error with mkfs on containers drive"; exit 1; }
  sudo mkfs.ext4 -m 0 ${DRIVE_BACKUPS}p1 || { echo "error with mkfs on backup drive"; exit 1; }

  touch $STATE/drive-setup
fi

DATABASE_UUID=$(lsblk -n -o UUID ${DRIVE_DATABASES}p1)
CONTAINER_UUID=$(lsblk -n -o UUID ${DRIVE_CONTAINERS}p1)
BACKUP_UUID=$(lsblk -n -o UUID ${DRIVE_BACKUPS}p1)

#Check we have UUID's for all drives
if [ -z $DATABASE_UUID ] || [ -z $CONTAINER_UUID ] || [ -z $BACKUP_UUID ]; then
  echo "Don't have all required UUID's"
  echo DATABASE_UUID: $DATABASE_UUID
  echo CONTAINER_UUID: $CONTAINER_UUID
  echo BACKUP_UUID: $BACKUP_UUID
  exit 1
fi


#Download filemaker
if [ ! -f $STATE/filemaker-downloaded ]; then
  rm -rf $SCRIPT_LOCATION/fmdownload
  if mkdir $SCRIPT_LOCATION/fmdownload; then
    cd $SCRIPT_LOCATION/fmdownload
    if wget $DOWNLOAD; then
      unzip ./fms*
    else
      echo "Error downloading filemaker."
      exit 1
    fi
    touch $STATE/filemaker-downloaded
  else
    echo "Error creating Filemaker download directory at $SCRIPT_LOCATION/fmdownload"
    exit 1
  fi
fi

#Copy install file
# The only thing we want from the claris .zip file is the *.deb installer.
if [ ! -f $STATE/filemaker-install-file ]; then
  mkdir $SCRIPT_LOCATION/fminstall
  cp $SCRIPT_LOCATION/fmdownload/filemaker-server*.deb $SCRIPT_LOCATION/fminstall || { echo "Error copying .deb file to fminstall directory"; exit 1; }
  touch $STATE/filemaker-install-file
fi


#Install filemaker
if [ ! -f $STATE/filemaker-installed ]; then
  cd $SCRIPT_LOCATION/fminstall
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

  sudo FM_ASSISTED_INSTALL=$ASSISTED_FILE apt install ./filemaker-server*.deb -y || { echo "Error installing Filemaker"; exit 1; }
  touch $STATE/filemaker-installed
fi

if [ ! -f $STATE/certbot-installed ]; then
  sudo snap install --classic certbot || { echo "Error installing Certbot."; exit 1; }
  sudo ln -s /snap/bin/certbot /usr/bin/certbot
  touch $STATE/certbot-installed
fi

sudo service ufw stop

if [ ! -f $STATE/certbot-certificate ]; then
  sudo certbot certonly --webroot \
    -w "$WEBROOTPATH" \
    -d $HOSTNAME \
    --agree-tos --non-interactive \
    -m $CERTBOT_EMAIL \
    || { echo "Error getting Certificate with Certbot."; sudo service ufw start; exit 1; }
fi
sudo service ufw start
touch $STATE/certbot-certificate

exit 9

if [ ! -f $STATE/certbot-certificate-loaded-filemaker ]; then
  sudo chown -R fmserver:fmsadmin "$CERTBOTPATH"

  CERTFILE=$(sudo realpath "$CERTBOTPATH/live/$HOSTNAME/cert.pem")
  PRIVKEYFILE=$(sudo realpath "$CERTBOTPATH/live/$HOSTNAME/privkey.pem")
  INTERMEDIATEFILE=$(sudo realpath "$CERTBOTPATH/live/$HOSTNAME/fullchain.pem")

  echo "Importing Certificates:"
  echo "Certificate: $CERTFILE"
  echo "Certificate: $PRIVKEYFILE"
  echo "Private key: $INTERMEDIATEFILE"

  sudo fmsadmin certificate \
   import "$CERTFILE" \
   --keyfile "$PRIVKEYFILE" \
   --intermediateCA "$INTERMEDIATEFILE" \
   -u $FM_ADMIN_USER -p $FM_ADMIN_PASSWORD -y || { echo "Filemaker unable to import certificate"; exit 1; }

  sudo service fmshelper restart
fi

## At this point, the server should be up and running with an SSL cert.
