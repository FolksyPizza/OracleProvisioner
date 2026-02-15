# OCI API Key Setup (Beginner Guide)

This guide prepares authentication for `run-a1.sh`.

## 1. Create local OCI CLI config

Run:

```bash
oci setup config
```

The CLI prompts for:
- User OCID
- Tenancy OCID
- Region (use `us-ashburn-1` for your case)
- API key file path

It creates:
- `~/.oci/config`
- API signing key pair (private key + public key)

## 2. Upload API public key in OCI Console

1. Sign in to OCI Console.
2. Open your user profile.
3. Go to API Keys.
4. Click Add API Key.
5. Choose Upload public key file.
6. Upload the `.pem.pub` file generated during `oci setup config`.
7. Save and confirm fingerprint matches your `~/.oci/config`.

## 3. Verify local config file

Open `~/.oci/config` and confirm your profile (usually `DEFAULT`) contains:
- `user=ocid1.user...`
- `fingerprint=..:..:..`
- `tenancy=ocid1.tenancy...`
- `region=us-ashburn-1`
- `key_file=/path/to/private_api_key.pem`

## 4. Test auth before provisioning

```bash
oci --profile DEFAULT iam region list
```

If this returns JSON, auth is working.

## 5. Configure script spec

Edit `a1-spec.yaml`:
- `oci.profile` must match your profile name in `~/.oci/config`.
- `oci.compartment_ocid` must be your target compartment OCID.

## Common problems

1. `NotAuthenticated`
- Public key not uploaded, wrong fingerprint, or wrong private key path.

2. `NotAuthorizedOrNotFound`
- Wrong compartment OCID or missing IAM policy permissions.

3. Region mismatch
- Profile region differs from your intended region. Update `a1-spec.yaml` and/or `~/.oci/config`.
