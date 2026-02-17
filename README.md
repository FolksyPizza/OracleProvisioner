# A1 Hunter

Provision Oracle Cloud `VM.Standard.A1.Flex` instances with automatic retry logic for limited-capacity scenarios.

`run.sh` continuously attempts provisioning until capacity is available, while reusing network resources and stopping after one managed active instance is found.

## Documentation

- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [CLI Usage](#cli-usage)
- [API Key Setup Guide](docs/API_KEY_SETUP.md)
- [Operations and Troubleshooting](docs/OPERATIONS.md)

## Features

- Single entrypoint script: `run.sh`
- Setup mode for first-time environments: `--setup`
- Retry loop with configurable interval and jitter
- Availability Domain cycling in-region
- Automatic network creation/reuse (VCN, subnet, IGW, route table, security list)
- Automatic SSH key creation/reuse in `./keys/`
- Stops when one managed A1 instance is active
- Console and file logging

## Repository Layout

- [`run.sh`](run.sh): main script
- [`a1-spec.yaml`](a1-spec.yaml): configuration file
- [`docs/API_KEY_SETUP.md`](docs/API_KEY_SETUP.md): OCI API key setup guide
- [`docs/OPERATIONS.md`](docs/OPERATIONS.md): operations, troubleshooting, and cleanup

## Requirements

- macOS or Linux
- `oci` CLI
- `jq`
- `yq` (mikefarah/yq)
- `ssh-keygen`
- OCI account with permissions for compute and networking in target compartment

## Dependency Installation

`./run.sh --setup` checks dependencies and can auto-install missing packages when you approve the prompt.

Supported auto-install paths:
- macOS: Homebrew
- Linux: `apt`, `dnf`, `yum`, `pacman`, `zypper`, `apk`

On Linux, the script attempts to install:
- `jq`
- `yq`
- `oci` CLI
- helper packages such as `python3`, `curl`, CA certs, and SSH client tools

If package-manager installs do not provide `yq` or `oci`, the script falls back to:
- direct `yq` binary install
- official OCI CLI install script

## Quick Start

1. From the repository root, make the script executable:

```bash
chmod +x run.sh
```

2. Run setup:

```bash
./run.sh --setup
```

When `oci setup config` starts, use:
- `Enter a location for your config [...]` -> `./keys/oci/config`
- `Enter a user OCID` -> paste your user OCID
- `Enter a tenancy OCID` -> paste your tenancy OCID
- `Enter a region` -> your OCI region (example: `us-ashburn-1`)
- `Enter the full path to the private key` -> `./keys/oci/oci_api_key.pem`
- passphrase prompt -> press Enter (blank) for automation

If you see a Python `SyntaxWarning`, continue unless an actual `ERROR` follows.

3. Edit `a1-spec.yaml`:

```yaml
oci:
  config_file: "./keys/oci/config"
  profile: "DEFAULT"
  region: "<your-region>"
  compartment_ocid: "<your-compartment-ocid>"
```

4. Upload OCI API public key:
- OCI Console -> User/Profile -> API Keys -> Add API Key
- Upload the public key created during setup (`.pub` / `_public.pem`)

5. Verify auth:

```bash
OCI_CLI_CONFIG_FILE=./keys/oci/config oci --profile <profile-name> iam region list
```

6. Start provisioning:

```bash
./run.sh --config a1-spec.yaml
```

## Key File Permissions

Run these from the repository root:

```bash
chmod 700 keys keys/oci
chmod 600 keys/ampere_a1_key keys/oci/oci_api_key.pem
chmod 644 keys/ampere_a1_key.pub keys/oci/oci_api_key_public.pem
```

Expected state:
- private keys (`*.pem`, no `.pub`) -> `600`
- public keys (`*.pub`, `*_public.pem`) -> `644`
- key directories -> `700`

## Configuration

Default target in `a1-spec.yaml`:
- Shape: `VM.Standard.A1.Flex`
- OCPUs: `4`
- Memory: `24 GB`
- Boot volume: `160 GB`
- Region: `us-ashburn-1`

Update these values for your environment before running:
- `oci.region`
- `oci.compartment_ocid`
- `oci.profile` (if not `DEFAULT`)

SSH keys are stored at:
- `./keys/ampere_a1_key`
- `./keys/ampere_a1_key.pub`

## CLI Usage

```bash
./run.sh --setup [--yes]
./run.sh --config a1-spec.yaml [--interval 45] [--jitter 15] [--peak-hours 0-3] [--peak-interval 20] [--peak-jitter 5] [--log-file ./a1-provision.log] [--yes]
```

Examples:

```bash
# Default retry timing from YAML (usually 45-60s between attempts):
./run.sh --config a1-spec.yaml

# Faster retry loop (20-25s between attempts):
./run.sh --config a1-spec.yaml --interval 20 --jitter 5

# Faster retries during local midnight window, normal retries otherwise:
./run.sh --config a1-spec.yaml --interval 45 --jitter 15 --peak-hours 0-3 --peak-interval 20 --peak-jitter 5

# Slower retry loop (60-70s between attempts):
./run.sh --config a1-spec.yaml --interval 60 --jitter 10

# Custom log file:
./run.sh --config a1-spec.yaml --log-file ./a1-provision.log
```

### Retry Flags Explained

- `--interval <sec>`: base delay before the next provisioning attempt
- `--jitter <sec>`: random extra delay added to each retry, from `0..jitter`
- `--peak-hours <start-end>`: local-hour window (0-23) for alternate retry timing
- `--peak-interval <sec>`: base delay during the peak window
- `--peak-jitter <sec>`: random extra delay during the peak window

Effective wait time is:
- `interval + random(0..jitter)`

Example:
- `--interval 20 --jitter 5` means each retry waits **20 to 25 seconds**.
- `--interval 45 --jitter 15 --peak-hours 0-3 --peak-interval 20 --peak-jitter 5`
  means retries run at **20-25s** from 00:00-03:59 local time and **45-60s** outside that window.

### Recommended Retry Profiles

- Balanced (recommended): `--interval 20 --jitter 5`
- Conservative: `--interval 45 --jitter 15` (default)
- Aggressive: `--interval 10 --jitter 3` (higher API request rate)
- Peak-ramp: `--interval 45 --jitter 15 --peak-hours 0-3 --peak-interval 20 --peak-jitter 5`

Notes:
- Very low intervals can increase `429` / transient API errors.
- `20/5` is usually a safe balance. Going below `10/3` for long runs is not recommended.
- Retryable failures are handled automatically; the script keeps trying until success.
- For long-running stability, start with Balanced and only go more aggressive if needed.

## Setup and Auth

For full OCI API key onboarding and profile configuration:
- [`docs/API_KEY_SETUP.md`](docs/API_KEY_SETUP.md)

Important:
- A Git SSH key (used for cloning/pushing GitHub repos) is not the same as an OCI API signing key.
- This project uses OCI API signing keys configured in `./keys/oci/config` by default.

## Logging

- Default log file: `./a1-provision.log`
- Key events include:
  - `AUTH_CHECK`
  - `NET_CREATE` / `NET_REUSE`
  - `LAUNCH_ATTEMPT`
  - `LAUNCH_RETRYABLE`
  - `LAUNCH_SUCCESS`
  - `ALREADY_ACTIVE`

## Notes

- Managed resources are tagged with `ManagedBy=A1RetryScript` by default.
- In setup mode, `--yes` disables prompts but cannot complete interactive `oci setup config`.
