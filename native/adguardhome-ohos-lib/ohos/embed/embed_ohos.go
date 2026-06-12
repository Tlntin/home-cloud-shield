//go:build ohos_c_shared

// This file is a home_cloud_shield / 栖云盾 addition (GPL-3.0-only, same as the
// surrounding AdGuardHome source).  It is NOT part of upstream AdGuardHome.
//
// It provides an embeddable, library-friendly entry point into the home
// package so AdGuardHome can be driven from a c-shared (.so) build loaded by a
// non-Go host (here: an OpenHarmony app via C/C++/NAPI) instead of the normal
// CLI.  The build script copies this file into internal/home/ of the pinned
// AdGuardHome submodule before building with `-tags ohos_c_shared`.
//
// StartEmbedded mirrors the setup performed by home.run (see home.go) but:
//   - returns errors instead of calling fatalOnError / os.Exit, so a bad config
//     reports an error to the caller rather than killing the host process;
//   - does not install OS signal handlers (the host owns process lifecycle);
//   - runs the (blocking) web server loop in a background goroutine and returns
//     once all servers are started, instead of blocking on <-done.
//
// StopEmbedded performs the same teardown the signal handler would (cleanup +
// cleanupAlways).
//
// Keep this in sync with home.run when bumping the AdGuardHome submodule.

package home

import (
	"context"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"sync"

	"github.com/AdguardTeam/AdGuardHome/internal/aghos"
	"github.com/AdguardTeam/AdGuardHome/internal/dnsforward"
	"github.com/AdguardTeam/AdGuardHome/internal/filtering"
	"github.com/AdguardTeam/AdGuardHome/internal/version"
	"github.com/AdguardTeam/golibs/errors"
	"github.com/AdguardTeam/golibs/log"
	"github.com/AdguardTeam/golibs/logutil/slogutil"
)

// embedMu guards embedStarted and serializes StartEmbedded/StopEmbedded.
var (
	embedMu      sync.Mutex
	embedStarted bool
)

// StartEmbedded configures and starts AdGuard Home using the configuration file
// at confPath, with workDir as the working directory and logPath as the log
// file (logPath may be empty to use the config's log settings).  It returns
// after every server has been started, or an error if startup failed.  The
// embedded instance requires an already-existing configuration file: first-run
// (no config) is reported as an error.
//
// It is the responsibility of the caller (the generated AdGuardHome.yaml) to
// bind the DNS and HTTP servers to free, unprivileged loopback ports, since the
// host app cannot bind privileged ports and the web server aborts the process
// if its address is unavailable.
//
// startWeb controls whether the web admin (dashboard) HTTP server actually
// serves.  The webAPI object is always constructed (tlsManager and the control
// handlers hold references to it), but with startWeb false its blocking serve
// loop is never launched: no listener is bound and no HTTP server goroutines
// run, which saves battery on the mobile host.  cleanup() handles a
// never-started webAPI fine (shutdownSrv is nil-safe on its nil servers).
func StartEmbedded(confPath, workDir, logPath string, clientBuildFS fs.FS, startWeb bool) (err error) {
	embedMu.Lock()
	defer embedMu.Unlock()

	if embedStarted {
		return errors.Error("adguardhome embedded instance is already running")
	}

	opts := options{
		confFilename: confPath,
		workDir:      workDir,
		logFile:      logPath,
		// The host app runs unprivileged and owns the files it creates, so
		// skip the privileged permission checks/migration that home.run would
		// otherwise perform.
		noPermCheck: true,
	}

	// A signal handler is required by run's setup steps (swapLogger,
	// addTLSManager), but we never start its handle goroutine: the host owns
	// process signals.
	ctx := context.Background()
	sigHdlr := newSignalHandler(nil, func(c context.Context) {
		cleanup(c)
		cleanupAlways()
	})

	// Configure working dir and config filename.
	err = initWorkingDir(opts)
	if err != nil {
		return fmt.Errorf("initializing working dir: %w", err)
	}

	initConfigFilename(opts)

	ls := getLogSettings(opts)

	err = configureLogger(ls)
	if err != nil {
		return fmt.Errorf("configuring logger: %w", err)
	}

	slogLogger := newSlogLogger(ls)
	sigHdlr.swapLogger(slogLogger)

	log.Info("%s", version.Full())
	log.Debug("current working directory is %s", globalContext.workDir)

	// Inline of setupContext (home.go) with error returns instead of os.Exit.
	globalContext.firstRun = detectFirstRun()
	globalContext.mux = http.NewServeMux()

	if !opts.noEtcHosts {
		err = setupHostsContainer()
		if err != nil {
			return fmt.Errorf("setting up hosts container: %w", err)
		}
	}

	if globalContext.firstRun {
		return errors.Error("embedded mode requires an existing configuration file")
	}

	err = parseConfig()
	if err != nil {
		return fmt.Errorf("parsing configuration file: %w", err)
	}

	err = configureOS(config)
	if err != nil {
		return fmt.Errorf("configuring os: %w", err)
	}

	// Clients package uses filtering package's static data, so initialize the
	// filtering static data first.
	filtering.InitModule(ctx, slogLogger)

	err = initContextClients(ctx, slogLogger, sigHdlr)
	if err != nil {
		return fmt.Errorf("initializing clients: %w", err)
	}

	tlsMgrLogger := slogLogger.With(slogutil.KeyPrefix, "tls_manager")
	tlsMgr, err := newTLSManager(ctx, &tlsManagerConfig{
		logger:         tlsMgrLogger,
		configModified: onConfigModified,
		tlsSettings:    config.TLS,
		servePlainDNS:  config.DNS.ServePlainDNS,
	})
	if err != nil {
		tlsMgrLogger.ErrorContext(ctx, "initializing", slogutil.KeyError, err)
		onConfigModified()
	}

	globalContext.tls = tlsMgr

	err = setupDNSFilteringConf(ctx, slogLogger, config.Filtering, tlsMgr)
	if err != nil {
		return fmt.Errorf("setting up dns filtering: %w", err)
	}

	err = setupOpts(opts)
	if err != nil {
		return fmt.Errorf("setting up options: %w", err)
	}

	execPath, err := os.Executable()
	if err != nil {
		return fmt.Errorf("getting executable path: %w", err)
	}

	confPathResolved := configFilePath()

	updLogger := slogLogger.With(slogutil.KeyPrefix, "updater")
	upd, isCustomURL := newUpdater(ctx, updLogger, config, globalContext.workDir, confPathResolved, execPath)

	cmdlineUpdate(ctx, updLogger, opts, upd, tlsMgr)

	// Save the updated config (firstRun is always false here).
	err = config.write(nil)
	if err != nil {
		return fmt.Errorf("writing config: %w", err)
	}

	if config.HTTPConfig.Pprof.Enabled {
		startPprof(slogLogger, config.HTTPConfig.Pprof.Port)
	}

	dataDir := globalContext.getDataDir()
	err = os.MkdirAll(dataDir, aghos.DefaultPermDir)
	if err != nil {
		return fmt.Errorf("creating dns data dir at %s: %w", dataDir, err)
	}

	GLMode = opts.glinetMode

	globalContext.auth, err = initUsers()
	if err != nil {
		return fmt.Errorf("initializing users: %w", err)
	}

	web, err := initWeb(ctx, opts, clientBuildFS, upd, slogLogger, tlsMgr, isCustomURL)
	if err != nil {
		return fmt.Errorf("initializing web: %w", err)
	}

	globalContext.web = web

	tlsMgr.setWebAPI(web)
	sigHdlr.addTLSManager(tlsMgr)

	statsDir, querylogDir, err := checkStatsAndQuerylogDirs(&globalContext, config)
	if err != nil {
		return fmt.Errorf("checking stats and querylog dirs: %w", err)
	}

	err = initDNS(slogLogger, tlsMgr, statsDir, querylogDir)
	if err != nil {
		return fmt.Errorf("initializing dns: %w", err)
	}

	tlsMgr.start(ctx)

	err = startDNSServer()
	if err != nil {
		closeDNSServer()

		return fmt.Errorf("starting dns server: %w", err)
	}

	if globalContext.dhcpServer != nil {
		dhcpErr := globalContext.dhcpServer.Start()
		if dhcpErr != nil {
			log.Error("starting dhcp server: %s", dhcpErr)
		}
	}

	// web.start blocks until the web server is shut down, so run it in the
	// background and return control to the host.  With startWeb false the
	// dashboard is simply never served: handlers stay registered on the mux,
	// but no listener binds and no serve goroutines run.
	if startWeb {
		go web.start(ctx)
	}

	embedStarted = true

	return nil
}

// StopEmbedded stops a running embedded AdGuard Home instance previously started
// by StartEmbedded.  It is safe to call when nothing is running.
func StopEmbedded() {
	embedMu.Lock()
	defer embedMu.Unlock()

	if !embedStarted {
		return
	}

	ctx := context.Background()
	cleanup(ctx)
	cleanupAlways()

	// Upstream AdGuard Home assumes a single run per process, so a few modules
	// keep run-once package/global state that cleanup() does not reset. The host
	// app, however, can Stop and Start repeatedly within one long-lived process
	// (e.g. the "DNS server / coexist" mode runs AdGuardHome in the app's main
	// process, which is not killed between runs). Reset the known run-once guards
	// so a subsequent StartEmbedded re-initializes cleanly instead of failing.
	//
	// cleanup() -> stopDNSServer() already closed the clients container; clearing
	// storage only drops the "clients container already initialized" guard in
	// clientsContainer.Init.
	globalContext.clients.storage = nil
	// clientsContainer.registerWebHandlers is gated by this once-flag. Each
	// StartEmbedded builds a fresh mux (globalContext.mux), so re-enable it to let
	// the client web handlers register again on the new mux.
	webHandlersRegistered = false
	// dnsforward.registerHandlers has its own once-flag (webRegistered) gating
	// /control/dns_info, /control/access/list, /control/cache_clear, etc. Clear it
	// too so those re-register on the fresh mux; otherwise the dashboard's requests
	// for them 404 after a Stop/Start within the persistent process.
	dnsforward.ResetWebRegistered()

	embedStarted = false
}
