#lang racket/base

;; PCD readers: DATA ascii, DATA binary, and DATA binary_compressed.

(require lzf
         racket/string
         pcd/private/cloud
         pcd/private/codec
         pcd/private/header)

;; ---- public entry points ---------------------------------------------------

(define (pcd-read in)
  (define-values (hdr meta) (parse-header 'pcd-read in))
  (case (header-mode hdr)
    [(ascii) (read-ascii-data in hdr meta)]
    [(binary) (read-binary-data in hdr meta)]
    [else (read-binary-compressed-data in hdr meta)]))

(define (pcd-read-file path)
  (call-with-input-file path pcd-read))

(define (pcd-read-bytes bs)
  (pcd-read (open-input-bytes bs)))

;; ---- shared ----------------------------------------------------------------

(define (make-points hdr meta data)
  ;; Decodes a point-major byte buffer into the `points` vector.
  (define n (header-points-count hdr))
  (define step (colmeta-step meta))
  (for/vector #:length n ([i (in-range n)])
    (define base (* i step))
    (for/vector #:length (colmeta-total meta) ([j (in-range (colmeta-total meta))])
      (decode-value data (+ base (vector-ref (colmeta-vbyte-offs meta) j))
                    (vector-ref (colmeta-vtypes meta) j)
                    (vector-ref (colmeta-vsizes meta) j)))))

(define (finish hdr meta data)
  (point-cloud (header-fields hdr) (header-sizes hdr) (header-types hdr) (header-counts hdr)
               (header-width hdr) (header-height hdr) (header-viewpoint hdr)
               (make-points hdr meta data)))

;; ---- ascii -------------------------------------------------------------------

(define (read-ascii-data in hdr meta)
  (define n (header-points-count hdr))
  (define total (colmeta-total meta))
  (define data-line (header-data-line-no hdr))
  (define points
    (for/vector #:length n ([i (in-range n)])
      (define line (read-line in 'any))
      (when (eof-object? line)
        (pcd-error 'pcd-read "truncated ascii DATA section: got ~a point(s), expected ~a (input ended)"
                   i n))
      (define file-line (+ data-line i 1))
      (define toks (string-split line))
      (unless (= (length toks) total)
        (pcd-error 'pcd-read "point ~a (file line ~a): expected ~a value(s) per point, got ~a"
                   i file-line total (length toks)))
      (for/vector #:length total ([j (in-range total)] [tok (in-list toks)])
        (parse-ascii-value tok (vector-ref (colmeta-vtypes meta) j)
                           (vector-ref (colmeta-vsizes meta) j)
                           (vector-ref (colmeta-vnames meta) j)
                           i file-line))))
  (point-cloud (header-fields hdr) (header-sizes hdr) (header-types hdr) (header-counts hdr)
               (header-width hdr) (header-height hdr) (header-viewpoint hdr)
               points))

(define (parse-ascii-value tok type size field point-no line-no)
  (cond
    [(char=? type #\F)
     (define x (parse-ascii-real tok))
     (unless x
       (pcd-error 'pcd-read "point ~a, field '~a' (file line ~a): invalid float value '~a'"
                  point-no field line-no tok))
     (real->double-flonum x)]
    [else
     (define x (string->number tok))
     (unless (and x (exact-integer? x))
       (pcd-error 'pcd-read "point ~a, field '~a' (file line ~a): invalid integer value '~a' for a ~a field"
                  point-no field line-no tok
                  (if (char=? type #\U) "unsigned" "signed")))
     (unless (check-int-range x type size)
       (pcd-error 'pcd-read "point ~a, field '~a' (file line ~a): value ~a out of range for a ~a field of SIZE ~a"
                  point-no field line-no x
                  (if (char=? type #\U) "unsigned" "signed") size))
     x]))

;; ---- binary --------------------------------------------------------------------

(define (read-binary-data in hdr meta)
  (define n (header-points-count hdr))
  (define step (colmeta-step meta))
  (define data (read-bytes-exactly 'pcd-read in (* step n) "binary point data"))
  (finish hdr meta data))

;; ---- binary_compressed -----------------------------------------------------------

;; On-disk layout (matching PCL): for each non-padding field, in field order,
;; a little-endian u32 compressed size, a little-endian u32 uncompressed size,
;; then the LZF-compressed chunk of that field's data stored field-major.
;; Padding fields (named "_") are absent from the compressed stream.
(define (read-binary-compressed-data in hdr meta)
  (define n (header-points-count hdr))
  (define step (colmeta-step meta))
  (define nf (colmeta-nfields meta))
  ;; Planes are kept in a full-length vector indexed by field so padding
  ;; slots stay #f and field indices remain aligned.
  (define planes (make-vector nf #f))
  (for ([k (in-range nf)] #:unless (vector-ref (colmeta-fpadding meta) k))
    (define fname (vector-ref (colmeta-fnames meta) k))
    (define csize (read-u32-le 'pcd-read in))
    (define usize (read-u32-le 'pcd-read in))
    (define expected (* (vector-ref (colmeta-fcounts meta) k)
                        (vector-ref (colmeta-fsizes meta) k)
                        n))
    (unless (= usize expected)
      (pcd-error 'pcd-read "binary_compressed: field '~a' declares uncompressed size ~a, expected ~a (SIZE * COUNT * POINTS)"
                 fname usize expected))
    (define chunk
      (if (zero? csize)
          #""
          (read-bytes-exactly 'pcd-read in csize (format "LZF chunk for field '~a'" fname))))
    (define plane (lzf-decompress chunk #:hint usize))
    (unless (bytes? plane)
      (pcd-error 'pcd-read "binary_compressed: corrupt LZF stream for field '~a'" fname))
    (unless (= (bytes-length plane) usize)
      (pcd-error 'pcd-read "binary_compressed: LZF decompression of field '~a' produced ~a byte(s), expected ~a"
                 fname (bytes-length plane) usize))
    (vector-set! planes k plane))
  ;; De-interleave field-major planes into the point-major byte layout;
  ;; padding fields keep the buffer's zero bytes (PCL-compatible).
  (define data (make-bytes (* step n)))
  (for ([k (in-range nf)] #:unless (vector-ref (colmeta-fpadding meta) k))
    (define plane (vector-ref planes k))
    (define chunk-bytes (* (vector-ref (colmeta-fcounts meta) k)
                           (vector-ref (colmeta-fsizes meta) k)))
    (define foff (vector-ref (colmeta-fbyte-offs meta) k))
    (for ([i (in-range n)])
      (bytes-copy! data (+ (* i step) foff)
                   plane (* i chunk-bytes) (* (add1 i) chunk-bytes))))
  (finish hdr meta data))

(provide pcd-read
         pcd-read-file
         pcd-read-bytes)
