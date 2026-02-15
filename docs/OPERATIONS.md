# Operations Guide

## What the script creates

When missing, it creates and then reuses:
- VCN (`ampere-vcn`)
- Internet Gateway (`ampere-igw`)
- Route Table (`ampere-rt`)
- Security List (`ampere-sl`)
- Subnet (`ampere-subnet`)

Instance launches use display names like:
- `A1-Flex-1`
- `A1-Flex-2`

All managed resources are tagged with:
- `ManagedBy=A1RetryScript`

## IAM permissions

At minimum, the user/group running OCI CLI needs policy access in target compartment for:
- `inspect` / `read` / `use` / `manage virtual-network-family`
- `inspect` / `read` / `use` / `manage instance-family`
- permission to read images and ADs

If IAM is too restrictive, launch/network commands will fail as non-retriable.

## Common failure modes

1. Auth failure
- Check profile in `a1-spec.yaml` (`oci.profile`)
- Verify `./keys/oci/config` and matching private key path

2. Capacity unavailable
- Script treats this as retriable and keeps trying
- It cycles ADs in your configured region

3. Bad compartment or region
- Confirm `oci.compartment_ocid` and `oci.region`

4. Missing dependencies
- Install `oci`, `jq`, `yq`
- Script can prompt for Homebrew install on macOS

## Logs

- Default log file: `./a1-provision.log`
- Each line includes UTC timestamp + level + event code

Useful events:
- `AUTH_CHECK`
- `NET_CREATE` / `NET_REUSE`
- `LAUNCH_ATTEMPT`
- `LAUNCH_RETRYABLE`
- `LAUNCH_SUCCESS`
- `ALREADY_ACTIVE`

## Cleanup (manual)

If you want to remove resources later, first stop/terminate managed instances, then delete network resources in dependency order:
1. Subnet
2. Route Table rules/resources as needed
3. Internet Gateway
4. Security List (if no subnet dependency)
5. VCN

Keep the generated SSH key files if you still need SSH access:
- `./keys/ampere_a1_key`
- `./keys/ampere_a1_key.pub`
