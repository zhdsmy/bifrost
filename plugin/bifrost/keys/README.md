# Bifrost Core Signing Public Keys

This directory holds the ECDSA P-256 public keys used by the router to verify
`core.json.sig` before downloading or installing a core update (PLAN 12.3).

## Naming and Format

- Public key files must match `*.pub.pem` (for example `release-1.pub.pem`).
- Format: PEM-encoded ECDSA P-256 (`prime256v1`) SubjectPublicKeyInfo public
  key, verifiable by OpenSSL 1.1.1w (`openssl dgst -sha256 -verify`).
- Verification succeeds when **any** `*.pub.pem` file in this directory verifies
  the signature.
- Never commit private keys (`*.key.pem`) or temporary test keys here.

## Generating the Production Key Pair (Project Owner)

Run on an offline or trusted machine:

```sh
umask 077
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 \
    -out bifrost-signing.key.pem
openssl pkey -in bifrost-signing.key.pem -pubout \
    -out plugin/bifrost/keys/release-1.pub.pem
```

Then:

1. Store the full contents of `bifrost-signing.key.pem` in the GitHub Actions
   repository secret `BIFROST_SIGNING_KEY` (used by `.github/workflows/core.yml`
   and `.github/workflows/release.yml`).
2. Keep an offline encrypted backup of `bifrost-signing.key.pem` and remove the
   plaintext copy from the working tree.
3. Commit `plugin/bifrost/keys/release-1.pub.pem` to the repository.

## Key Rotation (PLAN 12.3)

1. Generate a new key pair and commit its public key alongside the existing key
   (for example `release-2.pub.pem`).
2. Ship a plugin release containing both public keys so existing routers learn
   the new key.
3. After users have had time to upgrade, replace the `BIFROST_SIGNING_KEY`
   secret in GitHub Actions with the new private key.
4. Remove the retired `*.pub.pem` file in a later plugin release (or immediately
   in an emergency plugin release if the old private key is compromised).
