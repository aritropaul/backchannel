package main

// WebP encoding for stickers. ImageIO only decodes WebP, so this links
// Homebrew's static libwebp (the app links the .a files; see project.yml).

/*
#cgo CFLAGS: -I/opt/homebrew/opt/webp/include
#include <webp/encode.h>
*/
import "C"

import (
	"errors"
	"image"
	"unsafe"
)

// encodeWebP encodes non-premultiplied RGBA, keeping transparency, at a lossy
// quality from 0 to 100.
func encodeWebP(img *image.NRGBA, quality float32) ([]byte, error) {
	b := img.Bounds()
	if b.Dx() == 0 || b.Dy() == 0 {
		return nil, errors.New("empty image")
	}
	var out *C.uint8_t
	n := C.WebPEncodeRGBA((*C.uint8_t)(unsafe.Pointer(&img.Pix[0])), C.int(b.Dx()), C.int(b.Dy()), C.int(img.Stride),
		C.float(quality), &out)
	if n == 0 || out == nil {
		return nil, errors.New("webp encode failed")
	}
	defer C.WebPFree(unsafe.Pointer(out))
	return C.GoBytes(unsafe.Pointer(out), C.int(n)), nil
}
