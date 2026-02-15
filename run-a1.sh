#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="./a1-provision.log"
CONFIG_FILE=""
ASSUME_YES=0
MODE="run"

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
    rm -rf "$TMP_DIR"
  fi
}

on_interrupt() {
  log "WARN" "INTERRUPTED" "Received interrupt signal, exiting."
  exit 2
}

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  local level="$1"
  local event="$2"
  local msg="$3"
  local line
  line="$(timestamp) [$level] [$event] $msg"
  printf "%s\n" "$line" | tee -a "$LOG_FILE"
}

die() {
  local event="$1"
  local msg="$2"
  log "ERROR" "$event" "$msg"
  exit 1
}

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME --setup [--yes]
  $SCRIPT_NAME --config a1-spec.yaml [--interval 45] [--jitter 15] [--log-file ./a1-provision.log] [--yes]

Options:
  --setup             Run beginner setup wizard (dependencies + OCI CLI config guidance)
  --config <path>     Path to YAML configuration file (required for run mode)
  --interval <sec>    Base retry interval in seconds (overrides YAML)
  --jitter <sec>      Max random jitter added to interval (overrides YAML)
  --log-file <path>   Log file path (default: ./a1-provision.log)
  --yes               Non-interactive mode (no prompts)
  -h, --help          Show this help
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_instructions() {
  cat <<'EOF'
Install dependencies:
  macOS (Homebrew):
    brew install oci-cli jq yq
  Ubuntu/Debian:
    sudo apt-get update
    sudo apt-get install -y jq
    # OCI CLI:
    bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
    # yq:
    sudo snap install yq
EOF
}

print_brew_permission_fix() {
  cat <<'EOF' | tee -a "$LOG_FILE"
Homebrew permission issue detected.
Run these commands, then rerun setup:

  sudo chown -R "$USER" /opt/homebrew
  chmod -R u+rwX /opt/homebrew
  git config --global --add safe.directory /opt/homebrew

  brew doctor
  brew install oci-cli yq
EOF
}

maybe_install_deps() {
  local missing=("$@")
  log "ERROR" "DEPENDENCY_MISSING" "Missing dependency(s): ${missing[*]}"
  install_instructions | tee -a "$LOG_FILE"

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    die "DEPENDENCY_MISSING" "Non-interactive mode enabled. Install dependencies and rerun."
  fi

  read -r -p "Attempt automatic install now? [y/N] " answer
  case "$answer" in
    [yY]|[yY][eE][sS])
      if [[ "$(uname -s)" == "Darwin" && -x "$(command -v brew)" ]]; then
        local brew_out_file
        brew_out_file="$TMP_DIR/brew_install.log"
        set +e
        brew install oci-cli jq yq >"$brew_out_file" 2>&1
        local brew_rc=$?
        set -e
        if [[ $brew_rc -ne 0 ]]; then
          cat "$brew_out_file" | tee -a "$LOG_FILE"
          if grep -qiE 'not writable by your user|permission denied|Operation not permitted|Command failed with exit 128: git|fatal: not in a git directory' "$brew_out_file"; then
            print_brew_permission_fix
            die "AUTO_INSTALL_FAILED" "Automatic dependency install failed due to local Homebrew permissions."
          fi
          die "AUTO_INSTALL_FAILED" "Automatic dependency install failed."
        fi
      else
        die "AUTO_INSTALL_UNSUPPORTED" "Automatic install only supported for macOS + Homebrew in this script."
      fi
      ;;
    *)
      die "DEPENDENCY_MISSING" "User declined automatic install."
      ;;
  esac
}

retryable_error() {
  local body="$1"
  local lc
  lc="$(printf "%s" "$body" | tr '[:upper:]' '[:lower:]')"
  [[ "$lc" == *"out of host capacity"* ]] && return 0
  [[ "$lc" == *"capacity"* ]] && return 0
  [[ "$lc" == *"temporarily unavailable"* ]] && return 0
  [[ "$lc" == *"too many requests"* ]] && return 0
  [[ "$lc" == *"service unavailable"* ]] && return 0
  [[ "$lc" == *"timeout"* ]] && return 0
  [[ "$lc" == *"internal error"* ]] && return 0
  return 1
}

parse_args() {
  local interval_override=""
  local jitter_override=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --setup)
        MODE="setup"
        shift
        ;;
      --config)
        CONFIG_FILE="${2:-}"
        shift 2
        ;;
      --interval)
        interval_override="${2:-}"
        shift 2
        ;;
      --jitter)
        jitter_override="${2:-}"
        shift 2
        ;;
      --log-file)
        LOG_FILE="${2:-}"
        shift 2
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage
        die "ARG_PARSE" "Unknown argument: $1"
        ;;
    esac
  done

  if [[ "$MODE" == "run" ]]; then
    [[ -n "$CONFIG_FILE" ]] || die "ARG_PARSE" "--config is required in run mode."
    [[ -f "$CONFIG_FILE" ]] || die "ARG_PARSE" "Config file not found: $CONFIG_FILE"
  fi

  if [[ -n "$interval_override" ]]; then
    export OVERRIDE_INTERVAL="$interval_override"
  fi
  if [[ -n "$jitter_override" ]]; then
    export OVERRIDE_JITTER="$jitter_override"
  fi
}

cfg() {
  local query="$1"
  yq -r "$query" "$CONFIG_FILE"
}

oci_cmd() {
  oci --profile "$OCI_PROFILE" --region "$OCI_REGION" "$@"
}

json_get() {
  local query="$1"
  jq -r "$query"
}

load_config() {
  OCI_PROFILE="$(cfg '.oci.profile // "DEFAULT"')"
  OCI_REGION="$(cfg '.oci.region')"
  COMPARTMENT_OCID="$(cfg '.oci.compartment_ocid')"

  SHAPE="$(cfg '.instance.shape // "VM.Standard.A1.Flex"')"
  OCPUS="$(cfg '.instance.ocpus // 4')"
  MEMORY_GB="$(cfg '.instance.memory_gb // 24')"
  BOOT_VOLUME_GB="$(cfg '.instance.boot_volume_gb // 160')"
  DISPLAY_PREFIX="$(cfg '.instance.display_name_prefix // "A1-Flex"')"
  ASSIGN_PUBLIC_IP="$(cfg '.instance.assign_public_ip // true')"
  IMAGE_MODE="$(cfg '.instance.image.mode // "auto_latest_ubuntu_22_04"')"
  IMAGE_OCID="$(cfg '.instance.image.image_ocid // ""')"
  SSH_KEY_PATH="$(cfg '.instance.ssh_public_key_path // "./keys/ampere_a1_key.pub"')"
  SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"

  RETRY_INTERVAL="$(cfg '.retry.interval_seconds // 45')"
  RETRY_JITTER="$(cfg '.retry.jitter_seconds // 15')"
  RETRY_INFINITE="$(cfg '.retry.infinite // true')"

  MANAGED_TAG_KEY="$(cfg '.management.managed_by_tag_key // "ManagedBy"')"
  MANAGED_TAG_VALUE="$(cfg '.management.managed_by_tag_value // "A1RetryScript"')"
  ENFORCE_SINGLE_ACTIVE="$(cfg '.management.enforce_single_active_instance // true')"

  NETWORK_MODE="$(cfg '.network.mode // "create_if_missing"')"
  VCN_NAME="$(cfg '.network.vcn.display_name // "ampere-vcn"')"
  VCN_CIDR="$(cfg '.network.vcn.cidr_block // "10.10.0.0/16"')"
  SUBNET_NAME="$(cfg '.network.subnet.display_name // "ampere-subnet"')"
  SUBNET_CIDR="$(cfg '.network.subnet.cidr_block // "10.10.1.0/24"')"
  PROHIBIT_PUBLIC_IP_ON_VNIC="$(cfg '.network.subnet.prohibit_public_ip_on_vnic // false')"
  IGW_NAME="$(cfg '.network.internet_gateway_display_name // "ampere-igw"')"
  RT_NAME="$(cfg '.network.route_table_display_name // "ampere-rt"')"
  SL_NAME="$(cfg '.network.security_list_display_name // "ampere-sl"')"

  if [[ -n "${OVERRIDE_INTERVAL:-}" ]]; then
    RETRY_INTERVAL="$OVERRIDE_INTERVAL"
  fi
  if [[ -n "${OVERRIDE_JITTER:-}" ]]; then
    RETRY_JITTER="$OVERRIDE_JITTER"
  fi

  [[ -n "$OCI_REGION" ]] || die "CONFIG" ".oci.region is required."
  [[ -n "$COMPARTMENT_OCID" && "$COMPARTMENT_OCID" != "null" ]] || die "CONFIG" ".oci.compartment_ocid is required."
  [[ "$SHAPE" == "VM.Standard.A1.Flex" ]] || die "CONFIG" "This script supports shape VM.Standard.A1.Flex only."
}

check_dependencies() {
  local missing=()
  for cmd in oci jq yq ssh-keygen; do
    if ! require_cmd "$cmd"; then
      missing+=("$cmd")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    maybe_install_deps "${missing[@]}"
  fi
}

ensure_ssh_key() {
  local pub_path="$SSH_KEY_PATH"
  local priv_path
  if [[ "$pub_path" == *.pub ]]; then
    priv_path="${pub_path%.pub}"
  else
    priv_path="$pub_path"
    pub_path="${pub_path}.pub"
    SSH_KEY_PATH="$pub_path"
  fi

  if [[ -f "$pub_path" ]]; then
    log "INFO" "SSH_KEY_REUSE" "Using existing SSH public key at $pub_path"
    return
  fi

  log "INFO" "SSH_KEY_CREATE" "Creating SSH key pair in workspace: $priv_path and $pub_path"
  mkdir -p "$(dirname "$priv_path")"
  ssh-keygen -t rsa -b 4096 -f "$priv_path" -N "" -C "ampere-a1-$(date +%Y%m%d)" >/dev/null \
    || die "SSH_KEY_CREATE" "Failed to generate SSH key pair."
}

run_setup_wizard() {
  log "INFO" "SETUP" "Running setup wizard."
  check_dependencies
  SSH_KEY_PATH="./keys/ampere_a1_key.pub"
  ensure_ssh_key

  if [[ ! -f "./a1-spec.yaml" ]]; then
    cat > ./a1-spec.yaml <<'EOF'
oci:
  profile: DEFAULT
  region: us-ashburn-1
  compartment_ocid: "ocid1.compartment.oc1..replace_me"

instance:
  shape: VM.Standard.A1.Flex
  ocpus: 4
  memory_gb: 24
  boot_volume_gb: 160
  display_name_prefix: "A1-Flex"
  assign_public_ip: true
  image:
    mode: auto_latest_ubuntu_22_04
    image_ocid: ""
  ssh_public_key_path: "./keys/ampere_a1_key.pub"

placement:
  strategy: cycle_ads_same_region
  availability_domains: []

network:
  mode: create_if_missing
  vcn:
    display_name: "ampere-vcn"
    cidr_block: "10.10.0.0/16"
  subnet:
    display_name: "ampere-subnet"
    cidr_block: "10.10.1.0/24"
    prohibit_public_ip_on_vnic: false
  internet_gateway_display_name: "ampere-igw"
  route_table_display_name: "ampere-rt"
  security_list_display_name: "ampere-sl"

retry:
  interval_seconds: 45
  jitter_seconds: 15
  infinite: true

management:
  enforce_single_active_instance: true
  managed_by_tag_key: "ManagedBy"
  managed_by_tag_value: "A1RetryScript"
  cleanup_mode: conservative
EOF
    log "INFO" "SETUP" "Created default ./a1-spec.yaml"
  else
    log "INFO" "SETUP" "Found existing ./a1-spec.yaml, not replacing."
  fi

  if [[ ! -f "$HOME/.oci/config" ]]; then
    log "INFO" "SETUP" "No OCI config found. Launching: oci setup config"
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      die "SETUP" "Cannot run interactive 'oci setup config' in --yes mode. Run without --yes."
    fi
    cat <<'EOF' | tee -a "$LOG_FILE"

Before continuing, quick guide for the upcoming OCI prompts:
1) "Enter a location for your config [...]"
   - Press Enter to accept the default path.
2) "Enter a user OCID"
   - Paste your user OCID from OCI Console -> Profile.
3) "Enter a tenancy OCID"
   - Paste your tenancy OCID from OCI Console -> Tenancy details.
4) "Enter a region"
   - Type: us-ashburn-1
5) API key path prompts
   - Press Enter to accept defaults unless you have a custom path.

If you see a Python SyntaxWarning line from OCI CLI, it is usually non-fatal.
Continue through the prompts unless the command exits with an actual ERROR.

EOF
    oci setup config
  else
    log "INFO" "SETUP" "Found existing OCI config at ~/.oci/config"
  fi

  if [[ -f "$HOME/.oci/config" ]]; then
    log "INFO" "SETUP" "Next: upload your OCI API public key in the Console and set compartment_ocid in a1-spec.yaml."
    log "INFO" "SETUP" "Detailed guide: README.md and docs/API_KEY_SETUP.md"
  fi

  log "INFO" "SETUP_DONE" "Setup completed."
}

check_auth() {
  log "INFO" "AUTH_CHECK" "Validating OCI credentials and region."
  if ! oci_cmd iam region list >/dev/null 2>&1; then
    die "AUTH_CHECK" "Unable to authenticate. Verify ~/.oci/config profile '$OCI_PROFILE'."
  fi
  if ! oci_cmd iam compartment get --compartment-id "$COMPARTMENT_OCID" >/dev/null 2>&1; then
    die "AUTH_CHECK" "Cannot access compartment: $COMPARTMENT_OCID"
  fi
}

find_vcn() {
  oci_cmd network vcn list \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "$VCN_NAME" \
    --all | json_get '.data[0].id // empty'
}

find_by_display_name() {
  local service="$1"
  local display_name="$2"
  shift 2
  oci_cmd network "$service" list \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "$display_name" \
    --all "$@" | json_get '.data[0].id // empty'
}

ensure_network() {
  [[ "$NETWORK_MODE" == "create_if_missing" ]] || die "CONFIG" "Only network.mode=create_if_missing is supported."

  VCN_ID="$(find_vcn || true)"
  if [[ -z "$VCN_ID" ]]; then
    log "INFO" "NET_CREATE" "Creating VCN '$VCN_NAME' ($VCN_CIDR)"
    VCN_ID="$(oci_cmd network vcn create \
      --compartment-id "$COMPARTMENT_OCID" \
      --display-name "$VCN_NAME" \
      --cidr-block "$VCN_CIDR" \
      --wait-for-state AVAILABLE \
      --defined-tags "{}" \
      --freeform-tags "{\"$MANAGED_TAG_KEY\":\"$MANAGED_TAG_VALUE\"}" | json_get '.data.id')"
  else
    log "INFO" "NET_REUSE" "Reusing VCN '$VCN_NAME' ($VCN_ID)"
  fi

  IGW_ID="$(find_by_display_name internet-gateway "$IGW_NAME" --vcn-id "$VCN_ID" || true)"
  if [[ -z "$IGW_ID" ]]; then
    log "INFO" "NET_CREATE" "Creating Internet Gateway '$IGW_NAME'"
    IGW_ID="$(oci_cmd network internet-gateway create \
      --compartment-id "$COMPARTMENT_OCID" \
      --vcn-id "$VCN_ID" \
      --display-name "$IGW_NAME" \
      --is-enabled true \
      --freeform-tags "{\"$MANAGED_TAG_KEY\":\"$MANAGED_TAG_VALUE\"}" \
      --wait-for-state AVAILABLE | json_get '.data.id')"
  else
    log "INFO" "NET_REUSE" "Reusing Internet Gateway '$IGW_NAME' ($IGW_ID)"
  fi

  RT_ID="$(find_by_display_name route-table "$RT_NAME" --vcn-id "$VCN_ID" || true)"
  if [[ -z "$RT_ID" ]]; then
    log "INFO" "NET_CREATE" "Creating Route Table '$RT_NAME'"
    RT_ID="$(oci_cmd network route-table create \
      --compartment-id "$COMPARTMENT_OCID" \
      --vcn-id "$VCN_ID" \
      --display-name "$RT_NAME" \
      --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW_ID\"}]" \
      --freeform-tags "{\"$MANAGED_TAG_KEY\":\"$MANAGED_TAG_VALUE\"}" \
      --wait-for-state AVAILABLE | json_get '.data.id')"
  else
    log "INFO" "NET_REUSE" "Reusing Route Table '$RT_NAME' ($RT_ID)"
  fi

  SL_ID="$(find_by_display_name security-list "$SL_NAME" --vcn-id "$VCN_ID" || true)"
  if [[ -z "$SL_ID" ]]; then
    log "INFO" "NET_CREATE" "Creating Security List '$SL_NAME'"
    SL_ID="$(oci_cmd network security-list create \
      --compartment-id "$COMPARTMENT_OCID" \
      --vcn-id "$VCN_ID" \
      --display-name "$SL_NAME" \
      --egress-security-rules "[{\"destination\":\"0.0.0.0/0\",\"protocol\":\"all\"}]" \
      --ingress-security-rules "[{\"source\":\"0.0.0.0/0\",\"protocol\":\"6\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":22,\"max\":22}}}]" \
      --freeform-tags "{\"$MANAGED_TAG_KEY\":\"$MANAGED_TAG_VALUE\"}" \
      --wait-for-state AVAILABLE | json_get '.data.id')"
  else
    log "INFO" "NET_REUSE" "Reusing Security List '$SL_NAME' ($SL_ID)"
  fi

  SUBNET_ID="$(find_by_display_name subnet "$SUBNET_NAME" --vcn-id "$VCN_ID" || true)"
  if [[ -z "$SUBNET_ID" ]]; then
    log "INFO" "NET_CREATE" "Creating Subnet '$SUBNET_NAME' ($SUBNET_CIDR)"
    SUBNET_ID="$(oci_cmd network subnet create \
      --compartment-id "$COMPARTMENT_OCID" \
      --vcn-id "$VCN_ID" \
      --display-name "$SUBNET_NAME" \
      --cidr-block "$SUBNET_CIDR" \
      --route-table-id "$RT_ID" \
      --security-list-ids "[\"$SL_ID\"]" \
      --prohibit-public-ip-on-vnic "$PROHIBIT_PUBLIC_IP_ON_VNIC" \
      --freeform-tags "{\"$MANAGED_TAG_KEY\":\"$MANAGED_TAG_VALUE\"}" \
      --wait-for-state AVAILABLE | json_get '.data.id')"
  else
    log "INFO" "NET_REUSE" "Reusing Subnet '$SUBNET_NAME' ($SUBNET_ID)"
  fi

  log "INFO" "NETWORK_READY" "VCN=$VCN_ID Subnet=$SUBNET_ID IGW=$IGW_ID RT=$RT_ID SL=$SL_ID"
}

resolve_ads() {
  local configured_json
  configured_json="$(yq -o=json '.placement.availability_domains // []' "$CONFIG_FILE")"
  if [[ "$(echo "$configured_json" | jq 'length')" -gt 0 ]]; then
    mapfile -t ADS < <(echo "$configured_json" | jq -r '.[]')
  else
    mapfile -t ADS < <(oci_cmd iam availability-domain list --compartment-id "$COMPARTMENT_OCID" | jq -r '.data[].name')
  fi
  [[ "${#ADS[@]}" -gt 0 ]] || die "PLACEMENT" "No availability domains found."
}

resolve_image_ocid() {
  if [[ "$IMAGE_MODE" == "explicit_ocid" ]]; then
    [[ -n "$IMAGE_OCID" && "$IMAGE_OCID" != "null" ]] || die "CONFIG" "image_ocid required when image.mode=explicit_ocid"
    RESOLVED_IMAGE_OCID="$IMAGE_OCID"
    return
  fi

  log "INFO" "IMAGE_RESOLVE" "Resolving latest Canonical Ubuntu 22.04 image for A1 in $OCI_REGION"
  RESOLVED_IMAGE_OCID="$(oci_cmd compute image list \
    --compartment-id "$COMPARTMENT_OCID" \
    --shape "$SHAPE" \
    --operating-system "Canonical Ubuntu" \
    --operating-system-version "22.04" \
    --all | jq -r '.data | sort_by(."time-created") | reverse | .[0].id // empty')"

  [[ -n "$RESOLVED_IMAGE_OCID" ]] || die "IMAGE_RESOLVE" "No matching Ubuntu 22.04 image found for shape $SHAPE."
}

count_active_managed_instances() {
  oci_cmd compute instance list \
    --compartment-id "$COMPARTMENT_OCID" \
    --all | jq -r --arg k "$MANAGED_TAG_KEY" --arg v "$MANAGED_TAG_VALUE" --arg shape "$SHAPE" '
      [.data[]
      | select(."shape" == $shape)
      | select(."freeform-tags"[$k] == $v)
      | select(."lifecycle-state" == "PROVISIONING" or ."lifecycle-state" == "STARTING" or ."lifecycle-state" == "RUNNING")
      ] | length'
}

next_display_name() {
  local max_id
  max_id="$(oci_cmd compute instance list \
    --compartment-id "$COMPARTMENT_OCID" \
    --all | jq -r --arg p "$DISPLAY_PREFIX" '
      [.data[]."display-name"
      | select(startswith($p + "-"))
      | sub("^" + $p + "-"; "")
      | tonumber?] | max // 0')"
  echo "${DISPLAY_PREFIX}-$((max_id + 1))"
}

launch_once() {
  local ad="$1"
  local display_name="$2"
  local launch_err_file="$TMP_DIR/launch_err.json"
  local launch_out_file="$TMP_DIR/launch_out.json"
  local ssh_key
  ssh_key="$(cat "$SSH_KEY_PATH")"

  set +e
  oci_cmd compute instance launch \
    --availability-domain "$ad" \
    --compartment-id "$COMPARTMENT_OCID" \
    --shape "$SHAPE" \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
    --subnet-id "$SUBNET_ID" \
    --assign-public-ip "$ASSIGN_PUBLIC_IP" \
    --display-name "$display_name" \
    --image-id "$RESOLVED_IMAGE_OCID" \
    --metadata "{\"ssh_authorized_keys\":\"$ssh_key\"}" \
    --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
    --freeform-tags "{\"$MANAGED_TAG_KEY\":\"$MANAGED_TAG_VALUE\"}" \
    >"$launch_out_file" 2>"$launch_err_file"
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    local instance_id
    instance_id="$(jq -r '.data.id' "$launch_out_file")"
    log "INFO" "LAUNCH_SUCCESS" "Instance created: $display_name ($instance_id) in $ad"
    return 0
  fi

  local err_body
  err_body="$(cat "$launch_err_file")"
  if retryable_error "$err_body"; then
    log "WARN" "LAUNCH_RETRYABLE" "Capacity/transient failure in $ad for $display_name. Will retry."
    return 10
  fi

  log "ERROR" "LAUNCH_FATAL" "Non-retriable launch failure: $err_body"
  return 11
}

print_success_instance_info() {
  local instance_json
  instance_json="$(oci_cmd compute instance list --compartment-id "$COMPARTMENT_OCID" --all | jq -r --arg k "$MANAGED_TAG_KEY" --arg v "$MANAGED_TAG_VALUE" --arg shape "$SHAPE" '
      [.data[]
      | select(."shape" == $shape)
      | select(."freeform-tags"[$k] == $v)
      | select(."lifecycle-state" == "PROVISIONING" or ."lifecycle-state" == "STARTING" or ."lifecycle-state" == "RUNNING")
      ][0]')"

  local instance_id lifecycle_name display_name
  instance_id="$(echo "$instance_json" | jq -r '.id // empty')"
  display_name="$(echo "$instance_json" | jq -r '."display-name" // empty')"
  lifecycle_name="$(echo "$instance_json" | jq -r '."lifecycle-state" // empty')"

  if [[ -z "$instance_id" ]]; then
    return
  fi

  local private_ip public_ip
  private_ip=""
  public_ip=""
  mapfile -t _VNIC_IDS < <(oci_cmd compute instance list-vnics --instance-id "$instance_id" | jq -r '.data[].id')
  if [[ "${#_VNIC_IDS[@]}" -gt 0 ]]; then
    local vnic
    vnic="$(oci_cmd network vnic get --vnic-id "${_VNIC_IDS[0]}")"
    private_ip="$(echo "$vnic" | jq -r '.data."private-ip" // empty')"
    public_ip="$(echo "$vnic" | jq -r '.data."public-ip" // empty')"
  fi

  log "INFO" "SUCCESS" "Managed instance active. display_name=$display_name state=$lifecycle_name id=$instance_id private_ip=${private_ip:-n/a} public_ip=${public_ip:-n/a}"
}

retry_loop() {
  local ad_index=0
  local attempts=0

  while true; do
    if [[ "$ENFORCE_SINGLE_ACTIVE" == "true" ]]; then
      local active
      active="$(count_active_managed_instances)"
      if [[ "$active" -ge 1 ]]; then
        log "INFO" "ALREADY_ACTIVE" "Found $active active managed instance(s); exiting successfully."
        print_success_instance_info
        return 0
      fi
    fi

    local ad="${ADS[$ad_index]}"
    local display_name
    display_name="$(next_display_name)"
    attempts=$((attempts + 1))
    log "INFO" "LAUNCH_ATTEMPT" "Attempt=$attempts AD=$ad Name=$display_name Shape=$SHAPE OCPU=$OCPUS RAM_GB=$MEMORY_GB BootGB=$BOOT_VOLUME_GB"

    set +e
    launch_once "$ad" "$display_name"
    local launch_rc=$?
    set -e

    if [[ $launch_rc -eq 0 ]]; then
      print_success_instance_info
      return 0
    fi
    if [[ $launch_rc -eq 11 ]]; then
      return 1
    fi

    ad_index=$(((ad_index + 1) % ${#ADS[@]}))
    local jitter=0
    if [[ "$RETRY_JITTER" -gt 0 ]]; then
      jitter=$((RANDOM % (RETRY_JITTER + 1)))
    fi
    local sleep_for=$((RETRY_INTERVAL + jitter))
    log "INFO" "RETRY_SLEEP" "Sleeping ${sleep_for}s before next attempt."
    sleep "$sleep_for"
  done
}

main() {
  trap cleanup EXIT
  trap on_interrupt INT TERM
  TMP_DIR="$(mktemp -d)"

  parse_args "$@"
  : >"$LOG_FILE"

  log "INFO" "START" "Starting $SCRIPT_NAME with config=$CONFIG_FILE"

  if [[ "$MODE" == "setup" ]]; then
    run_setup_wizard
    return 0
  fi

  check_dependencies
  load_config
  ensure_ssh_key
  check_auth
  ensure_network
  resolve_ads
  resolve_image_ocid

  log "INFO" "PLACEMENT" "Using AD cycle: ${ADS[*]}"
  log "INFO" "IMAGE" "Using image OCID: $RESOLVED_IMAGE_OCID"

  retry_loop
}

main "$@"
