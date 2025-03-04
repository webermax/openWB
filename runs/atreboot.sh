#!/bin/bash
OPENWBBASEDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOGFILE="/var/log/openWB.log"
. "$OPENWBBASEDIR/helperFunctions.sh"

at_reboot() {
	echo "atreboot.sh started"
	(sleep 600; echo "checking for stalled atreboot after 10 minutes"; echo 0 > "$OPENWBBASEDIR/ramdisk/bootinprogress"; echo 0 > "$OPENWBBASEDIR/ramdisk/updateinprogress"; sudo kill "$$") &

	# read openwb.conf
	echo "loading config"
	. "$OPENWBBASEDIR/loadconfig.sh"

	# load some helper functions
	# no code will run here, functions need to be called
	. "$OPENWBBASEDIR/runs/initRamdisk.sh"
	. "$OPENWBBASEDIR/runs/updateConfig.sh"
	. "$OPENWBBASEDIR/runs/rfid/rfidHelper.sh"
	. "$OPENWBBASEDIR/runs/pushButtons/pushButtonsHelper.sh"

	sleep 5
	mkdir -p "$OPENWBBASEDIR/web/backup"
	touch "$OPENWBBASEDIR/web/backup/.donotdelete"
	# web/backup and web/tools/upload are used to (temporarily) store backup files for download and for restoring.
	# files are created from PHP as user www-data, thus www-data needs write permissions.
	sudo chown -R pi:www-data "$OPENWBBASEDIR/"{web/backup,web/tools/upload}
	sudo chmod -R g+w "$OPENWBBASEDIR/"{web/backup,web/tools/upload}

	sudo chmod 777 "$OPENWBBASEDIR/openwb.conf"
	sudo chmod 777 "$OPENWBBASEDIR/smarthome.ini"
	sudo chmod 777 "$OPENWBBASEDIR/ramdisk"
	sudo chmod 777 "$OPENWBBASEDIR/ramdisk/"
	sudo chmod 777 "$OPENWBBASEDIR/web/files/"*
	sudo chmod -R +x "$OPENWBBASEDIR/modules/"*

	sudo chmod -R 777 "$OPENWBBASEDIR/modules/soc_i3"
	sudo chmod -R 777 "$OPENWBBASEDIR/modules/soc_eq"
	sudo chmod -R 777 "$OPENWBBASEDIR/modules/soc_tesla"

	sudo chmod 777 "$OPENWBBASEDIR/web/files/"*
	sudo chmod -R +x "$OPENWBBASEDIR/modules/"*

	mkdir -p "$OPENWBBASEDIR/web/logging/data/daily"
	mkdir -p "$OPENWBBASEDIR/web/logging/data/monthly"
	mkdir -p "$OPENWBBASEDIR/web/logging/data/ladelog"
	mkdir -p "$OPENWBBASEDIR/web/logging/data/v001"
	sudo chmod -R 777 "$OPENWBBASEDIR/web/logging/data/"
	sudo chmod +x "$OPENWBBASEDIR/packages/"*.sh

	# update openwb.conf
	updateConfig
	# reload our changed openwb.conf
	. "$OPENWBBASEDIR/loadconfig.sh"
	# now setup all files in ramdisk
	initRamdisk

	# standard socket - activated after reboot due to RASPI init defaults so we need to disable it as soon as we can
	if [[ $standardSocketInstalled == "1" ]]; then
		echo "turning off standard socket ..."
		sudo python "$OPENWBBASEDIR/runs/standardSocket.py" off
	fi

	# initialize automatic phase switching
	if (( u1p3paktiv == 1 )); then
		echo "triginit..."
		# quick init of phase switching with default pause duration (2s)
		sudo python "$OPENWBBASEDIR/runs/triginit.py"
	fi

	# setup push buttons handler if needed
	pushButtonsSetup "$ladetaster" 1

	# check for rse and restart daemon
	sudo pkill -f '^python.*/rse.py'
	if (( rseenabled == 1 )); then
		echo "rse..."
		if ! [ -x "$(command -v nmcli)" ]; then  # hack to prevent running the daemon on openwb standalone
			nohup python "$OPENWBBASEDIR/runs/rse.py" >>"$LOGFILE" 2>&1 &
		fi
	fi

	# setup rfid handler if needed
	rfidSetup "$rfidakt" 1 "$rfidlist"

	# check if tesla wall connector is configured and start daemon
	if [[ $evsecon == twcmanager ]]; then
		echo "twcmanager..."
		if [[ $twcmanagerlp1ip == "localhost/TWC" ]]; then
			screen -dm -S TWCManager /var/www/html/TWC/TWCManager.py &
		fi
	fi

	# restart our modbus server
	echo "modbus server..."
	sudo pkill -f '^python.*/modbusserver.py' > /dev/null
	sudo nohup python3 "$OPENWBBASEDIR/runs/modbusserver/modbusserver.py" >>"$LOGFILE" 2>&1 &

	# check if display is configured and setup timeout
	if (( displayaktiv == 1 )); then
		echo "display..."
		if ! grep -Fq "pinch" /home/pi/.config/lxsession/LXDE-pi/autostart
		then
			echo "not found"
			echo "@xscreensaver -no-splash" > /home/pi/.config/lxsession/LXDE-pi/autostart
			echo "@point-rpi" >> /home/pi/.config/lxsession/LXDE-pi/autostart
			echo "@xset s 600" >> /home/pi/.config/lxsession/LXDE-pi/autostart
			echo "@chromium-browser --incognito --disable-pinch --kiosk http://localhost/openWB/web/display.php" >> /home/pi/.config/lxsession/LXDE-pi/autostart
		fi
		echo "deleting browser cache"
		rm -rf /home/pi/.cache/chromium
	fi

	# restart smarthomehandler
	echo "smarthome handler..."
	# we need sudo to kill in case of an update from an older version where this script was not run as user `pi`:
	sudo pkill -f '^python.*/smarthomehandler.py'
	sudo pkill -f '^python.*/smarthomemq.py'
	smartmq=$(<"$OPENWBBASEDIR/ramdisk/smartmq")
	if (( smartmq == 0 )); then
		echo "starting legacy smarthome handler"
		nohup python3 "$OPENWBBASEDIR/runs/smarthomehandler.py" >> "$OPENWBBASEDIR/ramdisk/smarthome.log" 2>&1 &
	else
		echo "starting smarthomemq handler"
		nohup python3 "$OPENWBBASEDIR/runs/smarthomemq.py" >> "$OPENWBBASEDIR/ramdisk/smarthome.log" 2>&1 &
	fi

	# restart mqttsub handler
	echo "mqtt handler..."
	# we need sudo to kill in case of an update from an older version where this script was not run as user `pi`:
	sudo pkill -f '^python.*/mqttsub.py'
	nohup python3 "$OPENWBBASEDIR/runs/mqttsub.py" >>"$LOGFILE" 2>&1 &

	# restart legacy run server
	echo "legacy run server..."
	bash "$OPENWBBASEDIR/packages/legacy_run_server.sh"

	# check crontab for user pi
	echo "crontab 1..."
	crontab -l -u pi > "$OPENWBBASEDIR/ramdisk/tmpcrontab"
	if grep -Fq "lade.log" "$OPENWBBASEDIR/ramdisk/tmpcrontab"
	then
		echo "crontab modified"
		sed -i '/lade.log/d' "$OPENWBBASEDIR/ramdisk/tmpcrontab"
		echo "* * * * * $OPENWBBASEDIR/regel.sh >> /var/log/openWB.log 2>&1" >> "$OPENWBBASEDIR/ramdisk/tmpcrontab"
		cat "$OPENWBBASEDIR/ramdisk/tmpcrontab" | crontab -u pi -
	fi

	# check crontab for user root and remove old @reboot entry
	sudo crontab -l > "$OPENWBBASEDIR/ramdisk/tmprootcrontab"
	if grep -Fq "atreboot.sh" "$OPENWBBASEDIR/ramdisk/tmprootcrontab"
	then
		echo "executed"
		sed -i '/atreboot.sh/d' "$OPENWBBASEDIR/ramdisk/tmprootcrontab"
		cat "$OPENWBBASEDIR/ramdisk/tmprootcrontab" | sudo crontab -
	fi

	# check for LAN/WLAN connection
	echo "LAN/WLAN..."
	ethstate=$(</sys/class/net/eth0/carrier)
	if (( ethstate == 1 )); then
		sudo ifconfig eth0:0 "$virtual_ip_eth0" netmask 255.255.255.0 up
	else
		sudo ifconfig wlan0:0 "$virtual_ip_wlan0" netmask 255.255.255.0 up
	fi

	# check for apache configuration
	echo "apache..."
	if grep -Fxq "AllowOverride" /etc/apache2/sites-available/000-default.conf
	then
		echo "...ok"
	else
		sudo cp "$OPENWBBASEDIR/web/tools/000-default.conf" /etc/apache2/sites-available/
		echo "...changed"
	fi

	# add some crontab entries for user pi
	echo "crontab 2..."
	if ! sudo grep -Fq "cronnightly.sh" /var/spool/cron/crontabs/pi
	then
		(crontab -l -u pi ; echo "1 0 * * * $OPENWBBASEDIR/runs/cronnightly.sh >> /var/log/openWB.log 2>&1")| crontab -u pi -
	fi
	if ! sudo grep -Fq "cron5min.sh" /var/spool/cron/crontabs/pi
	then
		(crontab -l -u pi ; echo "*/5 * * * * $OPENWBBASEDIR/runs/cron5min.sh >> /var/log/openWB.log 2>&1")| crontab -u pi -
	fi
	if ! sudo grep -Fq "atreboot.sh" /var/spool/cron/crontabs/pi
	then
		(crontab -l -u pi ; echo "@reboot $OPENWBBASEDIR/runs/atreboot.sh >> /var/log/openWB.log 2>&1")| crontab -u pi -
	fi

	# check for needed packages
	echo "packages 1..."
	if python -c "import evdev" &> /dev/null; then
		echo 'evdev for python2 installed...'
	else
		sudo pip install evdev
	fi
	if python3 -c "import evdev" &> /dev/null; then
		echo 'evdev for python3 installed...'
	else
		sudo pip3 install evdev
	fi
	if ! [ -x "$(command -v sshpass)" ];then
		sudo apt-get -qq update
		sleep 1
		sudo apt-get -qq install sshpass
	fi
	if [ "$(dpkg-query -W -f='${Status}' php-gd 2>/dev/null | grep -c "ok installed")" -eq 0 ];
	then
		sudo apt-get -qq update
		sleep 1
		sudo apt-get -qq install -y php-gd
		sleep 1
		sudo apt-get -qq install -y php7.0-xml
	fi
	# required package for soc_vwid
	if [ "$(dpkg-query -W -f='${Status}' libxslt1-dev 2>/dev/null | grep -c "ok installed")" -eq 0 ];
	then
		sudo apt-get -qq update
		sleep 1
		sudo apt-get -qq install -y libxslt1-dev
	fi
	# no need to reload config
	# . $OPENWBBASEDIR/loadconfig.sh

	# update old ladelog
	"$OPENWBBASEDIR/runs/transferladelog.sh"

	# check for led handler
	if (( ledsakt == 1 )); then
		echo "led..."
		sudo python "$OPENWBBASEDIR/runs/leds.py" startup
	fi

	# setup timezone
	echo "timezone..."
	sudo cp /usr/share/zoneinfo/Europe/Berlin /etc/localtime


	if [ ! -f /home/pi/ssl_patched ]; then
		sudo apt-get update
		sudo apt-get -qq install -y openssl libcurl3 curl libgcrypt20 libgnutls30 libssl1.1 libcurl3-gnutls libssl1.0.2 php7.0-cli php7.0-gd php7.0-opcache php7.0 php7.0-common php7.0-json php7.0-readline php7.0-xml php7.0-curl libapache2-mod-php7.0
		touch /home/pi/ssl_patched
	fi


	# check for mosquitto packages
	echo "mosquitto..."
	if [ ! -f /etc/mosquitto/mosquitto.conf ]; then
		sudo apt-get update
		sudo apt-get -qq install -y mosquitto mosquitto-clients
		sudo service mosquitto start
	fi

	# check for mosquitto configuration
	if [ ! -f /etc/mosquitto/conf.d/openwb.conf ] || ! sudo grep -Fq "persistent_client_expiration" /etc/mosquitto/mosquitto.conf; then
		echo "updating mosquitto config file"
		sudo cp "$OPENWBBASEDIR/web/files/mosquitto.conf" /etc/mosquitto/conf.d/openwb.conf
		sudo service mosquitto reload
	fi

	# check for other dependencies
	echo "packages 2..."
	if python3 -c "import paho.mqtt.publish as publish" &> /dev/null; then
		echo 'mqtt installed...'
	else
		sudo apt-get -qq install -y python3-pip
		sudo pip3 install paho-mqtt
	fi
	if python3 -c "import docopt" &> /dev/null; then
		echo 'docopt installed...'
	else
		sudo pip3 install docopt
	fi
	if python3 -c "import certifi" &> /dev/null; then
		echo 'certifi installed...'
	else
		sudo pip3 install certifi
	fi
	if python3 -c "import aiohttp" &> /dev/null; then
		echo 'aiohttp installed...'
	else
		sudo pip3 install aiohttp
	fi
	if python3 -c "import pymodbus" &> /dev/null; then
		echo 'pymodbus installed...'
	else
		sudo pip3 install pymodbus
	fi
	if python3 -c "import requests" &> /dev/null; then
		echo 'python requests installed...'
	else
		sudo pip3 install requests
	fi
	#Prepare for jq in Python
	if python3 -c "import jq" &> /dev/null; then
		echo 'jq installed...'
	else
		sudo pip3 install jq
	fi
	#Prepare for ipparser in Python
	if python3 -c "import ipparser" &> /dev/null; then
		echo 'ipparser installed...'
	else
		sudo pip3 install ipparser
	fi
	#Prepare for lxml used in soc module libvwid in Python
	if python3 -c "import lxml" &> /dev/null; then
		echo 'lxml installed...'
	else
		sudo pip3 install lxml
	fi
	#Prepare for secrets used in soc module libvwid in Python
	VWIDMODULEDIR="$OPENWBBASEDIR/modules/soc_vwid"
	if python3 -c "import secrets" &> /dev/null; then
		echo 'soc_vwid: python3 secrets installed...'
		if [ -L "$VWIDMODULEDIR/secrets.py" ]; then
			echo 'soc_vwid: remove local python3 secrets.py...'
			rm "$VWIDMODULEDIR/secrets.py"
		fi
	else
		if [ ! -L "$VWIDMODULEDIR/secrets.py" ]; then
			echo 'soc_vwid: enable local python3 secrets.py...'
			ln -s "$VWIDMODULEDIR/_secrets.py" "$VWIDMODULEDIR/secrets.py"
		fi
	fi
	# update outdated urllib3 for Tesla Powerwall
	pip3 install --upgrade urllib3

	# update version
	echo "version..."
	uuid=$(</sys/class/net/eth0/address)
	owbv=$(<"$OPENWBBASEDIR/web/version")
	curl --connect-timeout 10 -d "update=\"${releasetrain}${uuid}vers${owbv}\"" -H "Content-Type: application/x-www-form-urlencoded" -X POST https://openwb.de/tools/update.php

	# all done, remove warning in display
	echo "clear warning..."
	echo "" > "$OPENWBBASEDIR/ramdisk/lastregelungaktiv"
	echo "" > "$OPENWBBASEDIR/ramdisk/mqttlastregelungaktiv"
	chmod 777 "$OPENWBBASEDIR/ramdisk/mqttlastregelungaktiv"

	# check for slave config and restart handler
	# we need sudo to kill in case of an update from an older version where this script was not run as user `pi`:
	sudo pkill -f '^python.*/isss.py'
	if (( isss == 1 )); then
		echo "isss..."
		echo "$lastmanagement" > "$OPENWBBASEDIR/ramdisk/issslp2act"
		nohup python3 "$OPENWBBASEDIR/runs/isss.py" >>"$OPENWBBASEDIR/ramdisk/isss.log" 2>&1 &
		# second IP already set up !
		ethstate=$(</sys/class/net/eth0/carrier)
		if (( ethstate == 1 )); then
			sudo ifconfig eth0:0 "$virtual_ip_eth0" netmask 255.255.255.0 down
		else
			sudo ifconfig wlan0:0 "$virtual_ip_wlan0" netmask 255.255.255.0 down
		fi
	fi

	# check for socket system and start handler
	# we need sudo to kill in case of an update from an older version where this script was not run as user `pi`:
	sudo pkill -f '^python.*/buchse.py'
	if [[ "$evsecon" == "buchse" ]]  && [[ "$isss" == "0" ]]; then
		echo "socket..."
		# ppbuchse is used in issss.py to detect "openWB Buchse"
		if [ ! -f /home/pi/ppbuchse ]; then
			echo "32" > /home/pi/ppbuchse
		fi
		nohup python3 "$OPENWBBASEDIR/runs/buchse.py" >>"$LOGFILE" 2>&1 &
	fi

	# update display configuration
	echo "display update..."
	if grep -Fq "@chromium-browser --incognito --disable-pinch --kiosk http://localhost/openWB/web/display.php" /home/pi/.config/lxsession/LXDE-pi/autostart
	then
		sed -i "s,@chromium-browser --incognito --disable-pinch --kiosk http://localhost/openWB/web/display.php,@chromium-browser --incognito --disable-pinch --overscroll-history-navigation=0 --kiosk http://localhost/openWB/web/display.php,g" /home/pi/.config/lxsession/LXDE-pi/autostart
	fi

	# get local ip
	ip route get 1 | awk '{print $7;exit}' > "$OPENWBBASEDIR/ramdisk/ipaddress"

	# update our local version
	sudo git -C "$OPENWBBASEDIR" show --pretty='format:%ci [%h]' | head -n1 > "$OPENWBBASEDIR/web/lastcommit"
	# and record the current commit details
	commitId=$(git -C "$OPENWBBASEDIR" log --format="%h" -n 1)
	echo "$commitId" > "$OPENWBBASEDIR/ramdisk/currentCommitHash"
	git -C "$OPENWBBASEDIR" branch -a --contains "$commitId" | perl -nle 'm|.*origin/(.+).*|; print $1' | uniq | xargs > "$OPENWBBASEDIR/ramdisk/currentCommitBranches"
	sudo chmod 777 "$OPENWBBASEDIR/ramdisk/currentCommitHash"
	sudo chmod 777 "$OPENWBBASEDIR/ramdisk/currentCommitBranches"

	# update broker
	echo "update broker..."
	for i in $(seq 1 9);
	do
		configured=$(timeout 1 mosquitto_sub -C 1 -t "openWB/config/get/SmartHome/Devices/$i/device_configured")
		if ! [[ "$configured" == 0 || "$configured" == 1 ]]; then
			mosquitto_pub -r -t "openWB/config/get/SmartHome/Devices/$i/device_configured" -m "0"
		fi
	done
	mosquitto_pub -r -t openWB/graph/boolDisplayLiveGraph -m "1"
	mosquitto_pub -t openWB/global/strLastmanagementActive -r -m ""
	mosquitto_pub -t openWB/lp/1/W -r -m "0"
	mosquitto_pub -t openWB/lp/2/W -r -m "0"
	mosquitto_pub -t openWB/lp/3/W -r -m "0"
	mosquitto_pub -t openWB/lp/1/boolChargePointConfigured -r -m "1"
	mosquitto_pub -r -t openWB/SmartHome/Devices/1/TemperatureSensor0 -m ""
	mosquitto_pub -r -t openWB/SmartHome/Devices/1/TemperatureSensor1 -m ""
	mosquitto_pub -r -t openWB/SmartHome/Devices/1/TemperatureSensor2 -m ""
	mosquitto_pub -r -t openWB/SmartHome/Devices/2/TemperatureSensor0 -m ""
	mosquitto_pub -r -t openWB/SmartHome/Devices/2/TemperatureSensor1 -m ""
	mosquitto_pub -r -t openWB/SmartHome/Devices/2/TemperatureSensor2 -m ""
	rm -rf "$OPENWBBASEDIR/web/themes/dark19_01"
	(sleep 10; mosquitto_pub -t openWB/set/ChargeMode -r -m "$bootmodus") &
	(sleep 10; mosquitto_pub -t openWB/global/ChargeMode -r -m "$bootmodus") &
	echo " " > "$OPENWBBASEDIR/ramdisk/lastregelungaktiv"
	chmod 777 "$OPENWBBASEDIR/ramdisk/lastregelungaktiv"
	chmod 777 "$OPENWBBASEDIR/ramdisk/smarthome.log"
	chmod 777 "$OPENWBBASEDIR/ramdisk/smarthomehandlerloglevel"

	# update etprovider pricelist
	echo "etprovider..."
	if [[ "$etprovideraktiv" == "1" ]]; then
		echo "update electricity pricelist..."
		echo "" > "$OPENWBBASEDIR/ramdisk/etprovidergraphlist"
		mosquitto_pub -r -t openWB/global/ETProvider/modulePath -m "$etprovider"
		nohup "$OPENWBBASEDIR/modules/$etprovider/main.sh" >>"$LOGFILE" 2>&1 &
	else
		echo "not activated, skipping"
		mosquitto_pub -r -t openWB/global/awattar/pricelist -m ""
	fi

	# set upload limit in php
	#prepare for Buster
	echo -n "fix upload limit..."
	if [ -d "/etc/php/7.0/" ]; then
		echo "OS Stretch"
		sudo /bin/su -c "echo 'upload_max_filesize = 300M' > /etc/php/7.0/apache2/conf.d/20-uploadlimit.ini"
		sudo /bin/su -c "echo 'post_max_size = 300M' >> /etc/php/7.0/apache2/conf.d/20-uploadlimit.ini"
	elif [ -d "/etc/php/7.3/" ]; then
		echo "OS Buster"
		sudo /bin/su -c "echo 'upload_max_filesize = 300M' > /etc/php/7.3/apache2/conf.d/20-uploadlimit.ini"
		sudo /bin/su -c "echo 'post_max_size = 300M' >> /etc/php/7.3/apache2/conf.d/20-uploadlimit.ini"
	fi
	sudo /usr/sbin/apachectl -k graceful

	# all done, remove boot and update status
	echo "$(date +"%Y-%m-%d %H:%M:%S:") boot done :-)"
	echo 0 > "$OPENWBBASEDIR/ramdisk/bootinprogress"
	echo 0 > "$OPENWBBASEDIR/ramdisk/updateinprogress"
	mosquitto_pub -t openWB/system/updateInProgress -r -m "0"
	mosquitto_pub -t openWB/system/reloadDisplay -m "1"
}

openwbRunLoggingOutput at_reboot
