# Dashboard GitHub device-flow lifetime

The GitHub integration card owns its frontend authorization attempt. Unmounting
cancels its status polling timer and settles the waiting polling phase. Late
responses from authorization or status requests must not open a window, show a
notification, update device-code state, or revalidate SWR after cancellation.
An already-sent HTTP request may finish; the frontend ignores its result.
The backend's device authorization remains independent of this UI lifetime.

Status polls do not overlap. Normal approval and expiry stop polling, clear the
prompt, release the waiting action, and refresh account state. Transient status
errors may be retried on the next tick while the attempt remains active.
