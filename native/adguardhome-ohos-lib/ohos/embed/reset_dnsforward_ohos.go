//go:build ohos_c_shared

// This file is a home_cloud_shield / 栖云盾 addition (GPL-3.0-only, same as the
// surrounding AdGuardHome source).  It is NOT part of upstream AdGuardHome.
//
// scripts/build_ohos_shared.sh injects it into internal/dnsforward/ of the pinned
// AdGuardHome submodule before building with `-tags ohos_c_shared`, then removes
// it again so the submodule working tree stays clean.
//
// Why it exists: dnsforward.registerHandlers() guards itself with the
// package-global webRegistered so the DNS control handlers (/control/dns_info,
// /control/access/list, /control/access/set, /control/cache_clear, ...) are
// registered only once per process.  Upstream AdGuardHome assumes a single run
// per process, but the embedded host can Stop and Start AdGuardHome repeatedly
// within one long-lived process (the "DNS server / coexist" mode runs it in the
// app's main process, which is not killed between runs).  Each StartEmbedded
// builds a fresh HTTP mux, so without clearing this guard those handlers are not
// re-registered on the new mux and the dashboard requests for them 404.
//
// StopEmbedded calls ResetWebRegistered to clear the guard, mirroring how it
// already clears home.webHandlersRegistered and clientsContainer.storage.

package dnsforward

// ResetWebRegistered clears the run-once web-handler registration guard so the
// DNS control handlers re-register on a rebuilt HTTP mux on the next start.
func ResetWebRegistered() {
	webRegistered = false
}
