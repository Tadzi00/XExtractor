#!/bin/sh
cat <<'HELP'
================  WiFi commands  ================
  wifi-status    connection state, config source, and why it failed
  wifi-scan      list nearby WiFi networks (SSID, signal, freq)
  wifi-connect   (re)connect using the configured SSID/password
  wifi-help      this help

Configure WiFi in miner.conf on the USB stick:
  WIFI_SSID=YourNetwork
  WIFI_PASS=YourPassword       (8-63 chars; leave blank for open networks)
  WIFI_COUNTRY=PL              (2-letter country code; needed for some channels)
Leave WIFI_SSID blank to use Ethernet instead.

Other handy commands:
  check-drives                 find the config stick / list all partitions
  tail -f /var/log/miner.log   live miner + WiFi log
  grep -i wifi /var/log/miner.log   just the WiFi lines
=================================================
HELP
