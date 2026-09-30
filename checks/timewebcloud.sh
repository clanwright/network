#!/usr/bin/env bash
set -euo pipefail

ip link set lo up
# A network namespace has loopback only: upstream mocks cannot reach a live
# provider or public DNS even if a regression tries to do so.
go test -v -count=1 -timeout=30s ./providers/dns/timewebcloud \
  -run '^(TestNewDNSProvider|TestNewDNSProviderConfig|TestNetworkTimewebV2Contract)$'
go test -v -count=1 -timeout=30s ./providers/dns/timewebcloud/internal
