#!/bin/bash
# set -xv
# This is for Percona Cluster Database Migration
# 1. It turns on db doner mode for the percona cluster node
# 2. Runs a full backup on percona cluster doner node
# 3. Turns off db doner mode on percona cluster node
# 4. Copy db archive to designated percona node in AWS
# 5. Create a new db cluster replicating from the first percona node
# Assumptions:
# Percona xtradb cluster v.5.5
# Disabled SSH key forwarding
# SSH key location same on doner db (running this script) and on JUMP_HOST
# Existing dir /ssd_data/mysql_migration on AWS_DB_HOST
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
SSH_KEY=/root/private_key.pem
USERNAME=mysql_backup_user
PASSWORD=mysql_backup_user_pass
ADMIN_USERNAME=mysql_admin_user
ADMIN_PASSWORD=mysql_admin_user_pass
LOG_DIR=/path/to/log/dir/
AWS_DB_HOST="dbm1"
JUMP_HOST="DMZ_HOSTNAME_OR_IP"

# email function
notify_email(){
  mail -s "${0}: failed on ${SERVER_NAME}" $EMAIL
}

# Stop percona node function
# example: stop_percona_node user@host
stop_percona_node(){
  DB_HOST=$(echo $1 | cut -d@ -f2)
  echo "SHUTDOWN ${DB_HOST} starting $(date)"
  # Stop the database cluster nodes to load data
  ssh -i ${SSH_KEY} ubuntu@"${JUMP_HOST}" -t -t ssh -i ${SSH_KEY} $1 "sudo service mysql stop"
    if [ ! $? -eq 0 ]; then
        echo "Unable to stop MySQL service on ${DB_HOST}" | notify_email
        exit 1
    fi
}

# Start percona node function
# example: start_percona_node user@host
start_percona_node(){
  DB_HOST=$(echo $1 | cut -d@ -f2)
  echo "STARTING ${DB_HOST} service $(date)"
  # Start the database cluster node
  ssh -i ${SSH_KEY} ubuntu@"${JUMP_HOST}" -t -t ssh -i ${SSH_KEY} $1 "screen -dm sudo service mysql start"
    if [ ! $? -eq 0 ]; then
        echo "Unable to start MySQL service on ${DB_HOST}" | notify_email
        exit 1
    fi
}

# Push compressed db archive and decompress on arrival anticipating migration
# example: percona_node_forklift
percona_node_forklift(){
  echo "STARTING MYSQL DATA FORKLIFT to $AWS_DB_HOST $(date)"
  rsync -av -e "ssh -i ${SSH_KEY} ubuntu@${JUMP_HOST} ssh -i ${SSH_KEY}" $LOCAL_BACKUP_DIR/${SERVER_NAME}-${CURRENT_BACKUP_DIR}.tar.gz ubuntu@"${AWS_DB_HOST}":/ssd_data/mysql_migration/
  if [ ! $? -eq 0 ]; then
    echo "Unable to copy archives to $AWS_DB_HOST" | notify_email
    exit 1
  fi

  # Extract todays data on the first percona db cluster node
  echo "Expanding archive data on $AWS_DB_HOST $(date)"
  ssh -i ${SSH_KEY} ubuntu@"${JUMP_HOST}" -t ssh -i ${SSH_KEY} ubuntu@"${AWS_DB_HOST}" "sudo find /ssd_data/mysql_migration -type f -daystart -mtime 0 -exec 'tar -C /ssd_data/mysql_migration -xvf {} ${CURRENT_BACKUP_DIR} \;'"
  if [ ! $? -eq 0 ]; then
    echo "Unable decompress MySQL data to /ssd_data/mysql_migration on $AWS_DB_HOST" | notify_email
    exit 1
  fi
}

# Prepare percona node to join new cluster function
# example: prepare_percona_node user@host
prepare_percona_node(){
  DB_HOST=$(echo $1 | cut -d@ -f2)
  echo "STARTING move of mysql data dir on ${DB_HOST} $(date)"
  # Move original MSQL data dir
  ssh -i ${SSH_KEY} ubuntu@"${JUMP_HOST}" -t -t ssh -i ${SSH_KEY} $1 "sudo mv /ssd_data/mysql /ssd_data/mysql_orig_$(date +%m-%d-%Y)"
    if [ ! $? -eq 0 ]; then
        echo "Unable to move mysql data dir for data load on ${DB_HOST}" | notify_email
        exit 1
    fi

  if [ ${DB_HOST} = ${AWS_DB_HOST} ]; then
      echo "STARTING data load on ${DB_HOST} $(date)"
      # Load MYSQL dir for first db cluster member to build the rest
      ssh -i ${SSH_KEY} ubuntu@"${JUMP_HOST}" -t -t ssh -i ${SSH_KEY} $1 "sudo mv /ssd_data/mysql_migration/${CURRENT_BACKUP_DIR} /ssd_data/mysql"
      if [ ! $? -eq 0 ]; then
          echo "Unable to move backup dir for data load on ${DB_HOST}" | notify_email
          exit 1
      fi
  else
      echo "Creating fresh mysql data dir on ${DB_HOST} $(date)"
      ssh -i ${SSH_KEY} ubuntu@"${JUMP_HOST}" -t -t ssh -i ${SSH_KEY} $1 "sudo mkdir -p /ssd_data/mysql"
      if [ ! $? -eq 0 ]; then
          echo "Unable to move backup dir for data load on ${DB_HOST}" | notify_email
          exit 1
      fi
  fi

  echo "Setting mysql data dir permissions on ${DB_HOST} $(date)"
  ssh -i ${SSH_KEY} ubuntu@"${JUMP_HOST}" -t -t ssh -i ${SSH_KEY} $1 "sudo chown -R mysql:mysql /ssd_data/mysql"
    if [ ! $? -eq 0 ]; then
        echo "Unable to move backup dir for data load on ${DB_HOST}" | notify_email
        exit 1
    fi

  echo "STARTING move of mysql binlog dir on ${DB_HOST} $(date)"
    # Move original MSQL binlog dir for data replication
  ssh -i ${SSH_KEY} ubuntu@"${JUMP_HOST}" -t -t ssh -i ${SSH_KEY} $1 "sudo mv /ssd_data/mysql-bin /ssd_data/mysql-bin-$(date +%m-%d-%Y)"
    if [ ! $? -eq 0 ]; then
        echo "Unable to move mysql binlog dir for data load on ${DB_HOST}" | notify_email
        exit 1
    fi

  echo "Creating fresh mysql binlog dir on ${DB_HOST} $(date)"
    # Create MYSQL binlog dir
  ssh -i ${SSH_KEY} ubuntu@"${JUMP_HOST}" -t -t ssh -i ${SSH_KEY} $1 "sudo mkdir -p /ssd_data/mysql-bin"
    if [ ! $? -eq 0 ]; then
        echo "Unable to move backup dir for data load on ${DB_HOST}" | notify_email
        exit 1
    fi

    echo "Setting mysql binlog dir permission changes on ${DB_HOST} $(date)"
    # Change MYSQL binlog dir permissions
    ssh -i ${SSH_KEY} ubuntu@"${JUMP_HOST}" -t -t ssh -i ${SSH_KEY} $1 "sudo chown -R mysql:mysql /ssd_data/mysql-bin"
      if [ ! $? -eq 0 ]; then
        echo "Unable to move backup dir for data load on ${DB_HOST}" | notify_email
        exit 1
      fi
}

# Make sure our log directory exists
if [ ! -d $LOG_DIR ]; then
  mkdir $LOG_DIR
  if [ ! $? -eq 0 ]; then
    echo "Unable to create log dir: $LOG_DIR" | notify_email
    exit 1
  fi
else
  touch $LOG_DIR/test
  rm $LOG_DIR/test
  if [ ! $? -eq 0 ]; then
    echo "Unable to write to log dir: $LOG_DIR" | notify_email
    exit 1
  fi
fi

# Make sure our local backup directory is writable
if [ ! -d $LOCAL_BACKUP_DIR ]; then
  mkdir -p $LOCAL_BACKUP_DIR
  if [ ! $? -eq 0 ]; then
    echo "Unable to create backup dir: $LOCAL_BACKUP_DIR" | notify_email
    exit 1
  fi
else
  touch $LOCAL_BACKUP_DIR/test
  rm $LOCAL_BACKUP_DIR/test
  if [ ! $? -eq 0 ]; then
    echo "Unable to write to backup dir: $LOCAL_BACKUP_DIR" | notify_email
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
  echo "Unable to turn on DB doner mode on $SERVER_NAME Doner Value is: $DONER_STATUS" | notify_email
  exit 1
fi

# Run the Database Backup
innobackupex --rsync --parallel=20 --user=$USERNAME --password=$PASSWORD --safe-slave-backup $LOCAL_BACKUP_DIR

# Disengage doner mode for percona cluster node
mysql -N -s -u $ADMIN_USERNAME -p$ADMIN_PASSWORD -e "set global wsrep_desync=OFF"
DONER_STATUS=$(mysql -N -s -u $ADMIN_USERNAME -p$ADMIN_PASSWORD -e "show global variables like '%wsrep_desync%'")
echo "Turning Doner mode off: $DONER_STATUS"
if [ ! $? -eq 0 ]; then
  echo "Unable to turn on DB doner mode on $SERVER_NAME Doner Value is: $DONER_STATUS" | notify_email
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
  echo "Unable to find last backup dir under $LOCAL_BACKUP_DIR" | notify_email
  exit 1
fi

echo "COMPRESSING BACKUP FILE $(date)"
# Compress the current backup dir to transport
cd $LOCAL_BACKUP_DIR
tar --remove-files -I pigz -cvf ${SERVER_NAME}-${CURRENT_BACKUP_DIR}.tar.gz ${CURRENT_BACKUP_DIR}
if [ ! $? -eq 0 ]; then
  echo "Unable to tar up the current backup ${LOCAL_BACKUP_DIR}/${SERVER_NAME}-${CURRENT_BACKUP_DIR}" | notify_email
  exit 1
fi

# Remove old mysql backup data to conserve space
START_TIME="$(date)"
echo "Removing old mysql exploded data $(date)"
ssh -i ${SSH_KEY} ubuntu@"${JUMP_HOST}" -t ssh -i ${SSH_KEY} ubuntu@"${AWS_DB_HOST}" "sudo rm -rf /ssd_data/mysql_migration/*"
if [ ! $? -eq 0 ]; then
  echo "Unable to Remove exploded mysql dir on $AWS_DB_HOST" | notify_email
  exit 1
fi

#######################################################
# DATABASE CUTOVER LOGIC                              #
#                                                     #
# Migrate today's db archive to AWS first db node     #
# Comment out to prevent archive upload and expansion #
#######################################################
percona_node_forklift

# Turn down nodes to receive data import
stop_percona_node ubuntu@dbm4
stop_percona_node ubuntu@dbm3
stop_percona_node ubuntu@dbm2
stop_percona_node ubuntu@dbm1

# Configure first node in the cluster
prepare_percona_node ubuntu@dbm1
start_percona_node ubuntu@dbm1

# Prepare adjoining nodes to replicate from first node in the cluster
prepare_percona_node ubuntu@dbm2
prepare_percona_node ubuntu@dbm3
prepare_percona_node ubuntu@dbm4

# Replicate data from first node in cluster
start_percona_node ubuntu@dbm2
start_percona_node ubuntu@dbm3
start_percona_node ubuntu@dbm4

END_TIME="$(date)"
echo "MYSQL DATA FORKLIFT STARTED AT: ${START_TIME} FINISHED AT ${END_TIME}"

# Cleanup local backup directory
find ${LOCAL_BACKUP_DIR} -name "*.gz" -type f -daystart -mtime +0 -exec rm -f {} \;
