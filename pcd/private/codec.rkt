#lang racket/base

;; Low-level helpers shared by the reader and writer: per-field and
;; per-value metadata for a parsed header, little-endian value codecs, and
;; ascii number formatting/parsing.

(require racket/math
         racket/string)

;; ---- errors --------------------------------------------------------------

(define (pcd-error who fmt . args)
  (apply error who fmt args))

;; ---- port primitives -----------------------------------------------------

(define (read-bytes-exactly who in n what)
  (define b (read-bytes n in))
  (unless (= (bytes-length b) n)
    (pcd-error who "truncated DATA section: needed ~a byte(s) of ~a, got only ~a"
               n what (bytes-length b)))
  b)

(define (read-u32-le who in)
  (integer-bytes->integer (read-bytes-exactly who in 4 "32-bit size") #f #f))

(define (write-u32-le out v)
  (write-bytes (integer->integer-bytes v 4 #f #f) out))

;; ---- per-field / per-value metadata ---------------------------------------

;; A field named "_" is PCL's padding marker: it occupies space in ascii and
;; binary layouts but is skipped in binary_compressed (its values read as 0).
(define (padding-field? name) (string=? name "_"))

;; Precomputed layout of a header: per-field vectors plus per-value (column)
;; vectors. A "value" is one element of one field inside one point; a field
;; with COUNT n contributes n consecutive values to every point.
(struct colmeta
  (nfields      ; number of fields
   fnames       ; vector of field-name strings
   fsizes       ; vector of bytes per element
   ftypes       ; vector of #\F / #\U / #\I
   fcounts      ; vector of elements per field
   fpadding     ; vector of booleans: field name is "_"
   fbyte-offs   ; vector of byte offset of the field inside a point
   fcol0        ; vector of value index of the field's first element
   vtypes       ; per-value vector of #\F / #\U / #\I
   vsizes       ; per-value vector of element byte sizes
   vnames       ; per-value vector of field-name strings
   vbyte-offs   ; per-value vector of byte offset inside a point
   total        ; number of values per point
   step)        ; bytes per point
  #:transparent)

(define (make-column-meta fields sizes types counts)
  (define nf (length fields))
  (define total (for/sum ([c (in-list counts)]) c))
  (define vtypes (make-vector total #\F))
  (define vsizes (make-vector total 4))
  (define vnames (make-vector total ""))
  (define vbyte-offs (make-vector total 0))
  (define fnames (list->vector fields))
  (define fsizes (list->vector sizes))
  (define ftypes (list->vector types))
  (define fcounts (list->vector counts))
  (define fpadding (for/vector ([f (in-list fields)]) (padding-field? f)))
  (define fbyte-offs (make-vector nf 0))
  (define fcol0 (make-vector nf 0))
  (define step
    (let loop ([j 0] [k 0] [byte 0])
      (if (>= k nf)
          byte
          (begin
            (vector-set! fbyte-offs k byte)
            (vector-set! fcol0 k j)
            (let inner ([j j] [e 0] [byte byte])
              (if (>= e (vector-ref fcounts k))
                  (loop j (add1 k) byte)
                  (begin
                    (vector-set! vtypes j (vector-ref ftypes k))
                    (vector-set! vsizes j (vector-ref fsizes k))
                    (vector-set! vnames j (vector-ref fnames k))
                    (vector-set! vbyte-offs j byte)
                    (inner (add1 j) (add1 e) (+ byte (vector-ref fsizes k))))))))))
  (colmeta nf fnames fsizes ftypes fcounts fpadding fbyte-offs fcol0
           vtypes vsizes vnames vbyte-offs total step))

;; ---- binary value codecs (PCD binary is little-endian) --------------------

(define (decode-value bs off type size)
  (cond
    [(char=? type #\F) (floating-point-bytes->real bs #f off (+ off size))]
    [else (integer-bytes->integer bs (char=? type #\I) #f off (+ off size))]))

(define (encode-value who v type size)
  (cond
    [(char=? type #\F) (real->floating-point-bytes (real->double-flonum v) size #f)]
    [(exact-integer? v) (integer->integer-bytes v size (char=? type #\I) #f)]
    [else (pcd-error who "expected an exact integer for an integer field, got: ~a" v)]))

(define (check-int-range v type size)
  (define limit (arithmetic-shift 1 (* 8 size)))
  (if (char=? type #\U)
      (and (>= v 0) (< v limit))
      (and (>= v (- limit)) (< v (sub1 limit)))))

;; ---- ascii values ----------------------------------------------------------

;; Parses one ascii numeric token; returns a real or #f. Accepts the strings
;; PCL 1.0.1+ writes for NaN and infinities.
(define (parse-ascii-real tok)
  (cond
    [(string->number tok)]
    [(string-ci=? tok "nan") +nan.0]
    [(member tok '("inf" "+inf" "infinity" "+infinity")) +inf.0]
    [(member tok '("-inf" "-infinity")) -inf.0]
    [else #f]))

;; Formats a real (already narrowed to the field's float representation by
;; the caller for 'F' fields) the way PCL reads it back: "nan", "inf",
;; "-inf", integral values without a trailing ".0", otherwise number->string.
(define (ascii-real-string v)
  (cond
    [(nan? v) "nan"]
    [(eqv? v +inf.0) "inf"]
    [(eqv? v -inf.0) "-inf"]
    [(and (rational? v) (= v (truncate v)) (<= (abs v) 1e15))
     (number->string (inexact->exact v))]
    [else (number->string v)]))

(define (ascii-value-string v type)
  (cond
    [(char=? type #\F) (ascii-real-string (real->double-flonum v))]
    [else (number->string v)]))

(provide pcd-error
         padding-field?
         read-bytes-exactly
         read-u32-le
         write-u32-le
         (struct-out colmeta)
         make-column-meta
         decode-value
         encode-value
         check-int-range
         parse-ascii-real
         ascii-real-string
         ascii-value-string)
