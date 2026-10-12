#lang racket/base

;; `pcd` — reader/writer for PCD point-cloud files (the Point Cloud Library
;; file format, version 0.7). Supports DATA ascii, DATA binary, and DATA
;; binary_compressed (via the `lzf` package). This module is the public,
;; contract-checked boundary; the implementation lives in pcd/private.

(require racket/contract/base
         pcd/private/cloud
         pcd/private/read
         pcd/private/write)

(define pcd-data/c (symbols 'ascii 'binary 'binary-compressed))

(provide
 (contract-out
  [struct point-cloud
    ([fields (listof string?)]
     [sizes (listof pcd-size/c)]
     [types (listof pcd-type/c)]
     [counts (listof pcd-count/c)]
     [width exact-nonneg-integer?]
     [height exact-nonneg-integer?]
     [viewpoint (vectorof flonum?)]
     [points (vectorof (vectorof real?))])]
  [pcd-size/c contract?]
  [pcd-type/c contract?]
  [pcd-count/c contract?]
  [pcd-data/c contract?]
  [pcd-read (-> input-port? point-cloud?)]
  [pcd-read-file (-> path-string? point-cloud?)]
  [pcd-read-bytes (-> bytes? point-cloud?)]
  [pcd-write (->* (output-port? point-cloud?) (#:data pcd-data/c) void?)]
  [pcd-write-file (->* (path-string? point-cloud?) (#:data pcd-data/c) void?)]))
