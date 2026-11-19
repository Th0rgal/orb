# Workspace resource limits

`GET` and `POST /api/workspaces/:id/resources` return HTTP 501
(`error: workspace_resources_unsupported`) for a workspace visible to the
caller under the workspace collection's ownership rules. A missing or invisible
workspace returns 404. Requests still require Core authentication.

Lean Core stores workspace metadata, but has no workspace execution owner that
can read, enforce or retune these overrides. These routes do not read or persist
overrides, change running scopes, or report node-wide defaults as workspace
limits. Node-level resource controls remain independent of this contract.
