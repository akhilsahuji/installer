#!/usr/bin/env bash

# Copyright 2018 The soda Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# 'stack' user is just for install keystone through devstack

create_user(){
    if id "${STACK_USER_NAME}" &> /dev/null; then
        return
    fi
    sudo useradd -s /bin/bash -d "${STACK_HOME}" -m "${STACK_USER_NAME}"
    echo "stack ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/stack
}


remove_user(){
    userdel "${STACK_USER_NAME}" -f -r
    rm /etc/sudoers.d/stack
}

devstack_local_conf(){
DEV_STACK_LOCAL_CONF=${DEV_STACK_DIR}/local.conf
cat > "$DEV_STACK_LOCAL_CONF" << DEV_STACK_LOCAL_CONF_DOCK
[[local|localrc]]
# use TryStack git mirror
GIT_BASE=$STACK_GIT_BASE

# If the "*_PASSWORD" variables are not set here you will be prompted to enter
# values for them by "stack.sh" and they will be added to "local.conf".
ADMIN_PASSWORD=$STACK_PASSWORD
DATABASE_PASSWORD=$STACK_PASSWORD
RABBIT_PASSWORD=$STACK_PASSWORD
SERVICE_PASSWORD=$STACK_PASSWORD

# Neither is set by default.
HOST_IP=$HOST_IP

# path of the destination log file.  A timestamp will be appended to the given name.
LOGFILE=\$DEST/logs/stack.sh.log

# Old log files are automatically removed after 7 days to keep things neat.  Change
# the number of days by setting "LOGDAYS".
LOGDAYS=2

ENABLED_SERVICES=mysql,key
# Using stable/queens branches
# ---------------------------------
KEYSTONE_BRANCH=$STACK_BRANCH
KEYSTONECLIENT_BRANCH=$STACK_BRANCH
DEV_STACK_LOCAL_CONF_DOCK
chown stack:stack "$DEV_STACK_LOCAL_CONF"
}

hotpot_conf() {
mkdir -p $soda_CONFIG_DIR
cat > "$soda_CONFIG_DIR/soda.conf" << soda_GLOBAL_CONFIG_DOC
[keystone_authtoken]
memcached_servers = $HOST_IP:11211
signing_dir = /var/cache/soda
cafile = /opt/stack/data/ca-bundle.pem
auth_uri = http://$HOST_IP/identity
project_domain_name = Default
project_name = service
user_domain_name = Default
password = $STACK_PASSWORD
# Whether to encrypt the password. If enabled, the value of the password must be ciphertext.
enable_encrypted = False
# Encryption and decryption tool. Default value is aes. The decryption tool can only decrypt the corresponding ciphertext.
pwd_encrypter = aes
username = $soda_SERVER_NAME
auth_url = http://$HOST_IP/identity
auth_type = password

soda_GLOBAL_CONFIG_DOC

cp "$TOP_DIR/../../conf/policy.json" "$soda_CONFIG_DIR"
}

gelato_conf() {
    local compose_file=/opt/soda-gelato-linux-amd64/docker-compose.yml
    sed -i "s,OS_AUTH_AUTHSTRATEGY=.*$,OS_AUTH_AUTHSTRATEGY=keystone," $compose_file
    sed -i "s,OS_AUTH_URL=.*$,OS_AUTH_URL=http://$HOST_IP/identity," $compose_file
    sed -i "s,OS_USERNAME=.*$,OS_USERNAME=$MULTICLOUD_SERVER_NAME," $compose_file
    sed -i "s,OS_PASSWORD=.*$,OS_PASSWORD=$STACK_PASSWORD," $compose_file
    sed -i "s,IAM_HOST=.*$,IAM_HOST=$HOST_IP," $compose_file
}

keystone_credentials () {
    export OS_AUTH_URL="http://${HOST_IP}/identity"
    export OS_USERNAME=admin
    export OS_PASSWORD="${STACK_PASSWORD}"
    export OS_PROJECT_NAME=admin
    export OS_PROJECT_DOMAIN_NAME=Default
    export OS_USER_DOMAIN_NAME=Default
    export OS_IDENTITY_API_VERSION=3
}

wait_for_keystone () {
    local count=0
    local interval=${1:-10}
    local times=${2:-12}

    while true
    do
        # get a token to check if keystone is working correctly or not.
        # keystone credentials such as OS_USERNAME must be set before.
        python ${TOP_DIR}/ministone.py token_issue
        if [ "$?" == "0" ]; then
            return
        fi
        count=`expr ${count} \+ 1`
        if [ ${count} -ge ${times} ]; then
            echo "ERROR: keystone didn't come up. Aborting..."
            exit 1
        fi
        sleep ${interval}
    done
}

create_user_and_endpoint_for_hotpot(){
    . "$DEV_STACK_DIR/openrc" admin admin
    if openstack user show $soda_SERVER_NAME &>/dev/null; then
        return
    fi

    openstack user create --domain default --password "$STACK_PASSWORD" "$soda_SERVER_NAME"
    openstack role add --project service --user "$soda_SERVER_NAME" admin
    openstack group create service
    openstack group add user service "$soda_SERVER_NAME"
    openstack role add service --project service --group service
    openstack group add user admins admin
    openstack service create --name "soda$soda_VERSION" --description "soda Block Storage" "soda$soda_VERSION"
    openstack endpoint create --region RegionOne "soda$soda_VERSION" public "http://$HOST_IP:50040/$soda_VERSION/%(tenant_id)s"
    openstack endpoint create --region RegionOne "soda$soda_VERSION" internal "http://$HOST_IP:50040/$soda_VERSION/%(tenant_id)s"
    openstack endpoint create --region RegionOne "soda$soda_VERSION" admin "http://$HOST_IP:50040/$soda_VERSION/%(tenant_id)s"
}

create_user_and_endpoint_for_gelato(){
    . "$DEV_STACK_DIR/openrc" admin admin
    if openstack user show $MULTICLOUD_SERVER_NAME &>/dev/null; then
        return 
    fi
    openstack user create --domain default --password "$STACK_PASSWORD" "$MULTICLOUD_SERVER_NAME"
    openstack role add --project service --user "$MULTICLOUD_SERVER_NAME" admin
    openstack group create service
    openstack group add user service "$MULTICLOUD_SERVER_NAME"
    openstack role add service --project service --group service
    openstack group add user admins admin
    openstack service create --name "multicloud$MULTICLOUD_VERSION" --description "Multi-cloud Block Storage" "multicloud$MULTICLOUD_VERSION"
    openstack endpoint create --region RegionOne "multicloud$MULTICLOUD_VERSION" public "http://$HOST_IP:8089/$MULTICLOUD_VERSION/%(tenant_id)s"
    openstack endpoint create --region RegionOne "multicloud$MULTICLOUD_VERSION" internal "http://$HOST_IP:8089/$MULTICLOUD_VERSION/%(tenant_id)s"
    openstack endpoint create --region RegionOne "multicloud$MULTICLOUD_VERSION" admin "http://$HOST_IP:8089/$MULTICLOUD_VERSION/%(tenant_id)s"
}

delete_redundancy_data() {
    . "$DEV_STACK_DIR/openrc" admin admin
    openstack project delete demo
    openstack project delete alt_demo
    openstack project delete invisible_to_admin
    openstack user delete demo
    openstack user delete alt_demo
}

download_code(){
    if [ ! -d "${DEV_STACK_DIR}" ];then
        git clone "${STACK_GIT_BASE}/openstack-dev/devstack.git" -b "${STACK_BRANCH}" "${DEV_STACK_DIR}"
        chown stack:stack -R "${DEV_STACK_DIR}"
    fi
}

install(){
    if [ "docker" == "$1" ]
    then
        docker pull sodaio/soda-authchecker:latest
        docker run -d --privileged=true --restart=always --net=host --name=soda-authchecker sodaio/soda-authchecker:latest
        docker cp "$TOP_DIR/../../conf/keystone.policy.json" soda-authchecker:/etc/keystone/policy.json
        keystone_credentials
        wait_for_keystone
        python ${TOP_DIR}/ministone.py endpoint_bulk_update keystone "http://${HOST_IP}/identity"
    else
        create_user
        download_code
        # If keystone is ready to start, there is no need continue next step.
        if wait_for_url "http://$HOST_IP/identity" "keystone" 0.25 4; then
            return
        fi
        devstack_local_conf
        cd "${DEV_STACK_DIR}"
        su "$STACK_USER_NAME" -c "${DEV_STACK_DIR}/stack.sh" >/dev/null
        delete_redundancy_data
        cp "$TOP_DIR/../../conf/keystone.policy.json" "${KEYSTONE_CONFIG_DIR}/policy.json"
    fi
}

uninstall(){
    if [ "docker" == "$1" ]
    then
        docker stop soda-authchecker
        docker rm soda-authchecker
    else
       su "$STACK_USER_NAME" -c "${DEV_STACK_DIR}/clean.sh" >/dev/null
       su "$STACK_USER_NAME" -c "${DEV_STACK_DIR}/unstack.sh" >/dev/null
    fi
    
}

uninstall_purge() {
    rm "${STACK_HOME:?'STACK_HOME must be defined and cannot be empty'}/*" -rf
    remove_user
}

config_hotpot() {
    hotpot_conf
    if [ "docker" != "$1" ] ;then
        create_user_and_endpoint_for_hotpot
    else
        keystone_credentials
        python ${TOP_DIR}/ministone.py endpoint_bulk_update "soda$soda_VERSION" "http://${HOST_IP}:50040/$soda_VERSION/%(tenant_id)s"
    fi
}

config_gelato() {
    gelato_conf
    if [ "docker" != "$1" ] ;then
        create_user_and_endpoint_for_gelato
    else
        keystone_credentials
        python ${TOP_DIR}/ministone.py endpoint_bulk_update "multicloud$MULTICLOUD_VERSION" "http://${HOST_IP}:8089/v1beta/%(tenant_id)s"
    fi
}

# ***************************
TOP_DIR=$(cd $(dirname "$0") && pwd)

# soda configuration directory
soda_CONFIG_DIR=${soda_CONFIG_DIR:-/etc/soda}
# Keystone configuration directory
KEYSTONE_CONFIG_DIR=${KEYSTONE_CONFIG_DIR:-/etc/keystone}
if [[ -e $TOP_DIR/local.conf ]];then
    source $TOP_DIR/local.conf
fi
source "$TOP_DIR/util.sh"
source "$TOP_DIR/sdsrc"

case "$# $1" in
    "2 install")
    echo "Starting install keystone..."
    install $2
    ;;
    "2 uninstall")
    echo "Starting uninstall keystone..."
    uninstall $2
    ;;
    "3 config")
    [[ X$2 != Xhotpot && X$2 != Xgelato ]] && echo "config type must be hotpot or gelato" && exit 1
    echo "Starting config $2 ..."
    config_$2 $3
    ;;
    "1 uninstall_purge")
    echo "Starting uninstall purge keystone..."
    uninstall_purge
    ;;
     *)
    echo "Usage: $(basename $0) <install|config|uninstall|uninstall_purge> [parameters ...]"
    exit 1
    ;;
esac
