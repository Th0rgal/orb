// Run as an overlay in CLIProxyAPI Plus's internal/runtime/executor package.
package executor

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/router-for-me/CLIProxyAPI/v8/internal/config"
	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
)

func TestR21aExpiredKimiRenewal(t *testing.T) {
	login := &auth.Auth{ID: "fixture", Provider: "kimi", Metadata: map[string]any{
		"access_token": "fixture-old", "refresh_token": "fixture-renew", "expired": "2000-01-01T00:00:00Z",
	}}
	now := time.Now()
	if login.HasValidAccessToken(now) {
		t.Fatal("fixture should require renewal")
	}
	calls := 0
	transport := kimiRoundTripperFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Method != "POST" || r.URL.String() != "https://auth.kimi.com/api/oauth/token" ||
			r.PostFormValue("grant_type") != "refresh_token" || r.PostFormValue("refresh_token") != "fixture-renew" {
			t.Fatal("unexpected renewal request")
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(
			`{"access_token":"fixture-new","refresh_token":"fixture-next","expires_in":3600,"token_type":"Bearer"}`))}, nil
	})
	ctx := context.WithValue(context.Background(), "cliproxy.roundtripper", transport)
	fresh, err := NewKimiExecutor(&config.Config{}).Refresh(ctx, login)
	if err != nil || calls != 1 || !fresh.HasValidAccessToken(now) || fresh.Metadata["access_token"] != "fixture-new" || fresh.Metadata["refresh_token"] != "fixture-next" {
		t.Fatal("renewal did not replace both tokens and advance expiry")
	}
}
