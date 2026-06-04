//go:build ohos_c_shared

// This file is a home_cloud_shield / 栖云盾 addition (GPL-3.0-only, same as the
// surrounding AdGuardHome source).  It is NOT part of upstream AdGuardHome.
//
// It is the cgo export layer for the OpenHarmony c-shared (.so) build.  The
// build script copies it into the AdGuardHome module root (next to main.go)
// before building with `go build -tags ohos_c_shared -buildmode=c-shared`.
//
// The exported C symbols and signatures must stay in sync with the consumed
// header, libadguardhome_ohos.h:
//
//	void  AdGuardHomeFreeCString(char* str);
//	char* AdGuardHomeVersion();
//	char* AdGuardHomeStart(char* configPath, char* workDir, char* logPath);
//	char* AdGuardHomeStop();
//
// All returned char* are heap-allocated with C.CString and MUST be released by
// the caller via AdGuardHomeFreeCString.  AdGuardHomeStart/AdGuardHomeStop
// return an empty string on success or an error message on failure.

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	"github.com/AdguardTeam/AdGuardHome/internal/home"
	"github.com/AdguardTeam/AdGuardHome/internal/version"
)

// AdGuardHomeVersion returns the AdGuard Home version string.
//
//export AdGuardHomeVersion
func AdGuardHomeVersion() *C.char {
	return C.CString(version.Version())
}

// AdGuardHomeStart starts the embedded AdGuard Home instance.  It returns an
// empty string on success, or an error message on failure.  clientBuildFS is
// the embedded web client filesystem declared in main.go.
//
//export AdGuardHomeStart
func AdGuardHomeStart(configPath, workDir, logPath *C.char) *C.char {
	err := home.StartEmbedded(
		C.GoString(configPath),
		C.GoString(workDir),
		C.GoString(logPath),
		clientBuildFS,
	)
	if err != nil {
		return C.CString(err.Error())
	}

	return C.CString("")
}

// AdGuardHomeStop stops the embedded AdGuard Home instance.  It returns an empty
// string (reserved for a future error channel) and is safe to call when nothing
// is running.
//
//export AdGuardHomeStop
func AdGuardHomeStop() *C.char {
	home.StopEmbedded()

	return C.CString("")
}

// AdGuardHomeFreeCString frees a char* previously returned by one of the
// exported functions.
//
//export AdGuardHomeFreeCString
func AdGuardHomeFreeCString(str *C.char) {
	C.free(unsafe.Pointer(str))
}
