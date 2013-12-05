#!/bin/bash
set -exu

VM_NAME="$1"
XENSERVER_PASSWORD="$2"

VM_KILLER_SCRIPT="kill-$VM_NAME.sh"

TEMPORARY_PRIVKEY="$VM_NAME.pem"
TEMPORARY_PRIVKEY_NAME="tempkey-$VM_NAME"

if nova keypair-list | grep -q "$TEMPORARY_PRIVKEY_NAME"; then
    echo "ERROR: A keypair already exists with the name $TEMPORARY_PRIVKEY_NAME"
    exit 1
fi

cat > "$VM_KILLER_SCRIPT" << EOF
#!/bin/bash

set -eux
EOF
chmod +x "$VM_KILLER_SCRIPT"

if nova list | grep -q "$VM_NAME"; then
    echo "ERROR: An instance already exists with the name $VM_NAME"
    exit 1
fi

function wait_for_ssh() {
    local host

    host="$1"

    set +x
    echo -n "Waiting for port 22 on ${host}"
    while ! echo "kk" | nc -w 1 "$host" 22 > /dev/null 2>&1; do
            sleep 1
            echo -n "."
    done
    echo "Connectable!"
    set -x
}

nova keypair-add "$TEMPORARY_PRIVKEY_NAME" > "$TEMPORARY_PRIVKEY"
chmod 0600 "$TEMPORARY_PRIVKEY"

cat >> "$VM_KILLER_SCRIPT" << EOF
nova keypair-delete "$TEMPORARY_PRIVKEY_NAME"
rm -f "$TEMPORARY_PRIVKEY"
EOF

nova boot \
	--image "Ubuntu 13.04 (Raring Ringtail) (PVHVM beta)" \
	--flavor "performance1-8" \
	"$VM_NAME" --key-name "$TEMPORARY_PRIVKEY_NAME"

while ! nova list | grep "$VM_NAME" | grep -q ACTIVE; do
	sleep 5
done

VM_ID=$(nova list | grep "$VM_NAME" | tr -d " " | cut -d "|" -f 2)

cat >> "$VM_KILLER_SCRIPT" << EOF
nova delete "$VM_ID"
EOF

while true; do
	VM_IP=$(nova show $VM_ID | grep accessIPv4 | tr -d " " | cut -d "|" -f 3)
	if [ -z "$VM_IP" ]; then
		sleep 1
	else
		break
	fi
done

wait_for_ssh "$VM_IP"

ssh -q \
    -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -i "$TEMPORARY_PRIVKEY" root@$VM_IP \
    bash -s -- << EOF
set -eux
halt -p
EOF

sleep 5

nova rescue "$VM_ID"

sleep 5

wait_for_ssh "$VM_IP"

cat shrink-xvdb.sh | ssh -q \
    -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -i "$TEMPORARY_PRIVKEY" root@$VM_IP \
    bash -s --

sleep 5

nova unrescue "$VM_ID"

sleep 5

wait_for_ssh "$VM_IP"

{
cat << EOF
XENSERVER_PASSWORD="$XENSERVER_PASSWORD"
EOF
cat start-xenserver-installer.sh
} | ssh -q \
    -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -i "$TEMPORARY_PRIVKEY" root@$VM_IP \
    bash -s --

sleep 30

wait_for_ssh "$VM_IP"

function copy_to_ubuntu() {
    local src
    local tgt

    src="$1"
    tgt="$2"

scp \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -i "$TEMPORARY_PRIVKEY" \
    "$src" "root@$VM_IP:$tgt"
}

copy_to_ubuntu first-cloud-boot/ubuntu-upstart.conf /etc/init/xenserver.conf
#copy_to_ubuntu first-cloud-boot/xenserver-firstboot-access-dom0.sh /root/xenserver-first-cloud-boot.sh
copy_to_ubuntu first-cloud-boot/xenserver-firstboot-access-staging.sh /root/xenserver-first-cloud-boot.sh
copy_to_ubuntu first-cloud-boot/ubuntu-boot-to-xenserver.sh /root/boot-to-xenserver.sh

ssh -q \
    -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -i "$TEMPORARY_PRIVKEY" root@$VM_IP \
    bash -s -- << EOF
set -eux
touch /root/xenserver-run.request
# You should shutdown and take a snapshot at this point
reboot
EOF

sleep 10

wait_for_ssh "$VM_IP"

cat << EOF
Finished.

To access XenServer:

ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i "$TEMPORARY_PRIVKEY" root@$VM_IP
EOF
