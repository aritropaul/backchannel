package main

/*
#include <stdlib.h>
#include <stdint.h>

// Events flow Go -> Swift through one callback. The buffer is only valid for
// the duration of the call; the receiver must copy it.
typedef void (*wa_event_cb)(const char *json, int64_t len);

static inline void wa_invoke(wa_event_cb cb, const char *json, int64_t len) {
	if (cb) cb(json, len);
}
*/
import "C"

import (
	"encoding/json"
	"unsafe"
)

var eventCB C.wa_event_cb

// WAStart opens the local store and begins connecting. It returns quickly;
// everything network-bound happens in the background and reports via events.
//
//export WAStart
func WAStart(dir *C.char, cb C.wa_event_cb) *C.char {
	eventCB = cb
	sink = func(b []byte) {
		if len(b) == 0 {
			return
		}
		C.wa_invoke(eventCB, (*C.char)(unsafe.Pointer(&b[0])), C.int64_t(len(b)))
	}
	me, err := start(C.GoString(dir))
	if err != nil {
		return result(map[string]any{"error": err.Error()})
	}
	return result(map[string]any{"ok": true, "me": me})
}

// WACall runs one JSON command (see req in actions.go) and returns JSON.
//
//export WACall
func WACall(cmd *C.char, n C.int64_t) *C.char {
	return result(call(C.GoBytes(unsafe.Pointer(cmd), C.int(n))))
}

//export WAFree
func WAFree(p *C.char) {
	C.free(unsafe.Pointer(p))
}

func result(v any) *C.char {
	b, _ := json.Marshal(v)
	return C.CString(string(b))
}
