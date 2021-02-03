#!/bin/sh

set -euxo pipefail

if [ -n "${OPENRC:-}" ] ; then
    . $OPENRC
fi

scriptdir=$( dirname $0 )

PROPERTIES_FILE=${PROPERTIES_FILE:-${1:-$scriptdir/demo-heat-properties.yaml}}
STACK_NAME=${STACK_NAME:-$USER.demo.test}
STACK_FILE=${STACK_FILE:-$scriptdir/demo-heat-template.yaml}
SERVER_NAME=${SERVER_NAME:-$USER.demo.test}
declare -A hosts=([machineA]="" [machineB]="" [machineC]="")
ANSIBLE_USER=${ANSIBLE_USER:-demo}

if [ -z "$START_STEP" ] ; then
    echo Error: must define START_STEP
    exit 1
fi

wait_until_cmd() {
    ii=$3
    interval=${4:-10}
    while [ $ii -gt 0 ] ; do
        $1 $2 && break
        sleep $interval
        ii=`expr $ii - $interval`
    done
    if [ $ii -le 0 ] ; then
        return 1
    fi
    return 0
}

get_machine() {
    nova list | awk -v pat=$1 '$0 ~ pat {print $2}'
}

get_stack() {
    openstack stack list | awk -v pat=$1 '$0 ~ pat {print $2}'
}

cleanup_old_machine_and_stack() {
    stack=`get_stack $STACK_NAME`
    if [ -n "$stack" ] ; then
        openstack stack delete -y $stack || openstack stack delete $stack
    fi

    if [ -n "$stack" ] ; then
        wait_s_d() {
            status=`openstack stack list | awk -v ss=$1 '$0 ~ ss {print $6}'`
            if [ "$status" = "DELETE_FAILED" ] ; then
                # try again
                openstack stack delete -y $1 || openstack stack delete $stack
                return 1
            fi
            test -z "`get_stack $1`"
        }
        wait_until_cmd wait_s_d $STACK_NAME 400 20
    fi

    mach=`get_machine $SERVER_NAME`
    if [ -n "$mach" ] ; then
        nova delete $mach
    fi

    if [ -n "$mach" ] ; then
        wait_n_d() { nova show $1 > /dev/null ; }
        wait_until_cmd wait_n_d $mach 400 20
    fi
}

get_external_ip() {
    ip=`openstack stack output show $1 $2 -c output_value -f value`
    if [ -n "$ip" ] ; then
        echo $ip
        return 0
    fi
    return 1
}

get_mach_status() {
    nova console-log $SERVER_NAME
}

wait_for_stack_create() {
    status=`openstack stack list | awk -v ss=$1 '$0 ~ ss {print $6}'`
    if [ -z "${status:-}" ] ; then
        return 1 # not created yet
    elif [ $status = "CREATE_IN_PROGRESS" ] ; then
        return 1
    elif [ $status = "CREATE_COMPLETE" ] ; then
        return 0
    elif [ $status = "CREATE_FAILED" ] ; then
        echo could not create stack
        openstack stack show $STACK_NAME
        exit 1
    else
        echo unknown stack create status $status
        return 1
    fi
    return 0
}

create_stack_and_machs_get_external_ips() {
    openstack stack create -e $PROPERTIES_FILE \
              -t $STACK_FILE $STACK_NAME

    wait_until_cmd wait_for_stack_create $STACK_NAME 600

    stack=`get_stack $STACK_NAME`
    wait_until_cmd get_external_ip "$stack machineA_ip" 400
}

if [ "$START_STEP" = clean ] ; then
    cleanup_old_machine_and_stack
    START_STEP=create
fi

ip=
stack=
if [ "$START_STEP" = create ] ; then
    create_stack_and_machs_get_external_ips
    START_STEP=inventory
fi

if [ "$START_STEP" = inventory ] ; then
    if [ -z "$stack" ] ; then
        stack=`get_stack $STACK_NAME`
    fi
    iplist=""
    for ipname in ${!hosts[*]} ; do
        hosts[$ipname]=$(get_external_ip $stack ${ipname}_ip)
    done
    INVENTORY=${INVENTORY:-inventory.yml}
    echo "all:" > $INVENTORY
    echo "  hosts:" >> $INVENTORY
    for ipname in ${!hosts[*]} ; do
        echo "    $ipname:" >> $INVENTORY
        echo "      ansible_host: ${hosts[$ipname]}" >> $INVENTORY
        echo "      ansible_ssh_common_args: -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no" >> $INVENTORY
        echo "      ansible_user: ${ANSIBLE_USER}" >> $INVENTORY
        echo "      ansible_become: true" >> $INVENTORY
    done
fi
