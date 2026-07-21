#!/bin/sh

set -e

DIR="${1:-.}"

mv /usr/bin/lsusb /usr/bin/lsusb.old

find "$DIR" -maxdepth 1 -type f -name "[0-9][0-9]_*.ipk" | sort | while read -r pkg; do
    echo "Installing $pkg..."
    opkg install "./$pkg" || exit 1
done

chmod +x wd-hub-switcher.sh
cp wd-hub-switcher.sh /usr/sbin

cp hubs.json /etc/hubs.json

cp wd-hub-switcher /etc/init.d
chmod +x /etc/init.d/wd-hub-switcher

#/etc/init.d/wd-hub-switcher enable
#/etc/init.d/wd-hub-switcher start
