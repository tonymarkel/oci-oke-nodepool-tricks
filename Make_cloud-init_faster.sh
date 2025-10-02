#!/bin/bash
# Runs instance operations in parallel to OKE operations
# in order to speed up node ready times for OKE
# This script is provided as-is with no warranties expressed or implied

set -euo pipefail

LOGFILE="${LOGFILE:-/var/log/ads-bv.log}"

# Redirect output to log file
if [ "$(id -u)" -ne 0 ] || [ ! -w "$(dirname "$LOGFILE")" ]; then
  LOGFILE="$HOME/ads-bv.log"
fi
exec > >(tee -a "$LOGFILE") 2>&1

# Logging function to prepend timestamps
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $1"
}

# Function to create and attach a volume
create_and_attach_volume() {
  local compartment_id="$1"
  local availability_domain="$2"
  local display_name="$3"
  local size_in_gbs="$4"
  local vpus_per_gb="$5"
  local device_path="$6"
  local instance_id="$7"
  local volume_name="$8"
  local device_name="$9"
  
  log "Creating volume $display_name ($size_in_gbs G, vpus-per-gb=$vpus_per_gb)"
  local volume_id=$(oci bv volume create --compartment-id "$compartment_id" \
    --availability-domain "$availability_domain" \
    --display-name "$display_name" --size-in-gbs "$size_in_gbs" \
    --vpus-per-gb "$vpus_per_gb" \
    --wait-for-state AVAILABLE --query 'data.id' --raw-output)
  log "Volume $display_name created: $volume_id"

  log "Attaching volume $display_name to $device_path"
  oci compute volume-attachment attach --type paravirtualized \
    --instance-id "$instance_id" --volume-id "$volume_id" \
    --device "$device_path" --wait-for-state ATTACHED
  log "Volume $display_name attached"
  log "Formatting $device_name as ext4 with label $volume_name"
  mkfs -t ext4 -L $volume_name $device_name
  log "Formatted $device_name"
}

create

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
export OCI_CLI_AUTH=instance_principal
META=$(curl -sS -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance)
instance=$(echo "$META" | jq -r '.id')
compartment=$(echo "$META" | jq -r '.compartmentId')
ad=$(echo "$META" | jq -r '.availabilityDomain' | tr -d '\r')
region=$(echo "$META" | jq -r '.regionInfo.regionIdentifier // .canonicalRegionName // .region')
export OCI_CLI_REGION="$region"
log "Retrieved metadata: instance=$instance, compartment=$compartment, ad=$ad, region=$region"

# --- create and attach two block volumes in parallel ---
log "Creating and attaching volumes in parallel"
create_and_attach_volume "$compartment" "$ad" "ads-$(hostname -s)-data1" 800 50 "/dev/oracleoci/oraclevdb" "$instance" "export" "/dev/sdb" &
create_and_attach_volume "$compartment" "$ad" "ads-$(hostname -s)-data2" 800 50 "/dev/oracleoci/oraclevdc" "$instance" "export-data" "/dev/sdc" &

# Switch log file for taints section
exec > >(tee -a /var/log/ads-taints.log) 2>&1
log "Switching log output to /var/log/ads-taints.log"

log "Fetching and decoding OKE init script"
curl -fsSL -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/metadata/oke_init_script | base64 -d > /var/run/oke-init.sh
chmod +x /var/run/oke-init.sh
log "OKE init script downloaded and made executable"

log "Executing OKE init script with taints"
bash /var/run/oke-init.sh --kubelet-extra-args "--register-with-taints=dedicated=ads:NoSchedule"
log "OKE init script executed successfully"

log "Cloud-init script completed"
