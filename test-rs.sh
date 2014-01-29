#!/bin/bash

# Note: RackSpace has hidden some of the images. Please see this page
# http://www.rackspace.com/knowledge_center/article/hidden-base-images

set -exu

SCRIPT_TO_INSTALL="xenapi-in-rs.sh"
INSTALL_TARGET="/opt/nodepool-scripts/xenserver_cloud.sh"
XENSERVER_PASSWORD=xspassword
STAGING_VM_URL="$1"

function main() {
    launch_vm testvm "62df001e-87ee-407c-b042-6f4e13f5d7e1"
    start_install
    ./wait-until-done.sh $VM_IP $PRIVKEY
    prepare_for_snapshot
    wait_till_snapshottable
    delete_all_images testimage
    perform_snapshot testvm testimage
    launch_vm snapvm testimage
    ./wait-until-done.sh $VM_IP $PRIVKEY
    test_ssh_access_to_dom0
    nova image-delete testimage

    echo "ALL TESTS PASSED"
}

function wait_for_ssh() {
    while ! echo "kk" | nc -w 1 "$VM_IP" 22 > /dev/null 2>&1; do
            sleep 1
            echo -n "x"
    done
}

function launch_vm() {
    local vm_name
    local image_name

    vm_name="$1"
    image_name="$2"

    PRIVKEY="$vm_name.pem"
    privkey_name="tempkey-$vm_name"

    rm -f "$PRIVKEY" || true
    nova keypair-delete "$privkey_name" || true
    nova delete "$vm_name" || true

    while nova list | grep -q "$vm_name"; do
        sleep 1
    done

    nova keypair-add "$privkey_name" > "$PRIVKEY"
    chmod 0600 "$PRIVKEY"

    nova boot \
        --poll \
	--image "$image_name" \
	--flavor "performance1-8" \
	"$vm_name" --key-name "$privkey_name"

    VM_IP=$(./get-ip-address-of-instance.sh $vm_name)

    set +x
    wait_for_ssh
    set -x
}

COMMON_SSH_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp $COMMON_SSH_OPTIONS"
SSH="ssh -o BatchMode=yes $COMMON_SSH_OPTIONS"

function start_install() {
    $SSH -i $PRIVKEY root@$VM_IP mkdir -p $(dirname "$INSTALL_TARGET")
    $SCP -i $PRIVKEY $SCRIPT_TO_INSTALL "root@$VM_IP:$INSTALL_TARGET"
    $SSH -i $PRIVKEY root@$VM_IP bash "$INSTALL_TARGET" "$XENSERVER_PASSWORD" "$STAGING_VM_URL"
}

function wait_till_snapshottable() {
    sleep 20
}

function prepare_for_snapshot() {
    # Copy over ssh key
    $SCP -i $PRIVKEY $PRIVKEY root@$VM_IP:key
    $SSH -i $PRIVKEY root@$VM_IP "chmod 0600 key"
    $SSH -i $PRIVKEY root@$VM_IP "rm -f $(./print-stamp-path.sh)"
    $SSH -i $PRIVKEY root@$VM_IP "$SSH -i key root@192.168.33.2" << EOF
# These instructions are executed on dom0
set -eux
halt -p
EOF
}

function perform_snapshot() {
    local vm_name
    local snapshot_name

    vm_name="$1"
    snapshot_name="$2"

    nova image-create --poll "$vm_name" "$snapshot_name"
}

function delete_all_images() {
    local image_name

    nova image-list |
        grep testimage |
        sed -e 's/|//g' -e 's/ \+/ /g' -e 's/^ *//g' |
        cut -d" " -f 1 |
        while read imageid; do
            nova image-delete $imageid
        done
}

function test_ssh_access_to_dom0() {
    local vm_ip
    local privkey_path

    vm_ip="$VM_IP"
    privkey_path="$PRIVKEY"

    $SSH -i $PRIVKEY root@$VM_IP bash << EOF
set -eux
sudo -u domzero ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@192.168.33.2 true
EOF
}

main