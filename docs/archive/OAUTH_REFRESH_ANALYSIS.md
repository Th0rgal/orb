# OAuth Token Refresh Analysis & Improvements

## Problem Summary

Anthropic OAuth provider shows as "expired" (orange) in the UI, and tokens are not being auto-refreshed despite having a background refresh loop.

## Root Cause Analysis

### Issue #1: Refresh Token Expiration

The core issue is that **Anthropic's refresh tokens themselves expire**. Looking at the logs:

```
invalid_grant: Refresh token not found or invalid
```

This means:
- The refresh token (not the access token) has expired
- Anthropic likely has a maximum lifetime for refresh tokens (security measure)
- Once the refresh token expires, automatic renewal is impossible
- User must re-authenticate to get a new refresh token

### Issue #2: Missing Early Warning

The current system:
1. ✅ Checks tokens every 15 minutes
2. ✅ Refreshes if expiring within 1 hour
3. ❌ **BUT** doesn't warn when refresh fails due to invalid_grant
4. ❌ Doesn't update provider status to "needs re-auth"

### Issue #3: Insufficient Debugging

Current logs don't show:
- When the refresh loop actually runs
- What providers it finds
- Token expiration timestamps
- Whether tokens are already expired when checked

## Improvements Implemented

### 1. Enhanced Debug Logging

Added comprehensive logging to track:
- Total providers vs OAuth providers checked
- Exact expiration timestamps and time remaining
- Detection of already-expired tokens
- Clear warning when refresh token is invalid

**New Log Output:**
```
OAuth refresh check cycle starting total_providers=6 oauth_providers=3
Checking OAuth token status provider=Anthropic expires_in_minutes=45 needs_refresh=true
OAuth token is ALREADY EXPIRED expired_since_minutes=120 - emergency refresh...
Refresh token is invalid - user needs to re-authenticate
```

### 2. Better Error Context

Added `is_invalid_grant` flag to immediately identify when refresh tokens have expired vs other errors.

### 3. Documentation of Expected Behavior

This is **normal and expected**:
- OAuth refresh tokens don't last forever
- Periodically, users must re-authenticate
- The system correctly detects this and removes invalid credentials

## Recommended Additional Improvements

### Priority 1: Provider Status Updates

**Problem**: Provider shows generic "error" but doesn't specifically say "needs re-authentication"

**Solution**: Add a `NeedsReauth` status type:

```rust
pub enum ProviderStatusResponse {
    Unknown,
    Connected,
    NeedsAuth { auth_url: Option<String> },
    NeedsReauth { reason: String },  // NEW
    Error { message: String },
}
```

When `invalid_grant` is detected, update provider to `NeedsReauth` status.

### Priority 2: Proactive Notifications

**Problem**: Users don't know their token expired until a mission fails

**Solution**: Send notification when refresh token expiration is detected:
- Dashboard notification
- Email alert (if configured)
- SSE event to connected clients

### Priority 3: Refresh Token Expiry Tracking

**Problem**: We don't know when the refresh token itself will expire

**Solution**: Track refresh token creation time and warn users before it expires:

```rust
pub struct OAuthCredentials {
    pub refresh_token: String,
    pub access_token: String,
    pub expires_at: i64,
    pub refresh_token_created_at: Option<i64>,  // NEW
    pub refresh_token_expires_at: Option<i64>,  // NEW
}
```

Anthropic's refresh tokens likely expire after 30-90 days. We should:
1. Track when they were issued
2. Warn at 7 days before expiry
3. Send notification to re-authenticate

### Priority 4: Automatic Re-auth Prompt

**Problem**: User must manually go to Settings → AI Providers

**Solution**: When `invalid_grant` is detected:
1. Send SSE event with re-auth prompt
2. Dashboard shows modal: "Anthropic provider needs re-authentication"
3. Click to initiate OAuth flow without navigating away

### Priority 5: Health Check Integration

**Problem**: No way to validate provider health before using

**Solution**: The provider health check endpoint (PR #116) should:
- Test OAuth token validity
- Detect expired refresh tokens early
- Return specific "needs_reauth" status

### Priority 6: Sync Check on Refresh Loop

**Problem**: Refresh loop only checks `ai_providers` store, not auth files

**Solution**: Also check OAuth tokens in OpenCode auth files:

```rust
// Check both sources
let store_token = provider.oauth;
let auth_file_token = read_opencode_auth_entry(provider.provider_type);

if auth_file_token != store_token {
    tracing::warn!("Token mismatch between store and auth file");
    // Sync them
}
```

## Implementation Priority

1. **Phase 1** (This PR) - Enhanced debugging ✅
   - Better logging
   - Clear error messages
   - Detection of already-expired tokens

2. **Phase 2** (Next PR) - Status updates
   - Add `NeedsReauth` status
   - Update provider status on `invalid_grant`
   - Show clear message in UI

3. **Phase 3** (Future) - Proactive notifications
   - SSE events for re-auth needed
   - Dashboard modal prompts
   - Email notifications

4. **Phase 4** (Future) - Refresh token tracking
   - Track refresh token lifetime
   - Warn before expiration
   - Auto-prompt for re-auth

## Testing Recommendations

1. **Test invalid_grant handling**:
   - Manually corrupt a refresh token
   - Verify error is logged correctly
   - Verify credentials are removed

2. **Test refresh loop**:
   - Set token to expire in 30 minutes
   - Verify refresh loop catches it
   - Verify new token is stored

3. **Test multi-tier sync**:
   - After refresh, check all storage locations
   - Verify OpenCode auth file is updated
   - Verify Claude CLI credentials are updated

## User Impact

### Before
- Provider shows generic orange "error"
- No clear indication what's wrong
- No guidance on how to fix

### After (This PR)
- Detailed logs help diagnose issues
- Clear "refresh token invalid" message
- Logs indicate when user needs to re-authenticate

### After (Phase 2)
- Provider shows "Needs Re-authentication"
- Click to re-authenticate button
- Clear UX for fixing the issue

## Conclusion

The OAuth refresh system is working as designed. The issue is that:

1. **Refresh tokens expire** - This is normal OAuth behavior
2. **Users must re-authenticate** - This is expected periodically
3. **UX needs improvement** - Better status messages and prompts

This PR adds debugging to understand the refresh cycle better. Future PRs should focus on UX improvements to make re-authentication clearer and easier.
