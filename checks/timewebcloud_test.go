package timewebcloud

import (
	"net/http"
	"sync"
	"testing"

	"github.com/go-acme/lego/v5/challenge/dns01"
	"github.com/go-acme/lego/v5/internal/tester/dnsmock"
	"github.com/go-acme/lego/v5/internal/tester/servermock"
	"github.com/stretchr/testify/require"
)

// Upstream covers API serialization/errors but not delegated identity or the
// provider's record-ID lifecycle. Only assertions are added; upstream owns both
// DNS and HTTP mock engines, response fixtures and provider construction.
func TestNetworkTimewebV2Contract(t *testing.T) {
	previous := dns01.DefaultClient()
	t.Cleanup(func() { dns01.SetDefaultClient(previous) })
	t.Setenv("LEGO_DISABLE_CNAME_SUPPORT", "false")

	addr := dnsmock.NewServer().
		Query("_acme-challenge.alias.example.test. CNAME", dnsmock.CNAME("_acme-challenge.target.example.test.")).
		Query("_acme-challenge.target.example.test. CNAME", dnsmock.Noop).
		Query("_acme-challenge.target.example.test. SOA", dnsmock.SOA("example.test.")).
		Query("_acme-challenge.direct.example.test. CNAME", dnsmock.Noop).
		Query("_acme-challenge.direct.example.test. SOA", dnsmock.SOA("example.test.")).
		Build(t)
	dns01.SetDefaultClient(dns01.NewClient(&dns01.Options{RecursiveNameservers: []string{addr.String()}}))

	for _, test := range []struct {
		name, domain, effective string
		failCreate              bool
	}{
		{name: "direct control", domain: "direct.example.test", effective: "_acme-challenge.direct.example.test."},
		{name: "CNAME lifecycle", domain: "alias.example.test", effective: "_acme-challenge.target.example.test."},
		{name: "CNAME rejected creation", domain: "alias.example.test", effective: "_acme-challenge.target.example.test.", failCreate: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			const token, keyAuth = "synthetic-token", "123d=="
			info := dns01.GetChallengeInfo(t.Context(), test.domain, keyAuth)
			require.Equal(t, test.effective, info.EffectiveFQDN)
			path := "/v2/domains/" + test.effective[:len(test.effective)-1] + "/dns-records"
			var mu sync.Mutex
			var calls []string
			recordCall := servermock.LinkFunc(func(next http.Handler) http.Handler {
				return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
					mu.Lock()
					calls = append(calls, req.Method+" "+req.URL.Path)
					mu.Unlock()
					next.ServeHTTP(w, req)
				})
			})
			create := servermock.ResponseFromInternal("createDomainDNSRecord.json").WithStatusCode(http.StatusCreated)
			if test.failCreate {
				create = servermock.ResponseFromInternal("error_bad_request.json").WithStatusCode(http.StatusBadRequest)
			}
			provider := mockBuilder().
				Route("POST "+path, create, recordCall,
					servermock.CheckRequestJSONBodyFromStruct(map[string]string{"type": "TXT", "value": info.Value})).
				Route("DELETE "+path+"/123", servermock.Noop().WithStatusCode(http.StatusNoContent), recordCall).
				Build(t)

			err := provider.Present(t.Context(), test.domain, token, keyAuth)
			if test.failCreate {
				require.EqualError(t, err, "timewebcloud: create record: 400: Value must be a number conforming to the specified constraints (bad_request) [15095f25-aac3-4d60-a788-96cb5136f186]")
				require.Empty(t, provider.recordIDs)
				require.EqualError(t, provider.CleanUp(t.Context(), test.domain, token, keyAuth), "timewebcloud: unknown record ID for '"+test.effective+"'")
			} else {
				require.NoError(t, err)
				require.Equal(t, 123, provider.recordIDs[token])
				require.NoError(t, provider.CleanUp(t.Context(), test.domain, token, keyAuth))
				require.Empty(t, provider.recordIDs)
				require.EqualError(t, provider.CleanUp(t.Context(), test.domain, token, keyAuth), "timewebcloud: unknown record ID for '"+test.effective+"'")
			}
			expected := []string{"POST " + path}
			if !test.failCreate {
				expected = append(expected, "DELETE "+path+"/123")
			}
			mu.Lock()
			defer mu.Unlock()
			require.Equal(t, expected, calls)
		})
	}
}
