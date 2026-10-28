# Provider quota details

Expanded account rows prioritize quota information. Each quota bar grows into
available horizontal space; a sole window uses the full row. Multiple windows
share space and wrap on narrow screens. Account ordering remains above usage.
Antigravity execution availability, managed-machine settings and the model list
follow usage in a quieter footer. Controls retain their accessible names and
normal hit targets.

Google documents both five-hour and weekly limits. Core first reads
retrieveUserQuotaSummary, then falls back to the per-model retrieveUserQuota
when Gemini is omitted. That fallback has no explicit period and Core infers
one from the reset time. Previously observed windows may be labeled last seen;
a never-observed window is omitted by Core. A missing Gemini window in the
expanded desktop view must say Not reported, without a percentage/progressbar.
Absence must not be presented as zero usage or an unlimited allowance.

The existing backend's inference and remembered-reset semantics are not proof of
current usage of both windows. A future provider integration should prefer
explicit window identifiers and observation timestamps over inference.

Desktop geometry and light/dark/narrow behavior are covered by
provider-expanded-layout.browser.spec.ts in Chromium and WebKit. This change is
specific to the desktop layout shown in the report; native mobile provider rows
are not changed. Mobile unknown-window presentation remains a parity gap.
