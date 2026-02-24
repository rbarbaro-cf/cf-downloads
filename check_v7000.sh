#!/bin/bash

# Editing Author:	Niels van Aert
# Editing Date:		30-04-2019
# Custom Version	1.4.1

# Original Author:	Lazzarin Alberto
# Original Date:	10-04-2013
# Original Version	1.4
#
# This plugin checks various attributes of a Lenovo / IBM Storwize v3700 / v7000.
# To use this script you need to create a so called Monitoring user on the SAN with an SSH certificate.
# The help is included into the script.
#
#
#
# CHANGELOG
#
# 1.4.1 
# Added the option to specify -i to specify an identity file, rather than expect it to be at a certain location.
# Commented out rm $tmp_file_OK as it was throwing an error on recent firmware versions.
# Fixed incorrect line-formatting which caused the plugin to refuse to run on some systems.
# 1.4 Made by Andrea Tedesco [andrea85 . tedesco @ gmail . com]
# Add check of v7000 Unified
# 1.3 Made by Ivan Bergantin [ivan . bergantin @ gmail . com] suggested by Leandro Freitas [leandro @ nodeps . com . br]
# Add short output in "Service Status Details For Host" view, and detailed output in "Service Information"view
#
# 1.2 Made by Feilong
# Add check of mirror status between two volumes on two IBM V7000.
# It check the number of mirrors, the numbers of consitent and synchronized mirrors. If they are differents, the status returned is critical.
#
# 1.1
# Change login method from from 'plink' to ssh.
# Add "OK" and "ATTENTION" in the output.
#
# 1.0
# First release.
#

ssh=/usr/bin/ssh
exitCode=0

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

#echo -ne "IBM Storwize v3700/v7000 Health Check\n"

case $query in 
	lsarray)
		$ssh $user@$storage -i $identity $query |sed '1d' > $tmp_file

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
	;;

	lsdrive)
                $ssh $user@$storage -i $identity $query |sed '1d' > $tmp_file

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
                                        outputMess="$outputMess ATTENTION: Disk $drive_n \nstatus: $disk_status \nrole: $drive_role \ntype: $drive_type \ncapacity: $drive_capacity \nenclosure: $drive_enclosure \nslot: $drive_slot "
                                        exitCode=2
                                fi

                done < $tmp_file

	;;

	lsvdisk)
                $ssh $user@$storage -i $identity $query |sed '1d' > $tmp_file

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
                                        outputMess="$outputMess ATTENTION: VDisks $mdisk_name status: $vdisk_status \n"
                                        exitCode=2
                                fi

                done < $tmp_file
	;;

	lsenclosure)
                $ssh $user@$storage -i $identity $query |sed '1d' > $tmp_file

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
	;;

	lsenclosurebattery)
                $ssh $user@$storage -i $identity $query |sed '1d' > $tmp_file

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
	;;

	lsenclosurecanister)
                $ssh $user@$storage -i $identity $query |sed '1d' > $tmp_file

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
	;;

	lsenclosurepsu)
                $ssh $user@$storage -i $identity $query |sed '1d' > $tmp_file

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
	;;

	lsenclosureslot)
                $ssh $user@$storage -i $identity $query |sed '1d' > $tmp_file

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
  	;;
	lsvdiskspace)
		# Check vdisk capacity usage with warning/critical thresholds
		$ssh $user@$storage -i $identity lsvdisk -bytes -delim : -nohdr > $tmp_file

		if [ ! -s $tmp_file ]; then
			outputMess="CRITICAL: No vdisk data returned \n"
			exitCode=2
		else
			# Get header to find column positions
			header=$($ssh $user@$storage -i $identity lsvdisk -bytes -delim : | head -1)
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
				done < $tmp_file
			fi
		fi
	;;

	lspoolspace)
		# Check storage pool capacity usage with warning/critical thresholds
		$ssh $user@$storage -i $identity lsmdiskgrp -bytes -delim : -nohdr > $tmp_file

		if [ ! -s $tmp_file ]; then
			outputMess="CRITICAL: No pool data returned \n"
			exitCode=2
		else
			header=$($ssh $user@$storage -i $identity lsmdiskgrp -bytes -delim : | head -1)
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
				done < $tmp_file
			fi
		fi
	;;

	*)
		echo -ne "Command not found. \n"
		exit 3
	;;
esac

rm $tmp_file
# rm $tmp_file_OK
echo -ne "$outputMess\n"
exit $exitCode
