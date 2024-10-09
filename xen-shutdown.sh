#!/bin/bash
#
# This script will shutdown all running VMs in a Xen pool, all slave Xen 
# hosts, and eventually the Xen pool master. 
#
# Communication between Xen hosts is required for the sucessfull shutdown
# of all VMs/hosts; ensure that the network infrastructure between Xen 
# hosts does not loose power before this script completes execution. 
#
# This script will only run on the pool master though should be installed
# on all Xen hosts in the case of a change in master.
#

# Log file location
log_file="/var/log/xen-shutdown.log"

function exists_in_list () {
	LIST=$1
	DELIMITER=$2
	VALUE=$3

	[[ "$LIST" =~ ($DELIMITER|^)$VALUE($DELIMITER|$) ]]
}

function get_running_vms () {
	xe vm-list power-state=running is-control-domain=false --minimal | tr , "\n"
}

function get_running_vms_exclude_late_shutdown () {
	running_vm_uuids=( $(get_running_vms) )
	late_shutdown_vm_uuids=( $(xe vm-list power-state=running is-control-domain=false tags:contains="Late-Shutdown" --minimal) )

	vm_uuids=()
	for uuid in ${running_vm_uuids[@]}; do
		if ! exists_in_list "${late_shutdown_vm_uuids}" "," "$uuid"; then
			vm_uuids+=($uuid)
		fi
	done
	echo ${vm_uuids[@]}
}

function log_date () {
	# logging function formatted to include a date
	echo -e "$(date "+%Y/%m/%d %H:%M:%S"): $1" >> "$log_file" #2>&1
}

function shutdown_vms () {
	if [ "$1" = "initial" ]; then
		VM_LIST_FUNC="get_running_vms_exclude_late_shutdown"

		vm_graceful_timeout=180
		vm_forceful_timeout=80
		vm_powerreset_timeout=60
	elif [ "$1" = "all" ]; then
		VM_LIST_FUNC="get_running_vms"

		vm_graceful_timeout=180
		vm_forceful_timeout=80
		vm_powerreset_timeout=60
	else
		echo "Invalid parameter supplied to shutdown_vms: $1"
		return 1
	fi

	# Attempt to gracefully shutdown running VMs
	vm_uuids=( $($VM_LIST_FUNC) )
	for uuid in "${vm_uuids[@]}"; do
		vm_name="$(xe vm-param-get uuid=$uuid param-name=name-label)"
		log_date "Shutting down VM $vm_name (UUID: $uuid)"
		xe vm-shutdown uuid=$uuid &
		sleep 1
	done
	if wait_for_vm_shutdown $vm_graceful_timeout $VM_LIST_FUNC; then
		return 0
	fi

	# Attempt to forcefully shutdown any VMs still running
	vm_uuids=( $($VM_LIST_FUNC) )
	for vm_uuid in "${vm_uuids[@]}"; do
		vm_name="$(xe vm-param-get uuid=$vm_uuid param-name=name-label)"
		log_date "Forcefully shutting down VM $vm_name (UUID: $uuid)"
		xe vm-shutdown uuid=$vm_uuid force=true &
		sleep 1
	done
	if wait_for_vm_shutdown $vm_forceful_timeout $VM_LIST_FUNC; then
		return 0
	fi

	# Attempt to power reset any VMs still running
	vm_uuids=( $($VM_LIST_FUNC) )
	for vm_uuid in "${vm_uuids[@]}"; do
		vm_name="$(xe vm-param-get uuid=$vm_uuid param-name=name-label)"
		log_date "Resetting power for VM $vm_name (UUID: $uuid)"
		xe vm-reset-powerstate uuid=$vm_uuid force=true &
		sleep 1
	done
	if wait_for_vm_shutdown $vm_powerreset_timeout $VM_LIST_FUNC; then
		return 0
	else
		return 1
	fi
}

function shutdown_xenhosts () {
	xen_slave_timeout=240

	# Get UUID of all hosts
	xen_uuids=( $(xe host-list --minimal | tr , "\n" ) )

	# Get UUID of this host (master)
	xen_master_uuid=$( cat /etc/xensource-inventory | grep -i installation_uuid | awk -F"'[[:blank:]]*" '{print $2}' )

	# Get UUID of slave hosts
	xen_slave_uuids=()
	for uuid in ${xen_uuids[@]}; do
		if [[ $uuid != $xen_master_uuid ]]; then
			xen_slave_uuids+=($uuid)
		fi
	done

	# Shutdown all slave hosts
	for uuid in ${xen_slave_uuids[@]}; do
		slave_name=$(xe host-param-get uuid=$uuid param-name=name-label)
		log_date "Disabling slave host $slave_name (UUID: $uuid)"
		xe host-disable uuid=$uuid
		sleep 1
		log_date "Shutting down slave host $slave_name (UUID: $uuid)"
		xe host-shutdown uuid=$uuid &
		sleep 1
	done

	# Start timer for timeout
	start_time=$SECONDS

	# Loop until all slave hosts do not respond to ping or timeout
	sleep 10
	for uuid in ${xen_slave_uuids[@]}; do
		if [ $(( SECONDS - start_time )) -lt $xen_slave_timeout ]; then
			while true; do
				ping -c 1 $(xe host-param-get uuid=$uuid param-name=address) > /dev/null 2> /dev/null
				# If slave replies to ping
				if [ $? -eq 0 ]; then
					log_date "Not all slave hosts shutdown, continuing to wait..."
					sleep 10
					continue
				else
					sleep 2
					break
				fi
			done
		else
			log_date "Slave host shutdown timeout, proceeding with master host shutdown"
		fi
	done

	# Shutdown master host
	xen_master_name="$(xe host-param-get uuid=$xen_master_uuid param-name=name-label)"
	log_date "Disabling master host $xen_master_name (UUID: $xen_master_uuid)"
	xe host-disable uuid=$xen_master_uuid
	sleep 1
	log_date "Shutting down master host $xen_master_name (UUID: $xen_master_uuid)"
	xe host-shutdown uuid=$xen_master_uuid
	sleep 1
}

function wait_for_vm_shutdown () {
	WAIT_TIME=$1
	VM_LIST_FUNC=$2

	start_time=$SECONDS
	sleep 10
	while [ $(( SECONDS - start_time )) -lt $WAIT_TIME ]; do
		vm_uuids=( $($VM_LIST_FUNC) )
		if [ ${#vm_uuids[@]} -eq 0 ]; then
			return 0
		else
			log_date "Not all VMs shutdown, continuing to wait..."
			sleep 10
		fi
	done

	return 1
}

function unplug_remote_srs () {
	nfs_sr_uuids=( $(xe sr-list type=nfs --minimal | tr , "\n") )
	for uuid in ${nfs_sr_uuids[@]}; do
		sr_pbd_uuids=$(xe sr-param-get uuid=$uuid param-name=PBDs --minimal | tr , "\n")
		for pbd_uuid in ${sr_pbd_uuids[@]}; do
			pbd_name=$(xe pbd-param-get uuid=$pbd_uuid param-name=sr-name-label)
			log_date "Unplugging PBD $pbd_name (UUID: $pbd_uuid)"
			xe pbd-unplug uuid=$pbd_uuid
			sleep 1
		done
	done
}

function main () {
	log_date "==============================================================================="
	log_date "Received shutdown request, initiating shutdown procedure"
	log_date "==============================================================================="

	unplug_remote_srs

	if ! shutdown_vms initial; then
		log_date "Initial shutdown of VMs failed!"
		exit 1
	fi
	if ! shutdown_vms all; then
		log_date "Final shutdown of VMs failed!"
		exit 1
	fi

	shutdown_xenhosts

	exit
}

# Check that host has master role
role="$(more /etc/xensource/pool.conf)"
if [[ $role == *"master"* ]]; then
	main
fi

