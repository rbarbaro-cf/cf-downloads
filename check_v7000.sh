#!/bin/bash

# Original Author:	Lazzarin Alberto
# Original Date:	10-04-2013
# Original Version:	1.0
#
# Editing Author:	Niels van Aert
# Editing Date:		30-04-2019
# Editing Version:	1.4.1
#
# Editing Author:	Rich Barbaro
# Editing Date:		25-02-2026
# Editing Version:	1.6.0
#
# This plugin checks various attributes of a Lenovo / IBM Storwize v3700 / v7000.
# To use this script you need to create a so called Monitoring user on the SAN with an SSH certificate.
# The help is included into the script.
#
# CHANGELOG
#
# 1.6.0 - Rich Barbaro
# Added lseventlog check - reports all unfixed alerts, no exclusions.
# Added lsportfc check with node ID, speed mismatch detection.
# Converted all dynamic-column checks to single SSH call.
# Added LogLevel=ERROR to suppress SSH warnings in Nagios output.
#
# 1.5.0 - Rich Barbaro
# Added SSH connectivity validation (lssystem) - prevents false OKs.
# Added lspoolspace and lsvdiskspace checks with -w/-c thresholds.
# Added data guards on all legacy checks for empty SSH responses.
# Fixed temp file variable interpolation (${storage}_${query}).
# Fixed $mdisk_name typo in lsvdisk, $disk_status typo in lsdrive.
# Added HOME export for Nagios service execution context.
# Added rm -f to prevent errors on missing tmp files.
#
# 1.4.1 - Niels van Aert
# Added the option to specify -i to specify an identity file.
# Commented out rm $tmp_file_OK as it was throwing an error on recent firmware.
# Fixed incorrect line-formatting which caused the plugin to refuse to run.
#
# 1.4 - Andrea Tedesco
# Add check of v7000 Unified.
#
# 1.3 - Ivan Bergantin
# Add short output in service status view, detailed output in service info view.
#
# 1.2 - Feilong
# Add check of mirror status between two volumes on two IBM V7000.
#
# 1.1
# Change login method from plink to ssh. Add OK/ATTENTION in output.
#
# 1.0 - Lazzarin Alberto
# First release.
#

ssh="/usr/bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
exitCode=0
export HOME=${HOME:-/home/nagios}

while getopts 'M:U:Q:i:w:c:d:h' OPT; do
  case $OPT in
    M)  storage=$OPTARG;;
    U)  user=$OPTARG;;
    Q)  query=$OPTARG;;
    i)  identity=$OPTARG;;
    w)  warn=$OPTARG;;
    c)  crit=$OPTARG;;
    h)  hlp="yes";;
    *)  unknown="yes";;
  esac
done

# Defaults for space checks
warn=${warn:-80}
crit=${crit:-90}

# usage
HELP="
    Check an IBM Storwize v3700 / v7000 throught SSH (GPL licence)

    usage: $0 [ -M value -U value -i full-path-to-file -Q command -w value -c value -h ]

    syntax:

            -M --> IP Address
            -U --> user
            -Q --> query to storage
		lsarray
		lsdrive
		lseventlog
		lsportfc
		lsvdisk
		lsvdiskspace
		lspoolspace
		lsenclosure
		lsenclosurebattery
		lsenclosurecanister
		lsenclosurepsu
		lsenclosureslot
		lsrcrelationship
		unified
	    -i --> Provide the SSH identity file to use
	    -w --> Warning threshold % for space checks (default: 80)
	    -c --> Critical threshold % for space checks (default: 90)
            -h --> Print This Help Screen

    Note :
    This check uses the SSH protocol.
"

if [ "$hlp" = "yes" -o $# -lt 1 ]; then
        echo "$HELP"
        exit 0
fi

tmp_file=/tmp/v7000_${storage}_${query}.tmp
tmp_file_OK=/tmp/v7000_OK.tmp
outputMess=""
perfData=""

# --- SSH Connectivity Test ---
# Use lssystem as test command (echo not available in Storwize restricted shell)
$ssh $user@$storage -i $identity lssystem > /dev/null 2>&1
if [ "$?" -ne 0 ]; then
        echo -ne "CRITICAL: SSH connection failed to $storage\n"
        exit 2
fi

case $query in 
	lsarray)
		$ssh $user@$storage -i $identity $query |sed '1d' > $tmp_file

		if [ ! -s $tmp_file ]; then
			outputMess="CRITICAL: No array data returned \n"
			exitCode=2
		else
			cat $tmp_file |awk '{printf $3}' |grep -i offline
			if [ "$?" -eq "0" ]; then
				outputMess="$outputMess CRITICAL: MDisk OFFLINE \n"
			else
				outputMess="$outputMess OK: MDisks \n"
			fi

			while read line
				do
					mdisk_name=$(echo "${line}" | awk '{printf $2}')
					mdisk_status=$(echo "${line}" | awk '{printf $3}')

					if [ $mdisk_status = "online" ]; then
						outputMess="$outputMess OK: MDisks $mdisk_name status: $mdisk_status \n"
					else
						outputMess="$outputMess ATTENTION: MDisks $mdisk_name status: $mdisk_status \n"
						exitCode=2
					fi

			done < $tmp_file
		fi
	;;

	lsdrive)
                $ssh $user@$storage -i $identity $query |sed '1d' > $tmp_file

		if [ ! -s $tmp_file ]; then
			outputMess="CRITICAL: No drive data returned \n"
			exitCode=2
		else
                	cat $tmp_file |awk '{printf $2}' |grep -i offline
                	if [ "$?" -eq "0" ]; then
                        	outputMess="$outputMess CRITICAL: Disk OFFLINE \n"
                	else
                        	outputMess="$outputMess OK: Drive \n"
                	fi

			drive_total=$(/bin/cat $tmp_file |/usr/bin/wc -l)
                	while read line
                        	do
                                	drive_n=$(echo "${line}" | awk '{printf $1}')
                                	drive_status=$(echo "${line}" | awk '{printf $2}')
                                	drive_role=$(echo "${line}" | awk '{printf $4}')
                                	drive_type=$(echo "${line}" | awk '{printf $5}')
                                	drive_capacity=$(echo "${line}" | awk '{printf $6}')
                                	drive_enclosure=$(echo "${line}" | awk '{printf $10}')
                                	drive_slot=$(echo "${line}" | awk '{printf $11}')

                                	if [ $drive_status = "online" ]; then
                                        	outputMess="$outputMess OK: Drive $drive_n is online \n"
                                	else
                                        	outputMess="$outputMess ATTENTION: Disk $drive_n \nstatus: $drive_status \nrole: $drive_role \ntype: $drive_type \ncapacity: $drive_capacity \nenclosure: $drive_enclosure \nslot: $drive_slot "
                                        	exitCode=2
                                	fi

                	done < $tmp_file
		fi
	;;

	lsvdisk)
                $ssh $user@$storage -i $identity $query |sed '1d' > $tmp_file

		if [ ! -s $tmp_file ]; then
			outputMess="CRITICAL: No vdisk data returned \n"
			exitCode=2
		else
                	cat $tmp_file |awk '{printf $5}' |grep -i offline
                	if [ "$?" -eq "0" ]; then
                        	outputMess="$outputMess CRITICAL: VDisk OFFLINE \n"
                	else
                        	outputMess="$outputMess OK: VDisk \n"
                	fi

                	while read line
                        	do
                                	vdisk_name=$(echo "${line}" | awk '{printf $2}')
                                	vdisk_status=$(echo "${line}" | awk '{printf $5}')

                                	if [ $vdisk_status = "online" ]; then
                                        	outputMess="$outputMess OK: VDisks $vdisk_name status: $vdisk_status \n"
                                	else
                                        	outputMess="$outputMess ATTENTION: VDisks $vdisk_name status: $vdisk_status \n"
                                        	exitCode=2
                                	fi

                	done < $tmp_file
		fi
	;;

	lsenclosure)
                $ssh $user@$storage -i $identity $query |sed '1d' > $tmp_file

		if [ ! -s $tmp_file ]; then
			outputMess="CRITICAL: No enclosure data returned \n"
			exitCode=2
		else
                	cat $tmp_file |awk '{printf $2}' |grep -i offline
                	if [ "$?" -eq "0" ]; then
                        	outputMess="$outputMess CRITICAL: Enclosure OFFLINE \n"
                	else
                        	outputMess="$outputMess OK: Enclosure \n"
                	fi

                	while read line
                        	do
                                	enc_n=$(echo "${line}" | awk '{printf $1}')
                                	enc_status=$(echo "${line}" | awk '{printf $2}')
                                	enc_pn=$(echo "${line}" | awk '{printf $7}')
                                	enc_sn=$(echo "${line}" | awk '{printf $8}')

                                	if [ $enc_status = "online" ]; then
                                        	outputMess="$outputMess OK: Enclosure $enc_n status: $enc_status \n"
                                	else
                                        	outputMess="$outputMess ATTENTION: Enclosure $enc_n status: $enc_status sn: $enc_sn pn: $enc_pn \n"
                                        	exitCode=2
                                	fi

                	done < $tmp_file
		fi
	;;

	lsenclosurebattery)
                $ssh $user@$storage -i $identity $query |sed '1d' > $tmp_file

		if [ ! -s $tmp_file ]; then
			outputMess="CRITICAL: No battery data returned \n"
			exitCode=2
		else
                	cat $tmp_file |awk '{printf $3}' |grep -i offline
                	if [ "$?" -eq "0" ]; then
                        	outputMess="$outputMess CRITICAL: Battery OFFLINE \n"
                	else
                        	outputMess="$outputMess OK: Battery \n"
                	fi

                	while read line
                        	do
                                	batt_n=$(echo "${line}" | awk '{printf $2}')
                                	batt_status=$(echo "${line}" | awk '{printf $3}')
                                	batt_charge=$(echo "${line}" | awk '{printf $4}')
                                	batt_rec=$(echo "${line}" | awk '{printf $5}')
                                	batt_charge=$(echo "${line}" | awk '{printf $6}')
					batt_eol=$(echo "${line}" | awk '{printf $7}')

                                	if [ $batt_status = "online" -a  $batt_rec = "no" -a $batt_charge = "100" -a $batt_eol = "no" ]; then
                                        	outputMess="$outputMess OK: Battery $batt_n status: $batt_status \n"
                                	else
                                        	outputMess="$outputMess ATTENTION: Battery $batt_n status: $batt_statusn recharge: $batt_rec charged: $batt_charge eol: $batt_eol \n"
                                        	exitCode=2
                                	fi

                	done < $tmp_file
		fi
	;;

	lsenclosurecanister)
                $ssh $user@$storage -i $identity $query |sed '1d' > $tmp_file

		if [ ! -s $tmp_file ]; then
			outputMess="CRITICAL: No canister data returned \n"
			exitCode=2
		else
                	cat $tmp_file |awk '{printf $3}' |grep -i offline
                	if [ "$?" -eq "0" ]; then
                        	outputMess="$outputMess CRITICAL: Canister OFFLINE \n"
                	else
                        	outputMess="$outputMess OK: Canister \n"
                	fi

                	while read line
                        	do
                                	can_id=$(echo "${line}" | awk '{printf $2}')
                                	can_enc_id=$(echo "${line}" | awk '{printf $1}')
                                	can_stat=$(echo "${line}" | awk '{printf $3}')
                                	can_type=$(echo "${line}" | awk '{printf $4}')

                                	if [ $can_stat = "online" ]; then
                                        	outputMess="$outputMess OK: Canister $can_id enclosure: $can_enc_id status: $can_stat \n"
                                	else
                                        	outputMess="$outputMess ATTENTION: Canister $can_id enclosure: $can_enc_id status: $can_stat type: $can_type \n"
                                        	exitCode=2
                                	fi

                	done < $tmp_file
		fi
	;;

	lsenclosurepsu)
                $ssh $user@$storage -i $identity $query |sed '1d' > $tmp_file

		if [ ! -s $tmp_file ]; then
			outputMess="CRITICAL: No PSU data returned \n"
			exitCode=2
		else
                	cat $tmp_file |awk '{printf $3}' |grep -i offline
                	if [ "$?" -eq "0" ]; then
                        	outputMess="$outputMess CRITICAL: PSU OFFLINE \n"
                	else
                        	outputMess="$outputMess OK: PSU \n"
                	fi

                	while read line
                        	do
                                	psu_id=$(echo "${line}" | awk '{printf $2}')
                                	psu_enc_id=$(echo "${line}" | awk '{printf $1}')
                                	psu_stat=$(echo "${line}" | awk '{printf $3}')

                                	if [ $psu_stat = "online" ]; then
                                        	outputMess="$outputMess OK: PSU $psu_id enclosure: $psu_enc_id status: $psu_stat \n"
                                	else
                                        	outputMess="$outputMess ATTENTION: PSU $psu_id enclosure: $psu_enc_id status: $psu_stat \n"
                                        	exitCode=2
                                	fi

                	done < $tmp_file
		fi
	;;

	lsenclosureslot)
                $ssh $user@$storage -i $identity $query |sed '1d' > $tmp_file

		if [ ! -s $tmp_file ]; then
			outputMess="CRITICAL: No enclosure slot data returned \n"
			exitCode=2
		else
                	cat $tmp_file |awk '{printf $3, $4}' |grep -i offline
                	if [ "$?" -eq "0" ]; then
                        	outputMess="$outputMess CRITICAL: EnclosureSlot OFFLINE \n"
                	else
                        	outputMess="$outputMess OK: EnclosureSlot \n"
                	fi

                	while read line
                        	do
                                	slt_enc_id=$(echo "${line}" | awk '{printf $1}')
                                	slt_id=$(echo "${line}" | awk '{printf $2}')
                                	slt_prt1_stat=$(echo "${line}" | awk '{printf $3}')
                                	slt_prt2_stat=$(echo "${line}" | awk '{printf $4}')
                                	slt_drv=$(echo "${line}" | awk '{printf $5}')
                                	drv_id=$(echo "${line}" | awk '{printf $6}')

                                	if [ $slt_prt1_stat = "online" -a $slt_prt2_stat = "online" -a $slt_drv = "yes" ]; then
                                        	outputMess="$outputMess OK: Drive-$drv_id enclosure-$slt_enc_id slot-$slt_id port1-$slt_prt1_stat port2-$slt_prt2_stat\n"
                                	else
                                        	outputMess="$outputMess ATTENTION: Drive-$drv_id enclosure-$slt_enc_id slot-$slt_id port1-$slt_prt1_stat port2-$slt_prt2_stat \n"
                                        	exitCode=2
                                	fi

                	done < $tmp_file
		fi
	;;

	lsrcrelationship)
                volume_mirror_prod=$($ssh $user@$storage -i $identity $query | grep -c "rcrel*")
                volume_mirror_sync=$($ssh $user@$storage -i $identity $query | grep -c "consistent_synchronized")

                                if [ $volume_mirror_prod = $volume_mirror_sync ]; then
                                        outputMess="$outputMess OK: $volume_mirror_prod mirors are consistent and synchronized \n"
                                else
                                        outputMess="$outputMess CRITICAL: sur les $volume_mirror_prod volumes, only $volume_mirror_sync are consistent and synchronized \n"
                                        exitCode=2
                                fi

	;;

	unified)
    		# Execute remote command
		$ssh $user@$storage -i $identity lshealth -Y > $tmp_file

		if [ ! -s $tmp_file ]; then
			outputMess="CRITICAL: No health data returned \n"
			exitCode=2
		else
    			# Parse remote command output
    			while read line
    			do
        			case $(echo "$line" | cut -d : -f 9) in
          				OK) # Sensor OK state -> do nothing
						outputMess="${outputMess}`echo $line | cut -d : -f 7,9 >> $tmp_file_OK`"
          				;;
          				WARNING) # Sensor WARNING state
            					if [ "$exitCode" -lt 1 ]; then 
							exitCode=1; 
	    					fi
            					# Append sensor message to output
            					if [ -n "$outputMess" ]; then 
							outputMess="$outputMess +++ "; 
	    					fi
            					outputMess="${outputMess}STATE WARNING - [`echo $line | cut -d : -f 7`:`echo $line | cut -d : -f 8`] `echo $line | cut -d : -f 10`"
          				;;
          				ERROR) # Sensor ERROR state
            					if [ "$exitCode" -lt 2 ]; then 
							exitCode=2; 
						fi
            					# Append sensor message to output
            					if [ -n "$outputMess" ]; then 
							outputMess="$outputMess +++ "; 
						fi
            					outputMess="${outputMess}STATE CRITICAL - [`echo $line | cut -d : -f 7`:`echo $line | cut -d : -f 8`] `echo $line | cut -d : -f 10`"
          				;;
        			esac
    			done < $tmp_file

    			# No warnings/errors detected
    			if [ "$exitCode" -eq 0 ]; then 
				outputMess=`uniq "$tmp_file_OK"`;
			fi
		fi
  	;;

	lsportfc)
		# Check FC port status, link state, and speed
		# Fetch WITH header row in single call
		$ssh $user@$storage -i $identity lsportfc -delim : > $tmp_file

		if [ ! -s $tmp_file ]; then
			outputMess="CRITICAL: No FC port data returned \n"
			exitCode=2
		else
			# Read header from first line
			header=$(head -1 "$tmp_file")
			IFS=':' read -ra cols <<< "$header"
			id_col=-1; status_col=-1; speed_col=-1; nodeid_col=-1; nodename_col=-1; att_speed_col=-1
			for i in "${!cols[@]}"; do
				case "${cols[$i]}" in
					id) id_col=$i;;
					port_id) id_col=$i;;
					status) status_col=$i;;
					port_speed) speed_col=$i;;
					node_id) nodeid_col=$i;;
					node_name) nodename_col=$i;;
					attached_port_speed) att_speed_col=$i;;
				esac
			done

			if [ $id_col -eq -1 -o $status_col -eq -1 ]; then
				outputMess="UNKNOWN: Could not parse lsportfc column headers \n"
				exitCode=3
			else
				outputMess="OK: FC Ports \n"
				tmp_data="/tmp/v7000_${storage}_portfc_data.tmp"
				sed '1d' "$tmp_file" > "$tmp_data"
				while IFS=':' read -ra fields; do
					fc_id="${fields[$id_col]}"
					fc_status="${fields[$status_col]}"

					# Get node identifier
					fc_node=""
					if [ $nodeid_col -ge 0 ]; then
						fc_node="Node${fields[$nodeid_col]}"
					elif [ $nodename_col -ge 0 ]; then
						fc_node="${fields[$nodename_col]}"
					fi

					# Get speed if column exists
					fc_speed=""
					if [ $speed_col -ge 0 ]; then
						fc_speed="${fields[$speed_col]}"
					fi

					# Get attached speed if column exists
					fc_att_speed=""
					if [ $att_speed_col -ge 0 ]; then
						fc_att_speed="${fields[$att_speed_col]}"
					fi

					if [ "$fc_status" = "active" -o "$fc_status" = "online" ]; then
						# Port is up - check for speed mismatch if both speeds available
						if [ -n "$fc_speed" -a -n "$fc_att_speed" -a "$fc_att_speed" != "" -a "$fc_speed" != "$fc_att_speed" ]; then
							outputMess="$outputMess WARNING: $fc_node FC Port $fc_id is $fc_status but speed mismatch (port: $fc_speed, attached: $fc_att_speed) \n"
							if [ $exitCode -lt 2 ]; then exitCode=1; fi
						else
							outputMess="$outputMess OK: $fc_node FC Port $fc_id status: $fc_status speed: $fc_speed \n"
						fi
					elif [ "$fc_status" = "inactive_unconfigured" ]; then
						# Unconfigured port - intentionally unused, OK
						outputMess="$outputMess OK: $fc_node FC Port $fc_id status: $fc_status (unconfigured) \n"
					elif [ "$fc_status" = "inactive_configured" ]; then
						# Configured but not active - something is wrong
						outputMess="$outputMess WARNING: $fc_node FC Port $fc_id status: $fc_status \n"
						if [ $exitCode -lt 2 ]; then exitCode=1; fi
					else
						# Port in error, offline, or other bad state
						outputMess="$outputMess CRITICAL: $fc_node FC Port $fc_id status: $fc_status speed: $fc_speed \n"
						exitCode=2
					fi
				done < "$tmp_data"
				rm -f "$tmp_data"
			fi
		fi
	;;

	lseventlog)
		# Check for unresolved alert events in the Storwize event log
		# Reports ALL unfixed alerts. Events clear when fixed on the Storwize.

		# Fetch all unfixed alerts (WITH header row)
		$ssh $user@$storage -i $identity "lseventlog -filtervalue status=alert:fixed=no -delim :" > $tmp_file

		if [ ! -s $tmp_file ]; then
			outputMess="OK: No unresolved events \n"
			exitCode=0
		else
			# Read header from first line
			header=$(head -1 "$tmp_file")
			IFS=':' read -ra cols <<< "$header"
			seq_col=-1; ts_col=-1; objtype_col=-1; objname_col=-1; eventid_col=-1; errcode_col=-1; desc_col=-1
			for i in "${!cols[@]}"; do
				case "${cols[$i]}" in
					sequence_number) seq_col=$i;;
					last_timestamp) ts_col=$i;;
					object_type) objtype_col=$i;;
					object_name) objname_col=$i;;
					event_id) eventid_col=$i;;
					error_code) errcode_col=$i;;
					description) desc_col=$i;;
				esac
			done

			if [ $seq_col -eq -1 -o $desc_col -eq -1 ]; then
				outputMess="UNKNOWN: Could not parse lseventlog column headers \n"
				exitCode=3
			else
				alert_count=0
				event_summary=""

				# Process data lines (skip header)
				tmp_data="/tmp/v7000_${storage}_eventlog_data.tmp"
				sed '1d' "$tmp_file" > "$tmp_data"

				while IFS=':' read -ra fields; do
					evt_seq="${fields[$seq_col]}"
					evt_ts=""
					evt_objtype=""
					evt_objname=""
					evt_eventid=""
					evt_errcode=""
					evt_desc=""

					if [ $ts_col -ge 0 ]; then evt_ts="${fields[$ts_col]}"; fi
					if [ $objtype_col -ge 0 ]; then evt_objtype="${fields[$objtype_col]}"; fi
					if [ $objname_col -ge 0 ]; then evt_objname="${fields[$objname_col]}"; fi
					if [ $eventid_col -ge 0 ]; then evt_eventid="${fields[$eventid_col]}"; fi
					if [ $errcode_col -ge 0 ]; then evt_errcode="${fields[$errcode_col]}"; fi
					if [ $desc_col -ge 0 ]; then evt_desc="${fields[$desc_col]}"; fi

					# Use whichever ID is populated
					evt_display_code="$evt_eventid"
					if [ -n "$evt_errcode" ]; then evt_display_code="$evt_errcode"; fi

					alert_count=$((alert_count + 1))
					event_summary="$event_summary WARNING: Event $evt_display_code on $evt_objtype $evt_objname - $evt_desc (seq:$evt_seq ts:$evt_ts) \n"
				done < "$tmp_data"
				rm -f "$tmp_data"

				if [ $alert_count -eq 0 ]; then
					outputMess="OK: No unresolved events \n"
					exitCode=0
				else
					outputMess="WARNING: $alert_count unresolved event(s) \n$event_summary"
					exitCode=1
				fi
			fi
		fi
	;;

	lsvdiskspace)
		# Check vdisk capacity usage with warning/critical thresholds
		# Fetch WITH header row in single call
		$ssh $user@$storage -i $identity lsvdisk -bytes -delim : > $tmp_file

		if [ ! -s $tmp_file ]; then
			outputMess="CRITICAL: No vdisk data returned \n"
			exitCode=2
		else
			header=$(head -1 "$tmp_file")
			IFS=':' read -ra cols <<< "$header"
			name_col=-1; cap_col=-1; used_col=-1
			for i in "${!cols[@]}"; do
				case "${cols[$i]}" in
					name) name_col=$i;;
					capacity) cap_col=$i;;
					used_capacity) used_col=$i;;
				esac
			done

			if [ $name_col -eq -1 -o $cap_col -eq -1 -o $used_col -eq -1 ]; then
				outputMess="UNKNOWN: Could not parse lsvdisk column headers \n"
				exitCode=3
			else
				outputMess="OK: VDisk Space \n"
				tmp_data="/tmp/v7000_${storage}_vdiskspace_data.tmp"
				sed '1d' "$tmp_file" > "$tmp_data"
				while IFS=':' read -ra fields; do
					vd_name="${fields[$name_col]}"
					vd_cap="${fields[$cap_col]}"
					vd_used="${fields[$used_col]}"

					if [ "$vd_cap" -gt 0 ] 2>/dev/null; then
						pct=$(( vd_used * 100 / vd_cap ))
						vd_cap_gb=$(( vd_cap / 1073741824 ))
						vd_used_gb=$(( vd_used / 1073741824 ))

						if [ $pct -ge $crit ]; then
							outputMess="$outputMess CRITICAL: VDisk $vd_name ${pct}% used (${vd_used_gb}GB/${vd_cap_gb}GB) \n"
							exitCode=2
						elif [ $pct -ge $warn ]; then
							outputMess="$outputMess WARNING: VDisk $vd_name ${pct}% used (${vd_used_gb}GB/${vd_cap_gb}GB) \n"
							if [ $exitCode -lt 2 ]; then exitCode=1; fi
						else
							outputMess="$outputMess OK: VDisk $vd_name ${pct}% used (${vd_used_gb}GB/${vd_cap_gb}GB) \n"
						fi
					fi
				done < "$tmp_data"
				rm -f "$tmp_data"
			fi
		fi
	;;

	lspoolspace)
		# Check storage pool capacity usage with warning/critical thresholds
		# Fetch WITH header row in single call
		$ssh $user@$storage -i $identity lsmdiskgrp -bytes -delim : > $tmp_file

		if [ ! -s $tmp_file ]; then
			outputMess="CRITICAL: No pool data returned \n"
			exitCode=2
		else
			header=$(head -1 "$tmp_file")
			IFS=':' read -ra cols <<< "$header"
			name_col=-1; cap_col=-1; free_col=-1
			for i in "${!cols[@]}"; do
				case "${cols[$i]}" in
					name) name_col=$i;;
					capacity) cap_col=$i;;
					free_capacity) free_col=$i;;
				esac
			done

			if [ $name_col -eq -1 -o $cap_col -eq -1 -o $free_col -eq -1 ]; then
				outputMess="UNKNOWN: Could not parse lsmdiskgrp column headers \n"
				exitCode=3
			else
				outputMess="OK: Pool Space \n"
				perfData=""
				tmp_data="/tmp/v7000_${storage}_poolspace_data.tmp"
				sed '1d' "$tmp_file" > "$tmp_data"
				while IFS=':' read -ra fields; do
					pool_name="${fields[$name_col]}"
					pool_cap="${fields[$cap_col]}"
					pool_free="${fields[$free_col]}"

					if [ "$pool_cap" -gt 0 ] 2>/dev/null; then
						pool_used=$(( pool_cap - pool_free ))
						pct=$(( pool_used * 100 / pool_cap ))
						pool_cap_gb=$(( pool_cap / 1073741824 ))
						pool_free_gb=$(( pool_free / 1073741824 ))
						pool_used_gb=$(( pool_used / 1073741824 ))

						# Build perfdata: 'label'=value;warn;crit;min;max
						warn_bytes=$(( pool_cap * warn / 100 ))
						crit_bytes=$(( pool_cap * crit / 100 ))
						perfData="$perfData '${pool_name}_used'=${pool_used}B;${warn_bytes};${crit_bytes};0;${pool_cap}"
						perfData="$perfData '${pool_name}_pct'=${pct}%;${warn};${crit};0;100"
						perfData="$perfData '${pool_name}_free'=${pool_free}B;;;0;${pool_cap}"

						if [ $pct -ge $crit ]; then
							outputMess="$outputMess CRITICAL: Pool $pool_name ${pct}% used (${pool_used_gb}GB/${pool_cap_gb}GB, ${pool_free_gb}GB free) \n"
							exitCode=2
						elif [ $pct -ge $warn ]; then
							outputMess="$outputMess WARNING: Pool $pool_name ${pct}% used (${pool_used_gb}GB/${pool_cap_gb}GB, ${pool_free_gb}GB free) \n"
							if [ $exitCode -lt 2 ]; then exitCode=1; fi
						else
							outputMess="$outputMess OK: Pool $pool_name ${pct}% used (${pool_used_gb}GB/${pool_cap_gb}GB, ${pool_free_gb}GB free) \n"
						fi
					fi
				done < "$tmp_data"
				rm -f "$tmp_data"
			fi
		fi
	;;

	*)
		echo -ne "Command not found. \n"
		exit 3
	;;
esac

rm -f $tmp_file
# rm $tmp_file_OK
if [ -n "$perfData" ]; then
	# Nagios expects perfdata after | on the first line
	# Split outputMess: first line gets perfdata, rest is long output
	first_line=$(echo -ne "$outputMess" | head -1)
	long_output=$(echo -ne "$outputMess" | tail -n +2)
	echo "${first_line} |${perfData}"
	if [ -n "$long_output" ]; then
		echo "$long_output"
	fi
else
	echo -ne "$outputMess\n"
fi
exit $exitCode
