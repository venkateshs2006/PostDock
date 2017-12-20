#!/usr/bin/env bash
set -e

cp -f /var/pgpool_configs/$CONF_FILE_NAME $CONFIG_FILE

echo ">>> Opening access from all hosts by md5 in $HBA_FILE" #TODO: more configurable?
echo "host all all 0.0.0.0/0 md5" > $HBA_FILE

echo ">>> Adding user $PCP_USER for PCP"
echo "$PCP_USER:`pg_md5 --config-file $CONFIG_FILE $PCP_PASSWORD`" >> $PCP_FILE

echo ">>> Creating a ~/.pcppass file for $PCP_USER"
echo *:9898:$PCP_USER:$PCP_PASSWORD > ~/.pcppass
chmod 0600 ~/.pcppass

echo ">>> Adding users for md5 auth"
IFS=',' read -ra USER_PASSES <<< "$DB_USERS"
for USER_PASS in ${USER_PASSES[@]}
do
    IFS=':' read -ra USER <<< "$USER_PASS"
    echo ">>>>>> Adding user ${USER[0]}"
    pg_md5 --config-file $CONFIG_FILE --md5auth --username="${USER[0]}" "${USER[1]}"
done

echo ">>> Adding check user '$CHECK_USER' for md5 auth"
pg_md5 --config-file $CONFIG_FILE --md5auth --username="$CHECK_USER" "$CHECK_PASSWORD"

echo ">>> Adding user '$CHECK_USER' as check user"
echo "
sr_check_password = '$CHECK_PASSWORD'
sr_check_user = '$CHECK_USER'" >> $CONFIG_FILE

echo ">>> Adding user '$CHECK_USER' as health-check user"
echo "
health_check_password = '$CHECK_PASSWORD'
health_check_user = '$CHECK_USER'" >> $CONFIG_FILE

echo ">>> Adding backends"
BACKENDS_COUNT=0

IFS=',' read -ra HOSTS <<< "$BACKENDS"
for HOST in ${HOSTS[@]}
do
    ACCESSABLE_NODE=false

    IFS=':' read -ra INFO <<< "$HOST"

    #default values
    NUM=""
    HOST=""
    PORT="5432"
    WEIGHT=1
    DIR="/var/lib/postgresql/data"
    FLAG="ALLOW_TO_FAILOVER"

    #custom values
    [[ "${INFO[0]}" != "" ]] && NUM="${INFO[0]}"
    [[ "${INFO[1]}" != "" ]] && HOST="${INFO[1]}"
    [[ "${INFO[2]}" != "" ]] && PORT="${INFO[2]}"
    [[ "${INFO[3]}" != "" ]] && WEIGHT="${INFO[3]}"
    [[ "${INFO[4]}" != "" ]] && DIR="${INFO[4]}"
    [[ "${INFO[5]}" != "" ]] && FLAG="${INFO[5]}"


    echo ">>>>>> Waiting for backend $NUM to start pgpool (WAIT_BACKEND_TIMEOUT=$WAIT_BACKEND_TIMEOUT)"
    dockerize -wait tcp://$HOST:$PORT -timeout "$WAIT_BACKEND_TIMEOUT"s && ACCESSABLE_NODE=true

    $ACCESSABLE_NODE || echo ">>>>>> Will not add node $NUM - it's unreachable!"
    $ACCESSABLE_NODE || continue

    echo ">>>>>> Adding backend $NUM"
    echo "
backend_hostname$NUM = '$HOST'
backend_port$NUM = $PORT
backend_weight$NUM = $WEIGHT
backend_data_directory$NUM = '$DIR'
backend_flag$NUM = '$FLAG'
" >> $CONFIG_FILE

    BACKENDS_COUNT=$((BACKENDS_COUNT+1))

done

echo ">>> Checking if we have enough backends to start"
if [ "$REQUIRE_MIN_BACKENDS" != "0" ] && [ "$BACKENDS_COUNT" -lt "$REQUIRE_MIN_BACKENDS" ]; then
    echo ">>>>>> Can not start pgpool with REQUIRE_MIN_BACKENDS=$REQUIRE_MIN_BACKENDS, BACKENDS_COUNT=$BACKENDS_COUNT"
    exit 1
else
    echo ">>>>>> Will start pgpool REQUIRE_MIN_BACKENDS=$REQUIRE_MIN_BACKENDS, BACKENDS_COUNT=$BACKENDS_COUNT"
fi


echo ">>> Configuring $CONFIG_FILE"
echo "
#------------------------------------------------------------------------------
# AUTOGENERATED
#------------------------------------------------------------------------------
" >> $CONFIG_FILE
IFS=',' read -ra CONFIG_PAIRS <<< "$CONFIGS"
for CONFIG_PAIR in "${CONFIG_PAIRS[@]}"
do
    IFS=':' read -ra CONFIG <<< "$CONFIG_PAIR"
    VAR="${CONFIG[0]}"
    VAL="${CONFIG[1]}"
    sed -e "s/\(^\ *$VAR\(.*\)$\)/#\1 # overrided in AUTOGENERATED section/g" $CONFIG_FILE > /tmp/config.tmp && mv -f /tmp/config.tmp $CONFIG_FILE
    echo ">>>>>> Adding config '$VAR' with value '$VAL' "
    echo "$VAR = $VAL" >> $CONFIG_FILE
done

touch $CONFIG_FILE $PCP_FILE $HBA_FILE
chown postgres:postgres $CONFIG_FILE $PCP_FILE $HBA_FILE $POOL_PASSWD_FILE

rm -rf /var/run/postgresql/pgpool.pid #in case file exists after urgent stop

# http://www.pgpool.net/pgpool-web/contrib_docs/watchdog_master_slave_3.3/en.html#config_setuid
# chown postgres:postgres /home/apache/sbin
# chmod 4755 /sbin/ifconfig
# chmod 4755 /usr/sbin/arping

chmod -R 777 /sbin
chmod -R 777 /usr/sbin

chmod -R u+s /sbin
chmod -R u+s /usr/sbin

#chmod u+s /sbin/ifconfig
#chmod u+s /usr/sbin/arping


