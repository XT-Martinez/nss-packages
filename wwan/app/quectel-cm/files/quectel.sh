#!/bin/sh

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_quectel_init_config() {
	available=1
	no_device=1
	proto_config_add_string "device:device"
	proto_config_add_boolean "multiplexing"
	proto_config_add_boolean "create_virtual_interface"
	proto_config_add_string "apn"
	proto_config_add_string "apnv6"
	proto_config_add_string "pdnindex"
	proto_config_add_string "pdnindexv6"
	proto_config_add_string "auth"
	proto_config_add_string "username"
	proto_config_add_string "password"
	proto_config_add_string "pincode"
	proto_config_add_int "delay"
	proto_config_add_string "pdptype"
	proto_config_add_boolean "dhcp"
	proto_config_add_boolean "dhcpv6"
	proto_config_add_boolean "sourcefilter"
	proto_config_add_boolean "delegate"
	proto_config_add_int "mtu"
	proto_config_add_array 'cell_lock_4g:list(string)'
	proto_config_add_defaults
}

proto_quectel_setup() {
	local interface="$1"
	local device apn apnv6 auth username password pincode delay pdptype pdnindex pdnindexv6 multiplexing create_virtual_interface cell_lock_4g
	local dhcp dhcpv6 sourcefilter delegate mtu $PROTO_DEFAULT_OPTIONS
	local ip4table ip6table
	local pid zone npipe1 npipe2 npipe

	json_get_vars device apn apnv6 auth username password pincode delay pdnindex pdnindexv6 multiplexing create_virtual_interface
	json_get_vars pdptype dhcp dhcpv6 sourcefilter delegate ip4table
	json_get_vars ip6table mtu $PROTO_DEFAULT_OPTIONS

	[ -n "$delay" ] || delay="5"
	sleep "$delay"

	if json_is_a cell_lock_4g array; then
		echo "4G Cell ID Locking"
		json_select cell_lock_4g
		idx=1
		cell_ids=""

		while json_is_a ${idx} string
		do
			json_get_var cell_lock $idx
			pci=$(echo $cell_lock | cut -d',' -f1)
			earfcn=$(echo $cell_lock | cut -d',' -f2)
			cell_ids="$cell_ids,$earfcn,$pci" 
			idx=$(( idx + 1 ))
		done
		idx=$(( idx - 1 ))

		if [ "$idx" -gt 0 ]; then
			cell_ids="${idx}${cell_ids}"
			echo -ne "AT+QNWLOCK=\"COMMON/4G\",${cell_ids}\r\n" > /dev/ttyUSB2
		fi
	else
		echo -ne "AT+QNWLOCK=\"COMMON/4G\",0\r\n" > /dev/ttyUSB2
	fi

	[ -n "$metric" ] || metric="0"
	[ -n "$create_virtual_interface" ] || create_virtual_interface="1"
	[ -z "$ctl_device" ] || device="$ctl_device"

	[ -n "$device" ] || {
		echo "No control device specified"
		proto_notify_error "$interface" NO_DEVICE
		proto_set_available "$interface" 0
		return 1
	}

	device="$(readlink -f "$device")"
	[ -c "$device" ] || {
		echo "The specified control device does not exist"
		proto_notify_error "$interface" NO_DEVICE
		proto_set_available "$interface" 0
		return 1
	}

	devname="$(basename "$device")"
	devpath="$(readlink -f "/sys/class/usbmisc/$devname/device/")"
	ifname="$(ls "$devpath/net" 2>"/dev/null")"
	[ -n "$ifname" ] || {
		echo "The interface could not be found."
		proto_notify_error "$interface" NO_IFACE
		proto_set_available "$interface" 0
		return 1
	}

	[ "$pdptype" = "ipv4" -o "$pdptype" = "ipv4v6" ] && ipv4opt="-4"
	[ "$pdptype" = "ipv6" -o "$pdptype" = "ipv4v6" ] && ipv6opt="-6"
	[ -n "$auth" ] || auth="none"

	quectel-qmi-proxy &
	sleep 3

	# If $ifname_1 is not a valid device set $ifname4 to base $ifname as fallback
  	# so modems not using RMNET/QMAP data aggregation still set up properly. QMAP
   	# can be set via qmap_mode=n parameter during qmi_wwan_q module loading.
 	if [ ifconfig "${ifname}_1" &>"/dev/null" ]; then
 		ifname4="${ifname}_1"
   	else
		ifname4="$ifname"
	fi
	
	if [ "$multiplexing" = 1 ]; then
		ifconfig "${ifname}_2" &>"/dev/null" && ifname6="${ifname}_2"
	else
		ifname6="$ifname4"
	fi

	if [ -n "$mtu" ]; then
		echo "Setting MTU to $mtu"
		/sbin/ip link set dev "$ifname4" mtu "$mtu"
		[ "$multiplexing" = 1 ] && /sbin/ip link set dev "$ifname6" mtu "$mtu"
	fi

	if [ "$multiplexing" = 1 ]; then
		[ -n "$pdnindex" ] || pdnindex="1"
		[ -n "$pdnindexv6" ] || pdnindexv6="2"

		if [ -n "$ipv4opt" ]; then
			npipe1="/tmp/quectel_wwan0_1"
			[ ! -p "$npipe1" ] && mkfifo "$npipe1"
			quectel-cm -o -i "$ifname" $ipv4opt -n $pdnindex -m 1 ${pincode:+-p $pincode} -s "$apn" "$username" "$password" "$auth" > "$npipe1" &
		fi
		if [ -n "$ipv6opt" ]; then
			npipe2="/tmp/quectel_wwan0_2"
			[ ! -p "$npipe2" ] && mkfifo "$npipe2"
			quectel-cm -o -i "$ifname" $ipv6opt -n $pdnindexv6 -m 2 ${pincode:+-p $pincode} -s "$apnv6" "$username" "$password" "$auth" > "$npipe2" &
		fi
	else
		npipe="/tmp/quectel_wwan0"
		[ ! -p "$npipe" ] && mkfifo "$npipe"
		quectel-cm -o -i "$ifname" $ipv4opt $ipv6opt ${pincode:+-p $pincode} -s "$apn" "$username" "$password" "$auth" > "$npipe" &
	fi

	echo "Setting up $ifname"
	proto_init_update "$ifname" 1
	proto_set_keep 1
	proto_send_update "$interface"

	if [ "$create_virtual_interface" -ne 1 ]; then
		return 0;
	fi

	zone="$(fw3 -q network "$interface" 2>/dev/null)"

	if [ "$pdptype" = "ipv6" ] || [ "$pdptype" = "ipv4v6" ]; then
		ip -6 addr flush dev $ifname6

		json_init
		json_add_string name "${interface}_6"
		json_add_string device "$ifname6"
		[ "$pdptype" = "ipv4v6" ] && json_add_string iface_464xlat "0"
		if [ -z "$dhcpv6" -o "$dhcpv6" = 0 ]; then
			[ "$multiplexing" = 1 ] && npipe="$npipe2"
			json_load $(get_connection_information_from_pipe $npipe $ifname)
			json_select ipv6
			
			json_get_var ip6addr "ip6addr"
			json_get_var gateway "gateway"
			json_get_var prefix "prefix"
			json_get_var dns1 "dns1"
			json_get_var dns2 "dns2"
			 
			json_add_string proto "static"

			json_add_string ip6addr "$ip6addr/$prefix"
			json_add_string ip6prefix "$ip6addr/$prefix"
			json_add_string ip6gw "$gateway"

			# json_add_array ip6addr
			# json_add_string "" "$ip6addr/$prefix"
			# json_close_array

			# json_add_array ip6prefix
			# json_add_string "" "$ip6addr/$prefix"
			# json_close_array

			# json_add_string ip6gw "$gateway"

			json_add_array dns
			json_add_string "" "$dns1"
			json_add_string "" "$dns2"
			json_close_array
		else
			json_add_string proto "dhcpv6"
		fi
		proto_add_dynamic_defaults
		[ -z "$ip6table" ] || json_add_string ip6table "$ip6table"
		# RFC 7278: Extend an IPv6 /64 Prefix to LAN
		json_add_string extendprefix 1
		[ "$delegate" = "0" ] && json_add_boolean delegate "0"
		[ "$sourcefilter" = "0" ] && json_add_boolean sourcefilter "0"
		[ -z "$zone" ] || json_add_string zone "$zone"
		json_close_object
		ubus call network add_dynamic "$(json_dump)"
	fi

	if [ "$pdptype" = "ipv4" ] || [ "$pdptype" = "ipv4v6" ]; then
		json_init
		json_add_string name "${interface}_4"
		json_add_string device "$ifname4"
		if [ -z "$dhcp" -o "$dhcp" = 0 ]; then
			[ "$multiplexing" = 1 ] && npipe="$npipe1"
			json_load $(get_connection_information_from_pipe $npipe $ifname)
			json_select ipv4

			json_get_var ipaddr "ipaddr"
			json_get_var gateway "gateway"
			json_get_var netmask "netmask"
			json_get_var dns1 "dns1"
			json_get_var dns2 "dns2"

			json_add_string proto "static"

			json_add_string ipaddr "$ipaddr"
			json_add_string netmask "$netmask"
			json_add_string gateway "$gateway"

			json_add_array dns
			json_add_string "" "$dns1"
			json_add_string "" "$dns2"
			json_close_array
		else
			json_add_string proto "dhcp"
		fi
		[ -z "$ip4table" ] || json_add_string ip4table "$ip4table"
		proto_add_dynamic_defaults
		[ -z "$zone" ] || json_add_string zone "$zone"
		json_close_object
		ubus call network add_dynamic "$(json_dump)"
	fi

	[ -p "$npipe1" ] && rm "$npipe1"
	[ -p "$npipe2" ] && rm "$npipe2"
	[ -p "$npipe" ] && rm "$npipe"
}

get_connection_information_from_pipe() {
	local npipe, interface
	npipe="$1"
	interface="$2"
	tail -f "$npipe" | while read -r line; do
		if echo "$line" | grep -q "Connection Information:"; then
			echo "$line" | sed 's/.*Connection Information: //'
			break
		elif echo "$line" | grep -q "ip link set dev $interface down"; then
			break
		fi
	done
}

proto_quectel_teardown() {
	local interface="$1"

	local device
	json_get_vars device
	[ -z "$ctl_device" ] || device="$ctl_device"

	echo "Stopping network $interface"

	proto_init_update "*" 0
	proto_send_update "$interface"
	killall quectel-cm
	killall quectel-qmi-proxy
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol quectel
}
