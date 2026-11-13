# Seal configured provider keys

Run as the local Core service operator with its Bitwarden configuration:

```bash
orb-core-dev seal-provider --all --data-root /var/lib/sandboxed-sh-dev
```

Run once per instance; production sealing belongs to the operator. The command
discovers configured keys from Bitwarden metadata for every implemented
provider in the shared provider registry, including disabled providers. It
uses the same canonical entries on each instance (`BOAT_API_KEY`,
`LEANCI_API_KEY`, `COLAB_API_TOKEN`) and seals each value directly inside Core
under that instance's own master key. Batch sealing never reads a key from
an environment override and never enables a provider.

Only sealed provider names are printed. Missing entries are skipped; duplicate
entries, unavailable vaults and empty values fail closed. Authority is checked
before inventory lookup. Mission identities and managed machines cannot seal
or obtain these keys. The old single-provider command remains available.

A failure may follow successful sealing of an earlier provider. Fix the vault
configuration and rerun the command; existing sealed values remain private and
are replaced only after the replacement was successfully sealed. Never copy
sealed files between instances, print vault values, or deliver keys to a mission.
