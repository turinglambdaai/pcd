# pcd

**English** · [中文](README.zh-CN.md)

[![CI](https://github.com/turlamai/pcd/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/pcd/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A pure-Racket reader and writer for **PCD point-cloud files** — the native
file format of the [Point Cloud Library (PCL)](https://pointclouds.org/),
version 0.7. It reads and writes all three PCD storage modes: `DATA ascii`,
`DATA binary`, and `DATA binary_compressed`.

## Install

```
raco pkg install pcd
```

## Example

```racket
#lang racket/base
(require racket/port pcd)

(define cloud
  (point-cloud
   '("x" "y" "z" "intensity")     ; FIELDS
   '(4 4 4 4)                     ; SIZE (bytes per element)
   '(#\F #\F #\F #\F)             ; TYPE
   '(1 1 1 1)                     ; COUNT
   3 1                            ; WIDTH, HEIGHT
   (vector 0.0 0.0 0.0 1.0 0.0 0.0 0.0)  ; VIEWPOINT
   (vector (vector 0.5 1.25 -3.75 10.5)
           (vector 1.0 2.0 3.0 -0.5)
           (vector 4.0 5.0 6.0 1.5))))

(define encoded
  (call-with-output-bytes
   (lambda (out) (pcd-write out cloud #:data 'binary-compressed))))
(define cloud2 (pcd-read-bytes encoded))
(equal? cloud2 cloud) ; => #t
```

And reading any PCD file (with or without a preceding call to `pcd-write`):

```racket
(define c (pcd-read-file "table_scene_lms400.pcd"))
(point-cloud-fields c)   ; '("x" "y" "z" "intensity")
(point-cloud-points c)   ; point-major vector of value vectors
```

## Tested API examples and development

The complete [Scribble API reference](pcd/scribblings/pcd.scrbl) documents
the `point-cloud` structure, port and file APIs, the three PCD 0.7 storage
modes, header validation and format errors. The [runnable quickstart](pcd/examples/quickstart.rkt)
constructs a synthetic cloud and verifies **all three** `ascii`, `binary`
and `binary-compressed` round trips using in-memory ports—no hard-coded
`/tmp` path, fixture download or PCL/ECU hardware required. Compressed
mode uses the declared pure-Racket `lzf` dependency.

Run from a local checkout (Racket installed):

```sh
raco pkg install --auto --link "$(pwd)"
raco test -p pcd
racket pcd/examples/quickstart.rkt
raco setup --check-pkg-deps -l pcd
```

CI runs these checks on Ubuntu, Windows and macOS. The public `pcd`
collection belongs to a multi-collection Racket package. File APIs are
still available via `pcd-read-file` and `pcd-write-file` for real data.

## The point-cloud record

A `point-cloud` holds the header fields and the data:

- `fields` — `(listof string?)`, the `FIELDS` names in file order
- `sizes` — bytes per field element: `1`, `2`, `4`, or `8`
- `types` — `#\F` (float), `#\U` (unsigned), or `#\I` (signed) per field
- `counts` — elements per field, the `COUNT` line (defaults to 1 when a file omits it)
- `width`, `height` — the `WIDTH` and `HEIGHT` lines. Organized clouds
  (`HEIGHT` > 1) are supported; `points` is stored **row-major**
  (`WIDTH` consecutive points per row)
- `viewpoint` — 7 flonums: translation `tx ty tz` then quaternion `qw qx qy qz`
- `points` — point-major `(vectorof (vectorof real?))`; each point is a flat
  vector holding every field element in file order, `COUNT` elements per
  field. `'F'` columns hold flonums; `'U'`/`'I'` columns hold exact integers.

## Scope notes

- Targets PCD **version 0.7** (the current PCL format).
- `binary` and `binary_compressed` payloads are little-endian, matching PCL.
- `binary_compressed` support uses the pure-Racket
  [`lzf`](https://pkgs.racket-lang.org/package/lzf) package (the LZF codec
  PCL uses). It is declared as a runtime dependency.
- `COUNT` > 1 fields (n-D descriptors) are supported: a field's elements are
  flattened into consecutive positions of each point's value vector.
- Fields named `_` (PCL's padding marker) occupy space in `ascii`/`binary`
  data and are skipped in `binary_compressed` chunks — on read their values
  are `0`, exactly like PCL.
- PCL's NaN/inf conventions are honored on round-trip (`nan`, `inf`, `-inf`
  in ascii data; raw bit patterns in binary data).
- This package is a file-format codec only — it does not re-create PCL's
  `pcl::PointCloud` type system, Kd-trees, filters, or I/O for other formats.
