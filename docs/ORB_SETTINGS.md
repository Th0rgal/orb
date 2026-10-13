# Orb settings

Orb iOS opens Settings from the profile icon, with Backend, Providers and Machines.
The backend connection and credential owner determine available provider actions.
Cloud accounts retain their existing provider-dashboard links; opening a website
on the phone does not authenticate a browser profile running on Core.

Machines lists Core and the registered remote nodes (`/api/remote-nodes`) and
lets you pause or resume new jobs on a node. Machines that take work are
`sandboxed-node` nodes enrolled with Core; Orb does not keep a separate list of
SSH addresses.
