#!/bin/bash
# WiFi AP management script using hostapd

INTERFACE="wlan0"
BRIDGE="br0"

start_ap() {
    echo "Starting WiFi AP..."
    
    # Ensure the interface is up
    ip link set $INTERFACE up
    
    # Add interface to bridge
    ip link set $INTERFACE master $BRIDGE || true
    
    # Start hostapd
    systemctl start hostapd
    
    echo "WiFi AP started"
}

stop_ap() {
    echo "Stopping WiFi AP..."
    
    # Stop hostapd
    systemctl stop hostapd
    
    # Remove interface from bridge
    ip link set $INTERFACE nomaster || true
    
    echo "WiFi AP stopped"
}

status_ap() {
    systemctl status hostapd
}

case "$1" in
    start)
        start_ap
        ;;
    stop)
        stop_ap
        ;;
    restart)
        stop_ap
        sleep 2
        start_ap
        ;;
    status)
        status_ap
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
