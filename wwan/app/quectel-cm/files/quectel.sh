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
	local pid zone

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
	qmap_mode=$(cat "$devpath/net/$ifname/qmap_mode" 2>/dev/null)

	[ "$pdptype" = "ipv4" -o "$pdptype" = "ipv4v6" ] && ipv4opt="-4"
	[ "$pdptype" = "ipv6" -o "$pdptype" = "ipv4v6" ] && ipv6opt="-6"
	[ -n "$auth" ] || auth="none"

	quectel-qmi-proxy &
	sleep 2

	# If $ifname_1 is not a valid device set $ifname4 to base $ifname as fallback
  	# so modems not using RMNET/QMAP data aggregation still set up properly. QMAP
   	# can be set via qmap_mode=n parameter during qmi_wwan_q module loading.
	if [ -n "$qmap_mode" ] && [ "$qmap_mode" -gt "0" ]; then
		ifname4="${ifname}_1"
	else
		ifname4="$ifname"
	fi

	if [ "$multiplexing" = 1 ] && [ -n "$qmap_mode" ] && [ "$qmap_mode" -gt "1" ]; then
		ifname6="${ifname}_2"
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
			rm -f "/tmp/$ifname4"
			quectel-cm -o -i "$ifname" $ipv4opt -n $pdnindex -m 1 ${pincode:+-p $pincode} -s "$apn" "$username" "$password" "$auth" > "/tmp/$ifname4" &
		fi
		if [ -n "$ipv6opt" ]; then
			rm -f "/tmp/$ifname6"
			quectel-cm -o -i "$ifname" $ipv6opt -n $pdnindexv6 -m 2 ${pincode:+-p $pincode} -s "$apnv6" "$username" "$password" "$auth" > "/tmp/$ifname6" &
		fi
	else
		rm "/tmp/$ifname"
		quectel-cm -o -i "$ifname" $ipv4opt $ipv6opt ${pincode:+-p $pincode} -s "$apn" "$username" "$password" "$auth" > "/tmp/$ifname" &
	fi

	echo "Setting up $ifname"
	proto_init_update "$ifname" 1
	proto_set_keep 1
	proto_send_update "$interface"

	if [ "$create_virtual_interface" -ne 1 ]; then
		return 0;
	fi

	zone="$(fw3 -q network "$interface" 2>/dev/null)"

	if [ "$pdptype" = "ipv4" ] || [ "$pdptype" = "ipv4v6" ]; then
		json_init
		json_add_string name "${interface}_4"
		json_add_string device "$ifname4"
		if [ -z "$dhcp" -o "$dhcp" = 0 ]; then
			conn_info=$(get_connection_info "/tmp/$ifname4");

			ipaddr=$(echo "$conn_info" | jq -r '.ipv4.ipaddr')
			gateway=$(echo "$conn_info" | jq -r '.ipv4.gateway')
			netmask=$(echo "$conn_info" | jq -r '.ipv4.netmask')
			dns1=$(echo "$conn_info" | jq -r '.ipv4.dns1')
			dns2=$(echo "$conn_info" | jq -r '.ipv4.dns2')

			echo "IPv4 Connection Information:"
			echo "IPv4 Address: $ipaddr"
			echo "IPv4 Gateway: $gateway"
			echo "Netmask: $netmask"
			echo "DNS 1: $dns1"
			echo "DNS 2: $dns2"

			json_add_string proto "static"

			json_add_array ipaddr
			json_add_string "" "$ipaddr"
			json_close_array

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

	if [ "$pdptype" = "ipv6" ] || [ "$pdptype" = "ipv4v6" ]; then
		ip -6 addr flush dev $ifname6

		json_init
		json_add_string name "${interface}_6"
		json_add_string device "$ifname6"
		[ "$pdptype" = "ipv4v6" ] && json_add_string iface_464xlat "0"
		if [ -z "$dhcpv6" -o "$dhcpv6" = 0 ]; then
			conn_info=$(get_connection_info "/tmp/$ifname6");

			ip6addr=$(echo "$conn_info" | jq -r '.ipv6.ip6addr')
			gateway=$(echo "$conn_info" | jq -r '.ipv6.gateway')
			prefix=$(echo "$conn_info" | jq -r '.ipv6.prefix')
			dns1=$(echo "$conn_info" | jq -r '.ipv6.dns1')
			dns2=$(echo "$conn_info" | jq -r '.ipv6.dns2')

			echo "IPv6 Connection Information:"
			echo "IPv6 Address: $ip6addr"
			echo "IPv6 Gateway: $gateway"
			echo "Prefix length: $prefix"
			echo "DNS 1: $dns1"
			echo "DNS 2: $dns2"

			json_add_string proto "static"
			json_add_string ip6gw "$gateway"

			json_add_array ip6addr
			json_add_string "" "$ip6addr/$prefix"
			json_close_array

			json_add_array ip6prefix
			json_add_string "" "$ip6addr/$prefix"
			json_close_array

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
}

get_connection_info() {
	local interface_path="$1"
	local line
	while [ -z "$line" ]; do
		line=$(cat "$interface_path" | grep "Connection Information:")
		[ -z "$line" ] || echo $(echo "$line" | sed 's/^.*Connection Information: //')
		sleep 1;
	done
}

proto_quectel_teardown() {
	local interface="$1"

	local device multiplexing pdptype
	json_get_vars device multiplexing pdptype
	[ -z "$ctl_device" ] || device="$ctl_device"

	echo "Stopping network $interface"

	killall quectel-cm
	killall quectel-qmi-proxy

	if [ "$multiplexing" = 1 ]; then
		[ "$pdptype" = "ipv4" -o "$pdptype" = "ipv4v6" ] && ifdown "${interface}_4"
		[ "$pdptype" = "ipv6" -o "$pdptype" = "ipv4v6" ] && ifdown "${interface}_6"
	fi
	
	proto_init_update "*" 0
	proto_send_update "$interface"
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol quectel
}
