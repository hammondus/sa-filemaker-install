# Filemaker Installation
## A somewhat automated install of Filemaker on an AWS EC2 instance.

## Prerequisites before running this script.
- Installation of Ubuntu 22.04. Preferably a fresh clean install
- Any additional drives that Filemaker will use for databases, containers, backups etc are connected.
- Drives need not be partitioned for formatted. The script will do that.
- 
```
git clone https://github.com/hammondus/sa-filemaker-install
cd sa-filemaker-install
./fm_install.sh
```

