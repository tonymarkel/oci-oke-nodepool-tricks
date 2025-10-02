#!/bin/bash
# Runs instance operations in parallel to OKE operations
# in order to speed up node ready times for OKE. Useful
# if there are configurations that are unique to the node.
# This script builds on optimizations by creating a custom
# node imge.

# Functions:
#  - Adds Block Volumes
#  - Attaches and Configures a Secondary NIC
#    Note: Assumes subnet is named oke-secondary-vnic-subnet

# NOTE: This script is provided as-is with no warranties expressed or implied

set -euo pipefail

# Logging function to prepend timestamps
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $1"
}

# Function to create and attach a volume
create_and_attach_volume() {
  local display_name="$1"
  local size_in_gbs="$2"
  local vpus_per_gb="$3"
  local device_path="$4"
  local volume_name="$5"
  local device_name="$6"
  
  log "Creating volume $display_name ($size_in_gbs G, vpus-per-gb=$vpus_per_gb)"
  local volume_id=$(oci bv volume create --compartment-id "$compartment" \
    --availability-domain "$ad" \
    --display-name "$display_name" --size-in-gbs "$size_in_gbs" \
    --vpus-per-gb "$vpus_per_gb" \
    --wait-for-state AVAILABLE --query 'data.id' --raw-output)
  log "Volume $display_name created: $volume_id"

  log "Attaching volume $display_name to $device_path"
  oci compute volume-attachment attach --type paravirtualized \
    --instance-id "$instance" --volume-id "$volume_id" \
    --device "$device_path" --wait-for-state ATTACHED
  log "Volume $display_name attached"
  log "Formatting $device_name as ext4 with label $volume_name"
  mkfs -t ext4 -L $volume_name $device_name
  log "Formatted $device_name"
}

# See if there is a network on the secondary already. If not, attach one and configure it.
create_and_attach_vnic () {
  vnics=$(curl -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/vnics | jq -r .[].vlanTag | uniq | wc -l)
  if [ $vnics -lt 2 ]; then
    log "Creating and attaching vnic"
    oci compute instance attach-vnic --instance-id $instance --subnet-id $subnetid --wait --skip-source-dest-check TRUE --auth instance_principal
    # --assign-public-ip true # if you want a public IP on the secondary VNIC
    sleep 15 # wait for the VNIC to be fully attached before configuring
    log "Configuring secondary vnic"
    sudo oci-network-config configure
    log "Secondary vnic attached and configured"
  else
    log "Secondary VNIC already configured"
  fi
}

log "Starting cloud-init script, writing to $LOGFILE"

# --- Install OCI CLI using package manager ---
log "Checking for OCI CLI installation"
if ! command -v oci &> /dev/null; then
  log "OCI CLI not found, enabling repo and installing via dnf for Oracle Linux 8..."
  #sudo dnf -y install oraclelinux-developer-release-el8
  sudo dnf install -y python36-oci-cli
  log "OCI CLI installed via package manager"
else
  log "OCI CLI already installed"
fi

# Verify OCI CLI version
log "OCI CLI version: $(oci --version)"

# --- auth & metadata ---
log "Fetching instance metadata"
# Get instance information
metadata=$(curl -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/)
instance=$(echo $metadata | jq -r .id)
compartment=$(echo $metadata | jq -r .compartmentId)
region=$(echo $metadata | jq -r .region)
ad=$(echo $metadata | jq .availabilityDomain)
vnics=$(curl -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/vnics/)
primary_vnicid=$(echo $vnics | jq -r '.[0].vnicId')
vcn_compartment=$(oci network vnic get --vnic-id $primary_vnicid --auth instance_principal | jq -r '.data."compartment-id"')
subnets=$(oci network subnet list --compartment-id $vcn_compartment --auth instance_principal)
vcn=$(echo $subnets | jq -r '.data[] | select(."display-name" == "oke-secondary-vnic-subnet")."vcn-id"')
subnetid=$(echo $subnets | jq -r '.data[] | select(."display-name" == "oke-secondary-vnic-subnet").id')
export OCI_CLI_REGION="$region"
export OCI_CLI_AUTH=instance_principal

log "Retrieved metadata: instance=$instance, compartment=$compartment, ad=$ad, region=$region"

# Create and attach two block volumes in parallel
log "Creating, and attaching volumes in parallel"
create_and_attach_volume "ads-$(hostname -s)-data1" 800 50 "/dev/oracleoci/oraclevdb" "/export" "/dev/sdb" &
create_and_attach_volume "ads-$(hostname -s)-data2" 800 50 "/dev/oracleoci/oraclevdc" "/data" "/dev/sdc" &

# Create and Attach one secondary VNIC in parallel
log "Creating, attaching, and configuring a secondary vnic"
create_and_attach_vnic &

# Attach node to cluster
log "Fetching and decoding OKE init script"
curl -fsSL -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/metadata/oke_init_script | base64 -d > /var/run/oke-init.sh
chmod +x /var/run/oke-init.sh
log "OKE init script downloaded and made executable"

log "Executing OKE init script with taints"
bash /var/run/oke-init.sh --kubelet-extra-args "--register-with-taints=dedicated=ads:NoSchedule"
log "OKE init script executed successfully"

log "Cloud-init script completed"
