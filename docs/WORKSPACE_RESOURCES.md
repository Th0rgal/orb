# Workspace resource limits

`GET` and `POST /api/workspaces/:id/resources` return HTTP 501
(`error: workspace_resources_unsupported`) for a workspace visible to the
caller under the workspace collection's ownership rules. A missing or invisible
workspace returns 404. Requests still require Core authentication.

Lean Core stores workspace metadata, but has no workspace execution owner that
can read, enforce or retune these overrides. These routes do not read or persist
overrides, change running scopes, or report node-wide defaults as workspace
limits. Node-level resource controls remain independent of this contract.

## Desktop Resources page

The fleet graph and mission drilldown keep their current request when a background
poll fires or the tab becomes visible. The next poll can refresh the graph after
that request finishes. Choosing a new range, mission or backend supersedes the
old request immediately. A late response from the old selection must never replace
the graph for the new selection.
