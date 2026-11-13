# Dev rental spending

Dev has a $5 (500 cents) default daily ceiling on managed VM rental commitments,
across all its users, projects and providers. `ORB_DEV_DAILY_CAP_CENTS` in the
shared base env can lower or raise that operator-owned ceiling; it applies only
to dev. Zero or an invalid value stops new dev spending. Changing this env is
an operator action and requires only the next intentional dev deployment.

The effective limit is the smaller of this ceiling and the ordinary fleet
budget. Settings imports and REST settings cannot remove the ceiling. It is
checked inside the same immediate SQLite transaction that records the prepaid
rental commitment, using today's UTC ledger across all dev users. Creates,
forks, resumes and extensions share that gate. A missing ledger denies new
spending. Each new UTC day starts a new commitment budget.

This is a cap on reserved rental estimates, not a reconciliation of provider
invoices or a model inference budget. Each full rental or extension is charged
to its reservation day, including time extending into tomorrow. Existing
machines retain their paid lease and TTL; the ceiling blocks additional
commitments. Provider billing corrections and snapshot storage can differ from
these estimates. User inference and compute caps remain independently active.

Dev VM names carry `orb-managed-dev-` at the provider, even with an unsuffixed
Core binary configured with `ORB_INSTANCE=dev`. Inventory reconciliation uses
that same prefix. Machine responses include `instance: "dev"`; compute-fleet
labels include `instance=dev`; managed usage includes `instance`,
`instance_daily_cap_cents`, the effective `daily_cap_cents`, and
`cost_basis: "rental_commitments"`. User-scoped responses keep only that user's
spending. Prod and dev retain their separate ledgers.

Self-tests use temporary databases and synthetic rental records, never a
provider or live VM. Live cap/label acceptance requires the operator’s dev
installation and a dev-only rental within its budget.
