# A1 Hunter

Provision Oracle Cloud `VM.Standard.A1.Flex` instances with automatic retry logic for limited-capacity scenarios.

`run-a1.sh` continuously attempts provisioning until capacity is available, while reusing network resources and stopping after one managed active instance is found.

## Documentation

- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [CLI Usage](#cli-usage)
- [API Key Setup Guide](docs/API_KEY_SETUP.md)
- [Operations and Troubleshooting](docs/OPERATIONS.md)

## Features

- Single entrypoint script: `run-a1.sh`
- Setup mode for first-time environments: `--setup`
- Retry loop with configurable interval and jitter
- Availability Domain cycling in-region
- Automatic network creation/reuse (VCN, subnet, IGW, route table, security list)
- Automatic SSH key creation/reuse in `./keys/`
- Stops when one managed A1 instance is active
- Console and file logging

## Repository Layout

- [`run-a1.sh`](run-a1.sh): main script
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

## Quick Start

1. Make script executable:

```bash
chmod +x run-a1.sh
```

2. Run setup:

```bash
./run-a1.sh --setup
```

When `oci setup config` starts, use this:
- `Enter a location for your config [...]` -> press Enter
- `Enter a user OCID` -> paste from OCI Console profile
- `Enter a tenancy OCID` -> paste from Tenancy details
- `Enter a region` -> `us-ashburn-1`
- API key path prompts -> press Enter for defaults

If you see a Python `SyntaxWarning`, continue unless an actual `ERROR` follows.

3. Edit `a1-spec.yaml` and set:

```yaml
oci:
  compartment_ocid: "ocid1.compartment.oc1..REPLACE_ME"
```

4. Start provisioning:

```bash
./run-a1.sh --config a1-spec.yaml
```

## Configuration

Default target in `a1-spec.yaml`:
- Shape: `VM.Standard.A1.Flex`
- OCPUs: `4`
- Memory: `24 GB`
- Boot volume: `160 GB`
- Region: `us-ashburn-1`

SSH keys are stored at:
- `./keys/ampere_a1_key`
- `./keys/ampere_a1_key.pub`

## CLI Usage

```bash
./run-a1.sh --setup [--yes]
./run-a1.sh --config a1-spec.yaml [--interval 45] [--jitter 15] [--log-file ./a1-provision.log] [--yes]
```

Examples:

```bash
./run-a1.sh --config a1-spec.yaml --interval 60 --jitter 10
./run-a1.sh --config a1-spec.yaml --log-file ./a1-provision.log
```

## Setup and Auth

For full OCI API key onboarding and profile configuration:
- [`docs/API_KEY_SETUP.md`](docs/API_KEY_SETUP.md)

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
