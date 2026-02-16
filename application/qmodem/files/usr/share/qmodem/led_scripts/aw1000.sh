#!/bin/sh

# envs
# LED mapping for Arcadyan AW1000
# Signal Quality LEDs
LED_SIG_POOR="red:signal"
LED_SIG_MEDIUM="blue:signal"
LED_SIG_GOOD="green:signal"

# Data Type LEDs
LED_TYPE_5G="green:5g"
LED_TYPE_4G="blue:5g"
LED_TYPE_3G="red:5g"

# Internet LED
LED_INTERNET="green:internet"

# WiFi LED
LED_WIFI="green:wifi"

. /usr/share/qmodem/modem_util.sh
. /lib/functions.sh

MODEM_CFG=$1
ON_OFF=$2

# Auto-detect modem config if not provided
if [ -z "$MODEM_CFG" ]; then
    config_load qmodem
    # Function to grab the first section
    first_section() {
        echo "$1"
        return 1 # Stop after first
    }
    MODEM_CFG=$(config_foreach first_section modem-device)
fi

echo "$(date): aw1000 script started. MODEM_CFG=$MODEM_CFG ON_OFF=$ON_OFF" >> /tmp/aw1000.log

if [ -z "$MODEM_CFG" ]; then
    echo "$(date): Error: No modem configuration found or provided." >> /tmp/aw1000.log
    exit 1
fi

update_cfg(){
        config_load qmodem
        config_get AT_PORT "$MODEM_CFG" at_port
        config_get ALIAS "$MODEM_CFG" alias
        config_get USE_UBUS "$MODEM_CFG" use_ubus
        [ "$USE_UBUS" = "1" ] && use_ubus_flag="-u"
}

update_netdev(){
        config_load network
        if [ -n "$ALIAS" ]; then
                config_get NET_DEV "$ALIAS" ifname
        else
                config_get NET_DEV "$MODEM_CFG" ifname
        fi
}

last_siminserted=""
last_netstat=""

led_turn() {
        local path="/sys/class/leds/$1"
        [ ! -d "$path" ] && return
        local value="$2"
        max_brightness=$(cat "$path/max_brightness")
        if [ "$value" = "1" ]; then
                brightness=$max_brightness
        else
                brightness="0"
        fi
        echo "none" > "$path/trigger"
        echo "$brightness" > "$path/brightness"
}

led_heartbeat() {
        local path="/sys/class/leds/$1"
        [ ! -d "$path" ] && return
        max_brightness=$(cat "$path/max_brightness")
        echo "$max_brightness" > "$path/brightness"
        echo "heartbeat" > "$path/trigger"
}

led_netdev() {
        local path="/sys/class/leds/$1"
        [ ! -d "$path" ] && return
        local device="$2"
        echo "none" > "$path/trigger"
        echo "1" > "$path/brightness"
        echo "netdev" > "$path/trigger"
        echo "$device" > "$path/device_name"
        echo "1" > "$path/link"
        echo "1" > "$path/rx"
        echo "1" > "$path/tx"
}

led_off_signal() {
        led_turn "${LED_SIG_POOR}" "0"
        led_turn "${LED_SIG_MEDIUM}" "0"
        led_turn "${LED_SIG_GOOD}" "0"
}

led_off_type() {
        led_turn "${LED_TYPE_5G}" "0"
        led_turn "${LED_TYPE_4G}" "0"
        led_turn "${LED_TYPE_3G}" "0"
}

led_off_all() {
        led_off_signal
        led_off_type
}

sim_inserted() {
        if at $AT_PORT "AT+CPIN?" | grep -q "CPIN: READY"; then
                echo "1"
        else
                echo "0"
        fi
}

internet_led() {
        if wget --spider --quiet --tries=1 --timeout=3 www.google.com; then
                led_turn "${LED_INTERNET}" "1"
        else
                led_turn "${LED_INTERNET}" "0"
        fi
}

wifi_led() {
        if grep -q "up" /sys/class/net/wlan*/operstate 2>/dev/null || \
           grep -q "up" /sys/class/net/ath*/operstate 2>/dev/null || \
           grep -q "up" /sys/class/net/phy*-ap*/operstate 2>/dev/null; then
                led_turn "${LED_WIFI}" "1"
        else
                led_turn "${LED_WIFI}" "0"
        fi
}

get_rat_type() {
        # RAT Codes: 0:GSM, 2:3G, 7:4G, 10-13:5G
        rat_code=$(at $AT_PORT "AT+COPS?" | grep +COPS: | awk -F, '{print $4}' | tr -d '"')
        if [ -z "$rat_code" ]; then
                echo "NONE"
        elif [ "$rat_code" -ge 10 ]; then
                echo "5G"
        elif [ "$rat_code" -eq 7 ]; then
                echo "4G"
        elif [ "$rat_code" -eq 2 ] || [ "$rat_code" -eq 0 ]; then
                echo "3G"
        else
                echo "UNKNOWN"
        fi
}

get_rsrp() {
        rsrp=$(/usr/share/qmodem/modem_ctrl.sh cell_info "$MODEM_CFG" | jq -r '.modem_info[] | select(.key=="RSRP") | .value')
        [ -z "$rsrp" ] && rsrp="0"
        if [ "$rsrp" -gt "0" ] || [ "$rsrp" -lt "-140" ]; then
                rsrp="0"
        fi
        echo "$rsrp"
}

main() {
        local siminserted="$(sim_inserted)"
        if [ "$siminserted" = "0" ] && [ "$siminserted" = "$last_siminserted" ]; then
                return
        fi

        last_siminserted="$siminserted"

        if [ "$siminserted" = "0" ]; then
                led_off_all
                led_turn "${LED_SIG_POOR}" "1"
                led_turn "${LED_TYPE_3G}" "1"
                last_netstat=""
                return
        fi

        local rat_type=$(get_rat_type)
        local rsrp=$(get_rsrp)
        local signal_level="0"

        # Signal levels
        if [ "$rsrp" -ge "-95" ] && [ "$rsrp" -lt "0" ]; then
                signal_level="2" # Good
        elif [ "$rsrp" -ge "-110" ] && [ "$rsrp" -lt "-95" ]; then
                signal_level="1" # Medium
        else
                signal_level="0" # Poor
        fi

        netstat="${NET_DEV}_${rat_type}_${signal_level}"
        if [ "$netstat" = "$last_netstat" ]; then
                return
        fi
        last_netstat="$netstat"

        led_off_all

        # 1. Handle Data Type LED (5G LED group)
        case "$rat_type" in
                "5G") led_turn "${LED_TYPE_5G}" "1" ;;
                "4G") led_turn "${LED_TYPE_4G}" "1" ;;
                "3G") led_turn "${LED_TYPE_3G}" "1" ;;
                *) led_off_type ;;
        esac

        # 2. Handle Signal Quality LED (Signal LED group)
        if [ "$rat_type" != "NONE" ] && [ "$rat_type" != "UNKNOWN" ]; then
                case "$signal_level" in
                        "0") led_turn "${LED_SIG_POOR}" "1" ;;
                        "1") led_turn "${LED_SIG_MEDIUM}" "1" ;;
                        "2") led_turn "${LED_SIG_GOOD}" "1" ;;
                esac
        else
                led_turn "${LED_SIG_POOR}" "1"
        fi
}

# Loop forever
update_cfg
if [ "$ON_OFF" = "off" ]; then
        led_off_all
        led_turn "${LED_INTERNET}" "0"
        led_turn "${LED_WIFI}" "0"
        exit 0
fi

while true; do
        update_netdev
        main
        internet_led
        wifi_led
        sleep 5s
done