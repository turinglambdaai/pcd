#lang racket/base

;; Test suite for the `pcd` package: format round-trips (ascii, binary,
;; binary_compressed), golden hand-written headers, a hand-computed
;; binary_compressed payload, organized clouds, and error reporting.

(require racket/file
         racket/math
         racket/port
         racket/string
         rackunit
         lzf
         pcd)

;; ---- helpers -------------------------------------------------------------

(define (cloud->bytes cloud mode)
  (call-with-output-bytes (lambda (out) (pcd-write out cloud #:data mode))))

(define (round-trip cloud mode)
  (pcd-read-bytes (cloud->bytes cloud mode)))

;; Runs thunk; asserts an exn:fail whose message matches regexp.
(define (check-pcd-exn regexp thunk)
  (define got
    (with-handlers ([(lambda (e) (exn:fail? e)) (lambda (e) (cons 'exn (exn-message e)))])
      (thunk)
      (cons 'no-exn #f)))
  (check-equal? (car got) 'exn "expected an exn:fail")
  (check-regexp-match regexp (cdr got)))

(define default-viewpoint (vector 0.0 0.0 0.0 1.0 0.0 0.0 0.0))

(define (u32-le v) (integer->integer-bytes v 4 #f #f))

;; ---- fixtures ---------------------------------------------------------------

;; x/y/z/intensity, float32 throughout. All values are exactly representable
;; in float32, so round-trips must be value-exact (tolerance 0).
(define xyz-intensity
  (point-cloud
   '("x" "y" "z" "intensity") '(4 4 4 4) '(#\F #\F #\F #\F) '(1 1 1 1)
   4 1 default-viewpoint
   (vector (vector 0.5 1.25 -3.75 10.5)
           (vector 1.0 2.0 3.0 -0.5)
           (vector 4210800.0 0.25 100.0 0.0)
           (vector -1.5 2.5 3.5 7.25))))

;; Mixed integer widths: signed 32-bit, unsigned 16-bit, unsigned 8-bit.
(define int-cloud
  (point-cloud
   '("x" "y" "label") '(4 2 1) '(#\I #\U #\U) '(1 1 1)
   2 1 default-viewpoint
   (vector (vector -100000 65535 200)
           (vector 999999 1 0))))

;; A COUNT>1 field: j1 carries 3 int16 elements per point.
(define count-cloud
  (point-cloud
   '("x" "y" "z" "j1") '(4 4 4 2) '(#\F #\F #\F #\I) '(1 1 1 3)
   2 1 default-viewpoint
   (vector (vector 0.0 0.0 0.0 1 2 3)
           (vector 1.5 2.5 3.5 4 5 6))))

;; Organized cloud: 3x2 = 6 points, stored row-major.
(define organized
  (point-cloud
   '("x") '(4) '(#\F) '(1)
   3 2 default-viewpoint
   (vector (vector 0.0) (vector 1.0) (vector 2.0)
           (vector 3.0) (vector 4.0) (vector 5.0))))

;; Padding field: PCL marks ignored fields with the name "_".
(define padded
  (point-cloud
   '("x" "_" "y") '(4 4 4) '(#\F #\F #\F) '(1 1 1)
   2 1 default-viewpoint
   (vector (vector 1.0 9.0 2.0)
           (vector 3.0 8.0 4.0))))

(define modes '(ascii binary binary-compressed))

;; ---- 1. round-trips -----------------------------------------------------------

(define round-trip-tests
  (test-suite
   "round-trips"

   (for ([mode modes])
     (test-case (format "float32 xyz+intensity via ~a" mode)
       (check-equal? (round-trip xyz-intensity mode) xyz-intensity)))

   (for ([mode modes])
     (test-case (format "integer fields via ~a" mode)
       (check-equal? (round-trip int-cloud mode) int-cloud)))

   (for ([mode modes])
     (test-case (format "COUNT>1 fields via ~a" mode)
       (check-equal? (round-trip count-cloud mode) count-cloud)))

   (test-case "header fields survive a binary round-trip"
     (define c (round-trip xyz-intensity 'binary))
     (check-equal? (point-cloud-fields c) '("x" "y" "z" "intensity"))
     (check-equal? (point-cloud-sizes c) '(4 4 4 4))
     (check-equal? (point-cloud-types c) '(#\F #\F #\F #\F))
     (check-equal? (point-cloud-counts c) '(1 1 1 1))
     (check-equal? (point-cloud-width c) 4)
     (check-equal? (point-cloud-height c) 1)
     (check-equal? (point-cloud-viewpoint c) default-viewpoint))

   (test-case "non-default viewpoint survives ascii round-trip"
     (define c0
       (point-cloud '("x") '(4) '(#\F) '(1) 1 1
                    (vector 1.5 -2.5 3.0 0.5 0.5 0.25 0.25)
                    (vector (vector 7.0))))
     (check-equal? (round-trip c0 'ascii) c0))

   (test-case "empty cloud round-trips in every mode"
     (define empty-cloud
       (point-cloud '("x" "y" "z") '(4 4 4) '(#\F #\F #\F) '(1 1 1)
                    0 1 default-viewpoint #()))
     (for ([mode modes])
       (check-equal? (round-trip empty-cloud mode) empty-cloud)))))

;; ---- 2. golden ascii header ----------------------------------------------------

(define golden-ascii-text
  (string-append
   "# .PCD v.7 - Point Cloud Data file format\n"
   "# a comment line that must be skipped\n"
   "VERSION .7\n"
   "FIELDS x y z j1\n"
   "SIZE 4 4 4 2\n"
   "TYPE F F F I\n"
   "COUNT 1 1 1 3\n"
   "WIDTH 2\n"
   "HEIGHT 1\n"
   "VIEWPOINT 0 0 0 1 0 0 0\n"
   "POINTS 2\n"
   "DATA ascii\n"
   "0 0 0 1 2 3\n"
   "1.5 2.5 3.5 4 5 6\n"))

;; Same file with CRLF endings and a blank line: must parse identically.
(define golden-ascii-crlf-text
  (string-append
   "# .PCD v.7\r\n"
   "\r\n"
   "FIELDS x y z j1\r\n"
   "SIZE 4 4 4 2\r\n"
   "TYPE F F F I\r\n"
   "COUNT 1 1 1 3\r\n"
   "WIDTH 2\r\n"
   "HEIGHT 1\r\n"
   "VIEWPOINT 0 0 0 1 0 0 0\r\n"
   "POINTS 2\r\n"
   "DATA ascii\r\n"
   "0 0 0 1 2 3\r\n"
   "1.5 2.5 3.5 4 5 6\r\n"))

;; Minimal header: COUNT and VIEWPOINT omitted -> defaults; comments/blank
;; lines interleaved.
(define minimal-ascii-text
  (string-append
   "# minimal header\n"
   "VERSION .7\n"
   "# fields next\n"
   "FIELDS x y z\n"
   "SIZE 4 4 4\n"
   "TYPE F F F\n"
   "WIDTH 2\n"
   "HEIGHT 1\n"
   "POINTS 2\n"
   "DATA ascii\n"
   "0 0 0\n"
   "1 2 3\n"))

(define minimal-expected
  (point-cloud '("x" "y" "z") '(4 4 4) '(#\F #\F #\F) '(1 1 1)
               2 1 default-viewpoint
               (vector (vector 0.0 0.0 0.0) (vector 1.0 2.0 3.0))))

(define golden-header-tests
  (test-suite
   "golden ascii headers"

   (test-case "comments, COUNT>1, and data parse to the expected cloud"
     (check-equal? (pcd-read-bytes (string->bytes/utf-8 golden-ascii-text))
                   count-cloud))

   (test-case "CRLF endings and blank lines are tolerated"
     (check-equal? (pcd-read-bytes (string->bytes/utf-8 golden-ascii-crlf-text))
                   count-cloud))

   (test-case "omitted COUNT and VIEWPOINT default to 1 and 0 0 0 1 0 0 0"
     (check-equal? (pcd-read-bytes (string->bytes/utf-8 minimal-ascii-text))
                   minimal-expected))

   (test-case "tabs separate values"
     (check-equal?
      (pcd-read-bytes
       (string->bytes/utf-8
        (string-append "FIELDS x y\nSIZE 4 4\nTYPE F F\nWIDTH 1\nHEIGHT 1\n"
                       "POINTS 1\nDATA ascii\n0.5\t2.5\n")))
      (point-cloud '("x" "y") '(4 4) '(#\F #\F) '(1 1) 1 1 default-viewpoint
                   (vector (vector 0.5 2.5)))))

   (test-case "writer emits the canonical header prologue"
     (check-true
      (string-prefix?
       (bytes->string/utf-8 (cloud->bytes xyz-intensity 'ascii))
       "# .PCD v0.7 - Point Cloud Data file format\nVERSION .7\n")))

   (test-case "writer emits integral viewpoint without trailing .0"
     (check-regexp-match
      #rx"VIEWPOINT 0 0 0 1 0 0 0\n"
      (bytes->string/utf-8 (cloud->bytes xyz-intensity 'ascii))))

   (test-case "organized ascii output is one row of WIDTH points per line"
     (check-equal?
      (bytes->string/utf-8 (cloud->bytes organized 'ascii))
      (string-append
       "# .PCD v0.7 - Point Cloud Data file format\n"
       "VERSION .7\n"
       "FIELDS x\n"
       "SIZE 4\n"
       "TYPE F\n"
       "COUNT 1\n"
       "WIDTH 3\n"
       "HEIGHT 2\n"
       "VIEWPOINT 0 0 0 1 0 0 0\n"
       "POINTS 6\n"
       "DATA ascii\n"
       "0\n1\n2\n3\n4\n5\n")))))

;; ---- 3. binary_compressed ground truth ------------------------------------------

;; One float32 field `x`, two points 1.0 and 2.0.
;;
;; Field-major (structure-of-arrays) bytes: 1.0 then 2.0 as little-endian
;; float32 = 00 00 80 3F 00 00 00 40.
;;
;; Hand-computed LZF chunk: a literal-run control byte in 0..31 emits
;; ctrl+1 raw bytes, so ctrl = 7 followed by the 8 field-major bytes.
(define one-field-cloud
  (point-cloud '("x") '(4) '(#\F) '(1) 2 1 default-viewpoint
               (vector (vector 1.0) (vector 2.0))))

(define field-major-bytes
  (bytes 0 0 128 63   ; 1.0f32 little-endian
         0 0 0 64))   ; 2.0f32 little-endian

(define golden-lzf-chunk
  (bytes 7 0 0 128 63 0 0 0 64))

(define golden-compressed-file
  (bytes-append
   (string->bytes/utf-8
    (string-append
     "VERSION .7\n"
     "FIELDS x\n"
     "SIZE 4\n"
     "TYPE F\n"
     "WIDTH 2\n"
     "HEIGHT 1\n"
     "POINTS 2\n"
     "DATA binary_compressed\n"))
   (u32-le 9)                 ; compressed size of the field's chunk
   (u32-le 8)                 ; uncompressed size of the field's chunk
   golden-lzf-chunk))         ; the chunk itself

(define golden-compressed-tests
  (test-suite
   "binary_compressed ground truth"

   (test-case "hand-computed LZF literal-run chunk decodes to field-major bytes"
     (check-equal? (lzf-decompress golden-lzf-chunk) field-major-bytes))

   (test-case "lzf package round-trips the field-major bytes"
     (check-equal? (lzf-decompress (lzf-compress field-major-bytes))
                   field-major-bytes))

   (test-case "golden file bytes decode to the expected points"
     (check-equal? (pcd-read-bytes golden-compressed-file) one-field-cloud))

   (test-case "writer emits cSize + uSize + chunk that decompresses to field-major bytes"
     (define out (cloud->bytes one-field-cloud 'binary-compressed))
     (define m (regexp-match-positions #rx#"DATA binary_compressed\n" out))
     (check-not-false m "written file has no DATA binary_compressed line")
     (define payload (subbytes out (cdar m)))
     (check-equal? (integer-bytes->integer payload #f #f 0 4) 9 "compressed size")
     (check-equal? (integer-bytes->integer payload #f #f 4 8) 8 "uncompressed size")
     (define chunk (subbytes payload 8))
     (check-equal? (bytes-length payload) (+ 8 (bytes-length chunk))
                   "no trailing bytes after the chunk")
     (check-equal? (lzf-decompress chunk) field-major-bytes))

   (test-case "writer chunk equals the package compressor's output for the trivial case"
     (define out (cloud->bytes one-field-cloud 'binary-compressed))
     (define payload (subbytes out (cdar (regexp-match-positions #rx#"DATA binary_compressed\n" out))))
     (check-equal? (subbytes payload 8) (lzf-compress field-major-bytes)))))

;; ---- 4. organized clouds -------------------------------------------------------

(define organized-tests
  (test-suite
   "organized clouds"

   (for ([mode modes])
     (test-case (format "3x2 cloud round-trips via ~a" mode)
       (define c (round-trip organized mode))
       (check-equal? c organized)
       (check-equal? (point-cloud-width c) 3)
       (check-equal? (point-cloud-height c) 2)
       (check-equal? (vector-length (point-cloud-points c)) 6)))

   (test-case "points are stored row-major (WIDTH consecutive points per row)"
     (define c (pcd-read-bytes (cloud->bytes organized 'ascii)))
     (check-equal?
      (for/list ([i (in-range 6)])
        (vector-ref (vector-ref (point-cloud-points c) i) 0))
      '(0.0 1.0 2.0 3.0 4.0 5.0)))

   (test-case "padding values survive ascii and binary round-trips"
     (for ([mode '(ascii binary)])
       (check-equal? (round-trip padded mode) padded)))

   (test-case "binary_compressed skips padding fields (values read as 0)"
     (define c (round-trip padded 'binary-compressed))
     (check-equal? (vector-ref (vector-ref (point-cloud-points c) 0) 0) 1.0)
     (check-equal? (vector-ref (vector-ref (point-cloud-points c) 0) 1) 0.0)
     (check-equal? (vector-ref (vector-ref (point-cloud-points c) 0) 2) 2.0))))

;; ---- 5. NaN / infinity handling -------------------------------------------------

(define nan-tests
  (test-suite
   "nan and infinity"

   (test-case "ascii nan/inf/-inf parse"
     (define c
       (pcd-read-bytes
        (string->bytes/utf-8
         (string-append "FIELDS x y\nSIZE 4 4\nTYPE F F\nWIDTH 2\nHEIGHT 1\n"
                        "POINTS 2\nDATA ascii\nnan inf\n-inf 1.5\n"))))
     (define pts (point-cloud-points c))
     (check-true (nan? (vector-ref (vector-ref pts 0) 0)))
     (check-equal? (vector-ref (vector-ref pts 0) 1) +inf.0)
     (check-equal? (vector-ref (vector-ref pts 1) 0) -inf.0)
     (check-equal? (vector-ref (vector-ref pts 1) 1) 1.5))

   (test-case "writer emits PCL-style nan/inf strings"
     (define c
       (point-cloud '("x") '(4) '(#\F) '(1) 3 1 default-viewpoint
                    (vector (vector +nan.0) (vector +inf.0) (vector -inf.0))))
     (check-regexp-match
      #rx"DATA ascii\nnan\ninf\n-inf\n"
      (bytes->string/utf-8 (cloud->bytes c 'ascii))))

   (test-case "binary nan round-trips bit-exactly"
     (define c0
       (point-cloud '("x") '(4) '(#\F) '(1) 1 1 default-viewpoint
                    (vector (vector +nan.0))))
     (define c (round-trip c0 'binary))
     (check-true (nan? (vector-ref (vector-ref (point-cloud-points c) 0) 0))))))

;; ---- 6. file-based entry points ---------------------------------------------------

(define file-tests
  (test-suite
   "file entry points"
   (test-case "pcd-write-file + pcd-read-file round-trip"
     (define path
       (build-path (find-system-path 'temp-dir)
                   (format "pcd-roundtrip-~a.pcd" (current-inexact-milliseconds))))
     (pcd-write-file path xyz-intensity #:data 'binary-compressed)
     (check-equal? (pcd-read-file path) xyz-intensity)
     (delete-file path))
   (test-case "default #:data is ascii"
     (define path
       (build-path (find-system-path 'temp-dir)
                   (format "pcd-ascii-~a.pcd" (current-inexact-milliseconds))))
     (pcd-write-file path xyz-intensity)
     (check-regexp-match #rx"DATA ascii\n" (file->bytes path))
     (delete-file path))))

;; ---- 7. errors -----------------------------------------------------------------

(define header-prefix
  (string-append
   "FIELDS x y z\n"
   "SIZE 4 4 4\n"
   "TYPE F F F\n"
   "WIDTH 1\n"
   "HEIGHT 1\n"))

(define error-tests
  (test-suite
   "errors"

   (test-case "truncated header (no DATA line)"
     (check-pcd-exn
      #rx"pcd-read: truncated header.*without a DATA line"
      (lambda () (pcd-read-bytes (string->bytes/utf-8 "VERSION .7\nFIELDS x\n")))))

   (test-case "missing required keyword"
     (check-pcd-exn
      #rx"missing required keyword SIZE"
      (lambda ()
        (pcd-read-bytes
         (string->bytes/utf-8
          (string-append "FIELDS x\nTYPE F\nWIDTH 1\nHEIGHT 1\nPOINTS 1\nDATA ascii\n0\n"))))))

   (test-case "unknown header keyword names the line"
     (check-pcd-exn
      #rx"header line 2: unrecognized header line 'FOO 1'"
      (lambda ()
        (pcd-read-bytes
         (string->bytes/utf-8
          (string-append "# c\nFOO 1\n" header-prefix "POINTS 1\nDATA ascii\n0 0 0\n"))))))

   (test-case "unknown TYPE names the field and line"
     (check-pcd-exn
      #rx"header line 3: unknown TYPE 'Q' for field 'z'"
      (lambda ()
        (pcd-read-bytes
         (string->bytes/utf-8
          (string-append
           "FIELDS x y z\nSIZE 4 4 4\nTYPE F F Q\n"
           "WIDTH 1\nHEIGHT 1\nPOINTS 1\nDATA ascii\n0 0 0\n"))))))

   (test-case "bad SIZE names the field"
     (check-pcd-exn
      #rx"SIZE must be 1, 2, 4, or 8 bytes [(]field 'y'[)], got 3"
      (lambda ()
        (pcd-read-bytes
         (string->bytes/utf-8
          (string-append
           "FIELDS x y z\nSIZE 4 3 4\nTYPE F F F\n"
           "WIDTH 1\nHEIGHT 1\nPOINTS 1\nDATA ascii\n0 0 0\n"))))))

   (test-case "TYPE F with SIZE 2 is rejected"
     (check-pcd-exn
      #rx"TYPE F for field 'x' requires SIZE 4 or 8"
      (lambda ()
        (pcd-read-bytes
         (string->bytes/utf-8
          (string-append
           "FIELDS x\nSIZE 2\nTYPE F\nWIDTH 1\nHEIGHT 1\nPOINTS 1\nDATA ascii\n0\n"))))))

   (test-case "POINTS mismatch names the offending line"
     (check-pcd-exn
      #rx"header line 6: POINTS 5 does not match WIDTH \\* HEIGHT = 1"
      (lambda ()
        (pcd-read-bytes
         (string->bytes/utf-8
          (string-append header-prefix "POINTS 5\nDATA ascii\n0 0 0\n"))))))

   (test-case "unknown DATA mode"
     (check-pcd-exn
      #rx"DATA mode must be ascii, binary, or binary_compressed, got 'zstd'"
      (lambda ()
        (pcd-read-bytes
         (string->bytes/utf-8
          (string-append header-prefix "POINTS 1\nDATA zstd\n"))))))

   (test-case "truncated binary DATA section"
     (check-pcd-exn
      #rx"truncated DATA section: needed 12 byte[(]s[)] of binary point data, got only 4"
      (lambda ()
        (pcd-read-bytes
         (bytes-append
          (string->bytes/utf-8
           (string-append
            "FIELDS x\nSIZE 4\nTYPE F\nWIDTH 3\nHEIGHT 1\nPOINTS 3\nDATA binary\n"))
          (bytes 0 0 128 63))))))

   (test-case "truncated binary_compressed chunk"
     (check-pcd-exn
      #rx"truncated DATA section.*LZF chunk for field 'x'"
      (lambda ()
        (pcd-read-bytes
         (bytes-append
          (string->bytes/utf-8
           (string-append
            "FIELDS x\nSIZE 4\nTYPE F\nWIDTH 2\nHEIGHT 1\nPOINTS 2\n"
            "DATA binary_compressed\n"))
          (u32-le 9) (u32-le 8)
          (bytes 7 0 0 128))))))

   (test-case "binary_compressed uncompressed-size mismatch names the field"
     (check-pcd-exn
      #rx"field 'x' declares uncompressed size 7, expected 8"
      (lambda ()
        (pcd-read-bytes
         (bytes-append
          (string->bytes/utf-8
           (string-append
            "FIELDS x\nSIZE 4\nTYPE F\nWIDTH 2\nHEIGHT 1\nPOINTS 2\n"
            "DATA binary_compressed\n"))
          (u32-le 9) (u32-le 7)
          (bytes 7 0 0 128 63 0 0 0 64))))))

   (test-case "corrupt LZF stream"
     (check-pcd-exn
      #rx"binary_compressed: LZF decompression of field 'x' produced"
      (lambda ()
        (pcd-read-bytes
         (bytes-append
          (string->bytes/utf-8
           (string-append
            "FIELDS x\nSIZE 4\nTYPE F\nWIDTH 2\nHEIGHT 1\nPOINTS 2\n"
            "DATA binary_compressed\n"))
          ;; valid uncompressed size, but the stream only holds 5 literals
          (u32-le 6) (u32-le 8)
          (bytes 4 0 0 128 63 0))))))

   (test-case "invalid ascii float token names the point and field"
     (check-pcd-exn
      #rx"point 1, field 'y' [(]file line 9[)]: invalid float value 'abc'"
      (lambda ()
        (pcd-read-bytes
         (string->bytes/utf-8
          (string-append
           "FIELDS x y z\nSIZE 4 4 4\nTYPE F F F\nWIDTH 2\nHEIGHT 1\n"
           "POINTS 2\nDATA ascii\n0 0 0\n1 abc 2\n"))))))

   (test-case "wrong ascii value count names the point and line"
     (check-pcd-exn
      #rx"point 0 [(]file line 8[)]: expected 3 value[(]s[)] per point, got 2"
      (lambda ()
        (pcd-read-bytes
         (string->bytes/utf-8
          (string-append header-prefix "POINTS 1\nDATA ascii\n0 0\n"))))))

   (test-case "ascii integer token for float field is accepted"
     (check-equal?
      (pcd-read-bytes
       (string->bytes/utf-8
        (string-append header-prefix "POINTS 1\nDATA ascii\n0 0 0\n")))
      (point-cloud '("x" "y" "z") '(4 4 4) '(#\F #\F #\F) '(1 1 1) 1 1 default-viewpoint
                   (vector (vector 0.0 0.0 0.0)))))

   (test-case "integer out of range in ascii data"
     (check-pcd-exn
      #rx"value 300 out of range for a unsigned field of SIZE 1"
      (lambda ()
        (pcd-read-bytes
         (string->bytes/utf-8
          (string-append
           "FIELDS label\nSIZE 1\nTYPE U\nWIDTH 1\nHEIGHT 1\nPOINTS 1\n"
           "DATA ascii\n300\n"))))))

   (test-case "contract rejects a float field holding a string"
     (check-pcd-exn
      #rx"expected: real[?]"
      (lambda ()
        (point-cloud '("x") '(4) '(#\F) '(1) 1 1 default-viewpoint
                     (vector (vector "oops"))))))

   (test-case "guard rejects WIDTH*HEIGHT mismatch"
     (check-pcd-exn
      #rx"WIDTH \\* HEIGHT = 2 does not match the number of points, 1"
      (lambda ()
        (point-cloud '("x") '(4) '(#\F) '(1) 2 1 default-viewpoint
                     (vector (vector 1.0))))))

   (test-case "guard rejects TYPE F with SIZE 2"
     (check-pcd-exn
      #rx"field 'x': TYPE F requires SIZE 4 or 8"
      (lambda ()
        (point-cloud '("x") '(2) '(#\F) '(1) 1 1 default-viewpoint
                     (vector (vector 1.0))))))

   (test-case "guard rejects a point with the wrong number of values"
     (check-pcd-exn
      #rx"point 0: expected 2 value\\(s\\) per point"
      (lambda ()
        (point-cloud '("x" "y") '(4 4) '(#\F #\F) '(1 1) 1 1 default-viewpoint
                     (vector (vector 1.0))))))

   (test-case "guard rejects unknown type"
     (check-pcd-exn
      #rx"expected: pcd-type/c"
      (lambda ()
        (point-cloud '("x") '(4) '(#\X) '(1) 1 1 default-viewpoint
                     (vector (vector 1.0))))))

   (test-case "guard rejects integer field holding a float"
     (check-pcd-exn
      #rx"expected an exact integer for an integer field"
      (lambda ()
        (point-cloud '("label") '(1) '(#\U) '(1) 1 1 default-viewpoint
                     (vector (vector 1.5))))))

   (test-case "guard rejects out-of-range integer"
     (check-pcd-exn
      #rx"value 256 out of range for unsigned SIZE 1"
      (lambda ()
        (point-cloud '("label") '(1) '(#\U) '(1) 1 1 default-viewpoint
                     (vector (vector 256))))))

   (test-case "pcd-write rejects a float field holding a string (contract fires)"
     (check-pcd-exn
      #rx"expected: real[?]"
      (lambda ()
        (point-cloud '("x") '(4) '(#\F) '(1) 1 1 default-viewpoint
                     (vector (vector "oops"))))))))

;; ---- run ------------------------------------------------------------------------

(module+ main
  (require rackunit/text-ui)
  (define result
    (run-tests
     (test-suite "pcd"
                 round-trip-tests
                 golden-header-tests
                 golden-compressed-tests
                 organized-tests
                 nan-tests
                 file-tests
                 error-tests)))
  (exit (if (zero? result) 0 1)))
