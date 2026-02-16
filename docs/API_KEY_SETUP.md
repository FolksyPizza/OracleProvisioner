# OCI API Key Setup (Beginner Guide)

This guide prepares authentication for `run.sh`.

## 1. Create local OCI CLI config

From the repository root, run:

```bash
oci setup config
```

The CLI prompts for:
- User OCID
- Tenancy OCID
- Region (use `us-ashburn-1` for your case)
- API key file path

Prompt-by-prompt answers:
- `Enter a location for your config [...]` -> `./keys/oci/config`
- `Enter a user OCID` -> paste user OCID from OCI Console profile
- `Enter a tenancy OCID` -> paste tenancy OCID from OCI Console tenancy page
- `Enter a region` -> your OCI region (example: `us-ashburn-1`)
- `Enter the full path to the private key` -> `./keys/oci/oci_api_key.pem`
- passphrase prompt -> press Enter for no passphrase (simplest for automation)

If a Python `SyntaxWarning` appears, it is commonly non-fatal; continue unless the command exits with an explicit error.

It creates:
- `./keys/oci/config`
- API signing key pair (private key + public key)

## 2. Upload API public key in OCI Console

1. Sign in to OCI Console.
2. Open your user profile.
3. Go to API Keys.
4. Click Add API Key.
5. Choose Upload public key file.
6. Upload the `.pem.pub` file generated during `oci setup config`.
7. Save and confirm fingerprint matches your `./keys/oci/config`.

## 3. Verify local config file

Open `./keys/oci/config` and confirm your profile (usually `DEFAULT`) contains:
- `user=ocid1.user...`
- `fingerprint=..:..:..`
- `tenancy=ocid1.tenancy...`
- `region=us-ashburn-1`
- `key_file=/path/to/private_api_key.pem`

## 4. Test auth before provisioning

```bash
OCI_CLI_CONFIG_FILE=./keys/oci/config oci --profile <profile-name> iam region list
```

If this returns JSON, auth is working.

## 5. Configure script spec

Edit `a1-spec.yaml`:
- `oci.profile` must match your profile name in `./keys/oci/config`.
- `oci.config_file` should be `./keys/oci/config` (default).
- `oci.compartment_ocid` must be your target compartment OCID.
- `oci.region` must match your intended OCI region.

## Common problems

1. `NotAuthenticated`
- Public key not uploaded, wrong fingerprint, or wrong private key path.

2. `NotAuthorizedOrNotFound`
- Wrong compartment OCID or missing IAM policy permissions.

3. Region mismatch
- Profile region differs from your intended region. Update `a1-spec.yaml` and/or `./keys/oci/config`.

## Git SSH key vs OCI API key

These are different key types and use cases:
- GitHub SSH key: for `git clone`, `git pull`, `git push`
- OCI API signing key: for `oci` CLI and SDK authentication

If Git clone works but OCI auth fails, that is normal when OCI API keys are not configured/uploaded yet.

Best fix:
1. Run `oci setup config`
2. Upload the generated OCI public key to OCI Console -> User -> API Keys
3. Re-test with:
   - `OCI_CLI_CONFIG_FILE=./keys/oci/config oci --profile <profile-name> iam region list`
