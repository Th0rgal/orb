# Dashboard automation prompt parsing

The Next.js automation form debounces detection of prompt variables for 400 ms.
A newer prompt cancels its predecessor. Closing the dialog, changing its mission,
or unmounting cancels pending parsing so a callback cannot add stale variables
to another dialog session or update a component after teardown. Successful
creation also clears pending parsing as part of resetting the form.

Regression coverage schedules parsing, performs each lifecycle transition before
the delay expires, advances time, and verifies no stale variable is added. A
control case verifies parsing still occurs while the same dialog remains open.
