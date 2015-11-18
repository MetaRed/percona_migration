!/bin/bash
# set -xv
# This is for Mysql Master Database Migration
# It turns on db doner mode for the mysql cluster node
# It will run the full backup
# It turn off db doner mode for the mysql cluster node
# It copy the mysql archive to designated node on AWS
# Written By : Richard Lopez
# Date : Nov 19th, 2014


# Cron Path
PATH=$PATH:/bin:/usr/bin:/usr/local/bin:/sbin:/usr/sbin:/usr/local/sbin

# set the desired umask
umask 002

# declare variables
EMAIL=bigkahuna@meta.red
LOCAL_BACKUP_DIR=/path/to/mysql/backup/dir
SERVER_NAME=$(hostname --fqdn)
PORT=3306
USERNAME=mysql_backup_user
PASSWORD=mysql_backup_user_pass
ADMIN_USERNAME=mysql_admin_user
ADMIN_PASSWORD=mysql_admin_user_pass
LOG_DIR=/path/to/log/dir/
AWS_DB_HOST="dbm1"
JUMP_HOST="DMZ_HOSTNAME_OR_IP"

 make sure our log directory exists
if [ ! -d $LOG_DIR ]; then
  mkdir $LOG_DIR
  if [ ! $? -eq 0 ]; then
    echo "Unable to create log dir: $LOG_DIR" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
    exit 1
  fi
else
  touch $LOG_DIR/test
  rm $LOG_DIR/test
  if [ ! $? -eq 0 ]; then
    echo "Unable to write to log dir: $LOG_DIR" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
    exit 1
  fi
fi

 make sure our local backup directory is writable
if [ ! -d $LOCAL_BACKUP_DIR ]; then
  mkdir -p $LOCAL_BACKUP_DIR
  if [ ! $? -eq 0 ]; then
    echo "Unable to create backup dir: $LOCAL_BACKUP_DIR" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
    exit 1
  fi
else
  touch $LOCAL_BACKUP_DIR/test
  rm $LOCAL_BACKUP_DIR/test
  if [ ! $? -eq 0 ]; then
    echo "Unable to write to backup dir: $LOCAL_BACKUP_DIR" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
    exit 1
  fi
fi 

START_TIME="$(date)"
echo "STARTING MYSQL DATA FORKLIFT ${START_TIME}"
# Engage doner mode for percona cluster node
mysql -N -s -u $ADMIN_USERNAME -p$ADMIN_PASSWORD -e "set global wsrep_desync=ON"
DONER_STATUS=$(mysql -N -s -u $ADMIN_USERNAME -p$ADMIN_PASSWORD -e "show global variables like '%wsrep_desync%'")
echo "Turning Doner mode on: $DONER_STATUS"
if [ ! $? -eq 0 ]; then
  echo "Unable to turn on DB doner mode on $SERVER_NAME Doner Value is: $DONER_STATUS" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

# Run the Database Backup
innobackupex --rsync --parallel=20 --user=$USERNAME --password=$PASSWORD --safe-slave-backup $LOCAL_BACKUP_DIR

# Disengage doner mode for percona cluster node
mysql -N -s -u $ADMIN_USERNAME -p$ADMIN_PASSWORD -e "set global wsrep_desync=OFF"
DONER_STATUS=$(mysql -N -s -u $ADMIN_USERNAME -p$ADMIN_PASSWORD -e "show global variables like '%wsrep_desync%'")
echo "Turning Doner mode off: $DONER_STATUS"
if [ ! $? -eq 0 ]; then
  echo "Unable to turn on DB doner mode on $SERVER_NAME Doner Value is: $DONER_STATUS" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi
# Find the last Backup Directory for Backup
LAST_BACKUP_DIR=$(ls -tr $LOCAL_BACKUP_DIR|tail -1)

echo "APPLYING LOG TO BACKUP $(date)"
# Apply the log on Backup Directory
innobackupex --apply-log $LOCAL_BACKUP_DIR/$LAST_BACKUP_DIR

# Find the Current Backup Directory to migrate
cd $LOCAL_BACKUP_DIR
CURRENT_BACKUP_DIR=$(find . -maxdepth 1 -type d -daystart -mtime 0 | tail -1 | cut -d/ -f2)
if [ ! $? -eq 0 ]; then
  echo "Unable to find last backup dir under $LOCAL_BACKUP_DIR" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "COMPRESSING BACKUP FILE $(date)"
# compress the current backup dir to transport
cd $LOCAL_BACKUP_DIR
tar --remove-files -I pigz -cvf ${SERVER_NAME}-${CURRENT_BACKUP_DIR}.tar.gz ${CURRENT_BACKUP_DIR}
if [ ! $? -eq 0 ]; then
  echo "Unable to tar up the current backup ${LOCAL_BACKUP_DIR}/${SERVER_NAME}-${CURRENT_BACKUP_DIR}" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

# Remove old mysql backup data
START_TIME="$(date)"
echo "Removing old mysql exploded data $(date)"
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t ssh -i private_key.pem ubuntu@"${AWS_DB_HOST}" "sudo rm -rf /ssd_data/mysql_migration/*"
if [ ! $? -eq 0 ]; then
  echo "Unable to Remove exploded mysql dir on $AWS_DB_HOST" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

# Migrate todays db archive to AWS
echo "STARTING MYSQL DATA FORKLIFT $(date)"
cd /root
rsync -av -e "ssh -i private_key.pem ubuntu@${JUMP_HOST} ssh -i private_key.pem" $LOCAL_BACKUP_DIR/${SERVER_NAME}-${CURRENT_BACKUP_DIR}.tar.gz ubuntu@"${AWS_DB_HOST}":/ssd_data/mysql_migration/
if [ ! $? -eq 0 ]; then
  echo "Unable to copy archives to $AWS_DB_HOST" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

# Extract todays data
echo "Expanding archive data $(date)"
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t ssh -i private_key.pem ubuntu@"${AWS_DB_HOST}" "sudo find /ssd_data/mysql_migration -type f -daystart -mtime 0 -exec 'tar -C /ssd_data/mysql_migration -xvf {} ${CURRENT_BACKUP_DIR} \;'"
if [ ! $? -eq 0 ]; then
  echo "Unable decompress MySQL data to /ssd_data/mysql_migration on $AWS_DB_HOST" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

#########################
 DATABASE CUTOVER LOGIC #
#########################
# Remove comments to begin


echo "SHUTDOWN dbm2 starting $(date)"
# Stop the database cluster nodes to load data
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm2 "sudo service mysql stop"
if [ ! $? -eq 0 ]; then
  echo "Unable to stop MySQL service on dbm2" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "SHUTDOWN dbm3 starting $(date)"
# Stop the database cluster nodes to load data
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm3 "sudo service mysql stop"
if [ ! $? -eq 0 ]; then
  echo "Unable to stop MySQL service on dbm3" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "SHUTDOWN dbm4 starting $(date)"
# Stop the database cluster nodes to load data
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm4 "sudo service mysql stop"
if [ ! $? -eq 0 ]; then
  echo "Unable to stop MySQL service on dbm4" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "SHUTDOWN dbm1 starting $(date)"
# Stop the database service for data load
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@"${AWS_DB_HOST}" "sudo service mysql stop"
if [ ! $? -eq 0 ]; then
  echo "Unable to stop MySQL service on $AWS_DB_HOST" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "STARTING move of mysql data dir  $(date)"
# Move original MSQL data dir for data load
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@"${AWS_DB_HOST}" "sudo mv /ssd_data/mysql /ssd_data/mysql_orig_$(date +%m-%d-%Y)"
if [ ! $? -eq 0 ]; then
  echo "Unable to move mysql data dir for data load on $AWS_DB_HOST" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "STARTING data load on dbm1 $(date)"
# Load MYSQL dir for data load
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@"${AWS_DB_HOST}" "sudo mv /ssd_data/mysql_migration/${CURRENT_BACKUP_DIR} /ssd_data/mysql"
if [ ! $? -eq 0 ]; then
  echo "Unable to move backup dir for data load on $AWS_DB_HOST" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "STARTING mysql data dir permission changes $(date)"
# Change MYSQL data dir permissions
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@"${AWS_DB_HOST}" "sudo chown -R mysql:mysql /ssd_data/mysql"
if [ ! $? -eq 0 ]; then
  echo "Unable to move backup dir for data load on $AWS_DB_HOST" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "STARTING dbm1 database service $(date)"
# Start the database service for data load
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@"${AWS_DB_HOST}" "sudo service mysql start"
if [ ! $? -eq 0 ]; then
  echo "Unable to start MySQL service on $AWS_DB_HOST" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

##############################
# Preparing DB cluster nodes #
##############################

echo "STARTING move of mysql data dir on dbm2 $(date)"
# Move original MSQL data dir
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm2 "sudo mv /ssd_data/mysql /ssd_data/mysql_orig_$(date +%m-%d-%Y)"
if [ ! $? -eq 0 ]; then
  echo "Unable to move mysql data dir for data load on dbm2" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "Creating mysql data dir on dbm2 $(date)"
# Create MYSQL data dir
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm2 "sudo mkdir -p /ssd_data/mysql"
if [ ! $? -eq 0 ]; then
  echo "Unable to move backup dir for data load on dbm2" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "Setting mysql data dir permission changes on dbm2 $(date)"
# Change MYSQL data dir permissions
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm2 "sudo chown -R mysql:mysql /ssd_data/mysql"
if [ ! $? -eq 0 ]; then
  echo "Unable to move backup dir for data load on dbm2" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "STARTING move of mysql data dir on dbm3 $(date)"
# Move original MSQL data dir for data replication
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm3 "sudo mv /ssd_data/mysql /ssd_data/mysql_orig_$(date +%m-%d-%Y)"
if [ ! $? -eq 0 ]; then
  echo "Unable to move mysql data dir for data load on dbm3" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "Creating mysql data dir on dbm3 $(date)"
# Create MYSQL data dir
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm3 "sudo mkdir -p /ssd_data/mysql"
if [ ! $? -eq 0 ]; then
  echo "Unable to move backup dir for data load on dbm3" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "Setting mysql data dir permission changes on dbm3 $(date)"
# Change MYSQL data dir permissions
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm3 "sudo chown -R mysql:mysql /ssd_data/mysql"
if [ ! $? -eq 0 ]; then
  echo "Unable to move backup dir for data load on dbm3" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "STARTING move of mysql binlog dir on dbm3 $(date)"
# Move original MSQL binlog dir for data replication
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm3 "sudo mv /ssd_data/mysql-bin /ssd_data/mysql-bin-$(date +%m-%d-%Y)"
if [ ! $? -eq 0 ]; then
  echo "Unable to move mysql binlog dir for data load on dbm3" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "Creating mysql binlog dir on dbm3 $(date)"
# Create MYSQL binlog dir
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm3 "sudo mkdir -p /ssd_data/mysql-bin"
if [ ! $? -eq 0 ]; then
  echo "Unable to move backup dir for data load on dbm3" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "Setting mysql binlog dir permission changes on dbm3 $(date)"
# Change MYSQL binlog dir permissions
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm3 "sudo chown -R mysql:mysql /ssd_data/mysql-bin"
if [ ! $? -eq 0 ]; then
  echo "Unable to move backup dir for data load on dbm3" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "STARTING move of mysql data dir on dbm4 $(date)"
# Move original MSQL data dir for data replication
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm4 "sudo mv /ssd_data/mysql /ssd_data/mysql_orig_$(date +%m-%d-%Y)"
if [ ! $? -eq 0 ]; then
  echo "Unable to move mysql data dir for data load on dbm4" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "Creating mysql data dir on dbm4 $(date)"
# Create MYSQL data dir
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm4 "sudo mkdir -p /ssd_data/mysql"
if [ ! $? -eq 0 ]; then
  echo "Unable to move backup dir for data load on dbm4" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "Setting mysql data dir permission changes on dbm4 $(date)"
# Change MYSQL data dir permissions
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm4 "sudo chown -R mysql:mysql /ssd_data/mysql"
if [ ! $? -eq 0 ]; then
  echo "Unable to move backup dir for data load on dbm4" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "STARTING move of mysql binlog dir on dbm4 $(date)"
# Move original MSQL binlog dir for data replication
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm4 "sudo mv /ssd_data/mysql-bin /ssd_data/mysql-bin-$(date +%m-%d-%Y)"
if [ ! $? -eq 0 ]; then
  echo "Unable to move mysql binlog dir for data load on dbm4" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "Creating mysql binlog dir on dbm4 $(date)"
# Create MYSQL binlog dir
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm4 "sudo mkdir -p /ssd_data/mysql-bin"
if [ ! $? -eq 0 ]; then
  echo "Unable to move backup dir for data load on dbm4" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "Setting mysql binlog dir permission changes on dbm4 $(date)"
# Change MYSQL binlog dir permissions
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm4 "sudo chown -R mysql:mysql /ssd_data/mysql-bin"
if [ ! $? -eq 0 ]; then
  echo "Unable to move backup dir for data load on dbm4" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

#################################################################
echo "STARTING dbm2 service $(date)"
# Start the database cluster node
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm2 "screen -dm sudo service mysql start"
if [ ! $? -eq 0 ]; then
  echo "Unable to start MySQL service on dbm2" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "STARTING dbm3 service $(date)"
# Start the database cluster nodes
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm3 "screen -dm sudo service mysql start"
if [ ! $? -eq 0 ]; then
  echo "Unable to start MySQL service on dbm3" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

echo "STARTING dbm4 service $(date)"
# Start the database cluster nodes
cd /root
ssh -i private_key.pem ubuntu@"${JUMP_HOST}" -t -t ssh -i private_key.pem ubuntu@dbm4 "screen -dm sudo service mysql start"
if [ ! $? -eq 0 ]; then
  echo "Unable to start MySQL service on dbm4" |mail -s "${0}: failed on $SERVER_NAME" $EMAIL
  exit 1
fi

END_TIME="$(date)"
echo "MYSQL DATA FORKLIFT STARTED AT: ${START_TIME} FINISHED AT ${END_TIME}"

# Cleanup local backup directory
find ${LOCAL_BACKUP_DIR} -name "*.gz" -type f -daystart -mtime +0 -exec rm -f {} \;
