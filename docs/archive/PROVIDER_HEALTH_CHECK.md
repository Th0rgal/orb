# Provider Health Check

This feature adds a health check endpoint for AI providers to validate credentials and test connectivity before using them in missions.

## Endpoint

```
POST /api/ai/providers/:id/health
```

## Usage

Test a provider's health status:

```bash
curl -X POST https://YOUR-BACKEND/api/ai/providers/cerebras/health
```

## Response Format

### Healthy Provider
```json
{
  "healthy": true,
  "status": "connected",
  "message": "Provider API key is valid and working"
}
```

### Invalid Credentials
```json
{
  "healthy": false,
  "status": "api_error",
  "message": "API returned status 401: Invalid API key",
  "status_code": 401
}
```

### No Credentials
```json
{
  "healthy": false,
  "status": "no_credentials",
  "message": "Provider has no API key or OAuth credentials configured"
}
```

### Connection Error
```json
{
  "healthy": false,
  "status": "connection_error",
  "message": "Failed to connect to provider API: connection timeout"
}
```

## Supported Providers

The health check performs actual API validation for:
- **Cerebras** - Tests with `llama-3.1-8b` model
- **Z.AI** - Tests with `glm-4.7-flash` model
- **DeepInfra** - Tests with `Meta-Llama-3.1-8B-Instruct` model

For OAuth-based providers (Anthropic, OpenAI, Google), it verifies credentials exist without making test API calls.

## Examples

### Test Cerebras Provider
```bash
# Configure provider
curl -X POST https://YOUR-BACKEND/api/ai/providers \
  -H "Content-Type: application/json" \
  -d '{
    "provider_type": "cerebras",
    "name": "Cerebras",
    "api_key": "csk-...",
    "enabled": true,
    "use_for_backends": ["opencode"]
  }'

# Test health
curl -X POST https://YOUR-BACKEND/api/ai/providers/cerebras/health
```

### Test Z.AI Provider
```bash
# Configure provider
curl -X POST https://YOUR-BACKEND/api/ai/providers \
  -H "Content-Type: application/json" \
  -d '{
    "provider_type": "zai",
    "name": "Z.AI",
    "api_key": "YOUR_KEY",
    "enabled": true,
    "use_for_backends": ["opencode"]
  }'

# Test health
curl -X POST https://YOUR-BACKEND/api/ai/providers/zai/health
```

## Integration with Dashboard

The dashboard can use this endpoint to:
1. **Validate on Save** - Test credentials immediately when adding a provider
2. **Show Status** - Display health status in provider list
3. **Troubleshooting** - Help users diagnose authentication issues

Example dashboard integration:
```typescript
async function addProvider(config: ProviderConfig) {
  // Create provider
  const provider = await api.post('/api/ai/providers', config);

  // Immediately test health
  const health = await api.post(`/api/ai/providers/${provider.id}/health`);

  if (!health.healthy) {
    throw new Error(`Provider validation failed: ${health.message}`);
  }

  return provider;
}
```

## Benefits

1. **Early Error Detection** - Catch invalid API keys before missions fail
2. **Better UX** - Immediate feedback when configuring providers
3. **Troubleshooting** - Clear error messages help users fix issues
4. **Reliability** - Verify connectivity to provider APIs

## Error Codes

| Status | Description |
|--------|-------------|
| `connected` | Provider is healthy and working |
| `configured` | Provider has credentials (OAuth not tested) |
| `no_credentials` | No API key or OAuth token configured |
| `api_error` | API call failed (invalid key, rate limit, etc.) |
| `connection_error` | Network error connecting to provider |

## Status Codes

- **200 OK** - Health check completed (see `healthy` field for result)
- **404 Not Found** - Provider not configured
- **500 Internal Server Error** - Health check system error
