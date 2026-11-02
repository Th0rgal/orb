# Legacy dashboard confirmation lifecycle

The Next.js dashboard's ConfirmDialog uses one effective busy state: an external
busy flag or a pending promise returned by onConfirm. While either is active,
Confirm, Cancel, the close button, Escape, and backdrop dismissal are disabled.
Once the promise settles, cancellation becomes available again unless external
busy remains true. Callers own error reporting and whether successful confirmation
closes the dialog. This contract applies to dashboard/src; Orb and native clients
use their own dialog primitives.

Regression sequence: confirm with a deferred promise, attempt each dismissal,
verify no cancellation or repeated confirmation, settle the promise, then verify
cancellation works again. Explicit external busy remains authoritative.
