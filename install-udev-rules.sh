#!/usr/bin/env bash

udev_rules='/etc/udev/rules.d'
output_rule="$udev_rules/20-macchiato.rules"

if [ "$#" -eq 0 ]; then
	echo "This script requires macchiato's configuration directory as argument."
	echo 'It also assumes that you have already set all the configuration files up,'
	echo 'so make sure you do that first before running this script again.'
	exit 1
fi

scriptFile="$(readlink -f "$BASH_SOURCE")"
scriptDir="$(dirname "$scriptFile")"

source "$scriptDir/functions.sh" || exit 1

if [ -x /usr/share/macchiato/macchiato ]; then
	macchiato_bin='/usr/share/macchiato/macchiato'
else
	if ! which macchiato &> /dev/null; then
		echo 'Cannot find macchiato executable in $PATH.'
		exit 1
	fi
	macchiato_bin=$(which macchiato)
fi
bash_bin=$(which bash)

confDir="$1"
if [ ! -d "$confDir" ]; then
	echo "Configuration directory '$confDir' not found."
	exit 1
fi

confGlob=$(echo "$confDir"/*.sh)
if [ "$confGlob" == "$confDir/*.sh" ]; then
	echo "No configuration files found matching pattern '$confDir/*.sh'."
	exit 1
fi

devices=()
for i in "$confDir"/*.sh; do
	deviceName=$(basename "$i" | sed 's/\.sh$//')
	if ip link show "$deviceName" &> /dev/null; then
		devices+=("$deviceName")
	else
		echo "Warning: Configuration file '$i' found, but network interface '$deviceName' does not exist."
		echo "         No rules will be generated for this network interface."
		echo "         This means the MAC address of '$deviceName' will NOT be spoofed when the interface is eventually plugged in."
	fi
done

if [ "${#devices[@]}" -eq 0 ]; then
	echo 'Configuration files were found, but none of them are valid. Aborting.'
	exit 1
fi

declare -A macAddresses
for device in "${devices[@]}"; do
	unsure=true
	macAddress=""
	if [ -f "$output_rule" ]; then
		if grep -E "^#\\s*macchiato-data:\\s*$device\\s*=" "$output_rule" &> /dev/null; then
			macAddress="$(grep -E "^#\\s*macchiato-data:\\s*$device\\s*=" "$output_rule" | sed -r "s/^#\\s*macchiato-data:\\s*$device\\s*=\\s*//")"
			echo "[$device] MAC address '$macAddress' obtained from previous run of the script."
			unsure=''
		fi
	fi
	if [ -z "$macAddress" -a -d "$udev_rules" ]; then
		if grep -qrhEi "SUBSYSTEM\s*==\s*\"net\"\s*,\s*ATTR{address}\s*==\s*\"[^\"]*\"\s*,\s*NAME\s*=\s*\"$device\"" "$udev_rules"; then
			macAddress="$(grep -rhEi "SUBSYSTEM\s*==\s*\"net\"\s*,\s*ATTR{address}\s*==\s*\"[^\"]*\"\s*,\s*NAME\s*=\s*\"$device\"" "$udev_rules" | head -1 | sed -r 's#^.*ATTR\{address\}\s*==\s*"([^"]+)".*$#\1#i')"
			echo "[$device] MAC address '$macAddress' obtained from udev rules file: '$(grep -rlEi "SUBSYSTEM\s*==\s*\"net\"\s*,\s*ATTR{address}\s*==\s*\"[^\"]*\"\s*,\s*NAME\s*=\s*\"$device\"" "$udev_rules" | head -1)'"
		fi
	fi
	if [ -z "$macAddress" ]; then
		macAddress="$(deviceGetMAC "$deviceName")"
		echo "[$device] Guessed MAC address: '$macAddress'"
	fi
	if [ -n "$unsure" ]; then
		echo "[$device] Is this correct?"
		echo "     If it is correct, leave blank."
		echo "     If it is incorrect, please enter the hardware (i.e. non-spoofed) MAC address."
		read -p "[$device] Hardware MAC address? [$macAddress] " userMacAddress
		if [ -n "$userMacAddress" ]; then
			macAddress="$(echo "$userMacAddress" | sed 's/-/:/g' | tr '[A-Z]' '[a-z]')"
		fi
		echo "[$device] Using '$macAddress' as definitive MAC address."
	fi
	macAddresses["$device"]="$macAddress"
done

echo '# This file is generated by by macchiato using the install-udev-rules.sh script.' > "$output_rule"
echo '# As such, any changes you make here will be overwritten during the next run of script.' >> "$output_rule"
echo '' >> "$output_rule" # Empty line
for device in "${!macAddresses[@]}"; do
	echo "# macchiato-data: $device = ${macAddresses[$device]}" >> "$output_rule"
	echo "ACTION==\"add\", ATTR{address}==\"${macAddresses[$device]}\", RUN+=\"$bash_bin '$macchiato_bin' '$confDir' '$device'\"" >> "$output_rule"
	echo '' >> "$output_rule" # Empty line
done
echo "All done. udev rules have been written to '$output_rule'"
