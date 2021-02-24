#!/bin/bash

############# Execute custom scripts ##############
function runUserScripts {

  SCRIPTS_ROOT="$1";

  # Check whether parameter has been passed on
  if [ -z "$SCRIPTS_ROOT" ]; then
    echo "$0: No SCRIPTS_ROOT passed on, no scripts will be run";
    exit 1;
  fi;
  
  # Execute custom provided files (only if directory exists and has files in it)
  if [ -d "$SCRIPTS_ROOT" ] && [ -n "$(ls -A $SCRIPTS_ROOT)" ]; then
      
    echo "";
    echo "Executing user defined scripts"
  
    for f in $SCRIPTS_ROOT/*; do
        case "$f" in
            *.sh)     echo "$0: running $f"; . "$f" ;;
            *.sql)    echo "$0: running $f"; echo "exit" | su -p oracle -c "$ORACLE_HOME/bin/sqlplus / as sysdba @$f"; echo ;;
            *)        echo "$0: ignoring $f" ;;
        esac
        echo "";
    done
    
    echo "DONE: Executing user defined scripts"
    echo "";
  
  fi;
  
}

########### Move DB files ############
function moveFiles {
   if [ ! -d $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID ]; then
      su -p oracle -c "mkdir -p $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/"
   fi;
   
   su -p oracle -c "mv $ORACLE_HOME/dbs/spfile$ORACLE_SID.ora $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/"
   su -p oracle -c "mv $ORACLE_HOME/dbs/orapw$ORACLE_SID $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/"
   su -p oracle -c "mv $ORACLE_HOME/network/admin/listener.ora $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/"
   su -p oracle -c "mv $ORACLE_HOME/network/admin/tnsnames.ora $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/"
   mv /etc/sysconfig/oracle-xe $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/

   cp /etc/oratab $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/

   symLinkFiles;
}

########### Symbolic link DB files ############
function symLinkFiles {

   if [ ! -L $ORACLE_HOME/dbs/spfile$ORACLE_SID.ora ]; then
      ln -s $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/spfile$ORACLE_SID.ora $ORACLE_HOME/dbs/spfile$ORACLE_SID.ora
   fi;
   
   if [ ! -L $ORACLE_HOME/dbs/orapw$ORACLE_SID ]; then
      ln -s $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/orapw$ORACLE_SID $ORACLE_HOME/dbs/orapw$ORACLE_SID
   fi;
   
   if [ ! -L $ORACLE_HOME/network/admin/listener.ora ]; then
      ln -sf $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/listener.ora $ORACLE_HOME/network/admin/listener.ora
   fi;
   
   if [ ! -L $ORACLE_HOME/network/admin/tnsnames.ora ]; then
      ln -sf $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/tnsnames.ora $ORACLE_HOME/network/admin/tnsnames.ora
   fi;
   
   if [ ! -L /etc/sysconfig/oracle-xe ]; then
      ln -s $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/oracle-xe /etc/sysconfig/oracle-xe
   fi;

   cp $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/oratab /etc/oratab
}

########### SIGTERM handler ############
function _term() {
   echo "Stopping container."
   echo "SIGTERM received, shutting down database!"
  /etc/init.d/oracle-xe stop
}

########### SIGKILL handler ############
function _kill() {
   echo "SIGKILL received, shutting down database!"
   /etc/init.d/oracle-xe stop
}

############# Create DB ################
function createDB {
   # Auto generate ORACLE PWD if not passed on
   export ORACLE_PWD=${ORACLE_PWD:-"`openssl rand -hex 8`"}
   echo "ORACLE PASSWORD FOR SYS AND SYSTEM: $ORACLE_PWD";

   # configure
   echo "#This is a configuration file for automatic starting of the Oracle
#Database and listener at system startup.It is generated By running
#'/etc/init.d/oracle-xe configure'.Please use that method to modify this 
#file

# ORACLE_DBENABLED:'true' means to load the Database at system boot.
ORACLE_DBENABLED=true

# LISTENER_PORT: Database listener
LISTENER_PORT=1521

# HTTP_PORT : HTTP port for Oracle Application Express
HTTP_PORT=8080

# Configuration : Check whether configure has been done or not
CONFIGURE_RUN=true
" > /etc/sysconfig/oracle-xe
   
   # Listener 
   echo "# listener.ora Network Configuration File:
         
         SID_LIST_LISTENER = 
           (SID_LIST =
             (SID_DESC =
               (SID_NAME = PLSExtProc)
               (ORACLE_HOME = $ORACLE_HOME)
               (PROGRAM = extproc)
             )
           )
         
         LISTENER =
           (DESCRIPTION_LIST =
             (DESCRIPTION =
               (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC_FOR_XE))
               (ADDRESS = (PROTOCOL = TCP)(HOST = 0.0.0.0)(PORT = 1521))
             )
           )
         
         DEFAULT_SERVICE_LISTENER = (XE)" > $ORACLE_HOME/network/admin/listener.ora

   # TNS Names.ora
   echo "# tnsnames.ora Network Configuration File:

XE =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 0.0.0.0)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = XE)
    )
  )

EXTPROC_CONNECTION_DATA =
  (DESCRIPTION =
     (ADDRESS_LIST =
       (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC_FOR_XE))
     )
     (CONNECT_DATA =
       (SID = PLSExtProc)
       (PRESENTATION = RO)
     )
  )
" > $ORACLE_HOME/network/admin/tnsnames.ora

   su -p oracle -c "lsnrctl start"

   # make some required directories it not exists
   su -p oracle -c "mkdir -p $ORACLE_BASE/oradata/$ORACLE_SID"
   su -p oracle -c "mkdir -p $ORACLE_BASE/admin/$ORACLE_SID/adump"
   su -p oracle -c "mkdir -p $ORACLE_BASE/fast_recovery_area"

   # Check init-db.tar format
   if [ -f $ORACLE_BASE/scripts/setup/init-db.tar ]; then
      (cd $ORACLE_BASE/scripts/setup;tar xf init-db.tar)
   fi;

   # Check init-db.tar.gz format
   if [ -f $ORACLE_BASE/scripts/setup/init-db.tar.gz ]; then
      (cd $ORACLE_BASE/scripts/setup;tar xfz init-db.tar.gz)
   fi;

   # Check whether database already exists
   if [ -f $ORACLE_BASE/scripts/setup/spfile.bks ]; then
      # start process of restore from rman full backup, first spfile
      su -p oracle -c "rman target /<<EOF
startup nomount force;
restore spfile from '$ORACLE_BASE/scripts/setup/spfile.bks';
shutdown immediate;
startup nomount;
exit;
EOF"

      # begin restore if control files are present
      if [ -f $ORACLE_BASE/scripts/setup/control.bks ]; then
         su -p oracle -c "rman target /<<EOF
restore controlfile from '$ORACLE_BASE/scripts/setup/control.bks';
alter database mount;
restore database;
report schema;
recover database noredo;
alter database open resetlogs;
exit;
EOF"
      fi;

      # reset password for SYS
      orapwd file=$ORACLE_HOME/dbs/orapw$ORACLE_SID password=$ORACLE_PWD ignorecase=n force=y
      chown oracle:dba $ORACLE_HOME/dbs/orapw$ORACLE_SID
      echo "$ORACLE_SID:$ORACLE_HOME:N" >> /etc/oratab
      chown oracle:dba /etc/oratab
   fi;
  # Move database operational files to oradata
  moveFiles;
}

############# MAIN ################

# Set SIGTERM handler
trap _term SIGTERM

# Set SIGKILL handler
trap _kill SIGKILL

# Check whether database already exists
if [ -d $ORACLE_BASE/oradata/$ORACLE_SID ]; then
   symLinkFiles;
   # Make sure audit file destination exists
   if [ ! -d $ORACLE_BASE/admin/$ORACLE_SID/adump ]; then
      su -p oracle -c "mkdir -p $ORACLE_BASE/admin/$ORACLE_SID/adump"
   fi;
fi;

/etc/init.d/oracle-xe start | grep -qc "Oracle Database 11g Express Edition is not configured"
if [ "$?" == "0" ]; then
   # Check whether container has enough memory
   if [ `df -Pk /dev/shm | tail -n 1 | awk '{print $2}'` -lt 1048576 ]; then
      echo "Error: The container doesn't have enough memory allocated."
      echo "A database XE container needs at least 1 GB of shared memory (/dev/shm)."
      echo "You currently only have $((`df -Pk /dev/shm | tail -n 1 | awk '{print $2}'`/1024)) MB allocated to the container."
      exit 1;
   fi;
   
   # Create database
   createDB;
   
   # Execute custom provided setup scripts
   runUserScripts $ORACLE_BASE/scripts/setup
fi;

# Check whether database is up and running
$ORACLE_BASE/$CHECK_DB_FILE
if [ $? -eq 0 ]; then
  echo "#########################"
  echo "DATABASE IS READY TO USE!"
  echo "#########################"

  # Execute custom provided startup scripts
  runUserScripts $ORACLE_BASE/scripts/startup

else
  echo "#####################################"
  echo "########### E R R O R ###############"
  echo "DATABASE SETUP WAS NOT SUCCESSFUL!"
  echo "Please check output for further info!"
  echo "########### E R R O R ###############"
  echo "#####################################"
fi;

echo "The following output is now a tail of the alert.log:"
tail -f $ORACLE_BASE/diag/rdbms/*/*/trace/alert*.log &
childPID=$!
wait $childPID