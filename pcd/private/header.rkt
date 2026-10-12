#lang racket/base

;; PCD v0.7 header parsing and formatting.
;;
;; Header order per the PCD file format spec: VERSION, FIELDS, SIZE, TYPE,
;; COUNT, WIDTH, HEIGHT, VIEWPOINT, POINTS, DATA. Comment lines (#...) and
;; blank lines are skipped. Parsing is keyword-driven; every header error
;; names the offending line number.

(require racket/string
         pcd/private/cloud
         pcd/private/codec)

(struct header
  (fields      ; (listof string?)
   sizes       ; (listof 1/2/4/8)
   types       ; (listof #\F/#\U/#\I)
   counts      ; (listof positive integers)
   width
   height
   viewpoint   ; (vectorof flonum?) length 7
   points-count
   mode        ; 'ascii | 'binary | 'binary-compressed
   data-line-no) ; file line number of the DATA line (1-based)
  #:transparent)

(define known-keywords
  '(VERSION FIELDS SIZE TYPE COUNT WIDTH HEIGHT VIEWPOINT POINTS))

(define (require-keyword who seen key)
  (define entry (hash-ref seen key #f))
  (unless entry
    (pcd-error who "truncated header: missing required keyword ~a before DATA" key))
  entry)

(define (parse-uint-token who tok what line-no)
  (define v (string->number tok))
  (unless (and v (exact-integer? v) (>= v 0))
    (pcd-error who "header line ~a: ~a must be a nonnegative integer, got '~a'" line-no what tok))
  v)

(define (parse-header who in)
  ;; keyword -> (cons line-no tokens)
  (define seen (make-hash))
  (define data-line-no 0)
  (define data-mode #f)
  (define line-no 0)
  (let scan ()
    (define line (read-line in 'any))
    (when (eof-object? line)
      (pcd-error who "truncated header: reached end of input at line ~a without a DATA line" line-no))
    (set! line-no (add1 line-no))
    (define s (string-trim line))
    (cond
      ;; blank line or comment line
      [(or (zero? (string-length s)) (char=? (string-ref s 0) #\#)) (scan)]
      [else
       (define toks (string-split s))
       (define kw (car toks))
       (cond
         [(string=? kw "DATA")
          (unless (= (length toks) 2)
            (pcd-error who "header line ~a: DATA takes exactly one argument (ascii, binary, or binary_compressed), got ~a"
                       line-no (string-join (cdr toks) " ")))
          (define mode (cadr toks))
          (unless (member mode '("ascii" "binary" "binary_compressed"))
            (pcd-error who "header line ~a: DATA mode must be ascii, binary, or binary_compressed, got '~a'"
                       line-no mode))
          (set! data-line-no line-no)
          (set! data-mode (case mode [("ascii") 'ascii]
                                     [("binary") 'binary]
                                     [else 'binary-compressed]))]
         [else
          (define key (string->symbol kw))
          (unless (memq key known-keywords)
            (pcd-error who "header line ~a: unrecognized header line '~a' (expected one of VERSION, FIELDS, SIZE, TYPE, COUNT, WIDTH, HEIGHT, VIEWPOINT, POINTS, DATA)"
                       line-no s))
          (when (hash-ref seen key #f)
            (pcd-error who "header line ~a: duplicate header keyword ~a (first seen at line ~a)"
                       line-no kw (car (hash-ref seen key))))
          (hash-set! seen key (cons line-no (cdr toks)))
          (scan)])]))

  ;; FIELDS
  (define f-entry (require-keyword who seen 'FIELDS))
  (define f-line (car f-entry))
  (define fields (cdr f-entry))
  (when (zero? (length fields))
    (pcd-error who "header line ~a: FIELDS needs at least one field name" f-line))
  (define nf (length fields))

  ;; SIZE
  (define s-entry (require-keyword who seen 'SIZE))
  (define s-line (car s-entry))
  (define sizes
    (for/list ([tok (in-list (cdr s-entry))] [f (in-list fields)])
      (define v (parse-uint-token who tok "SIZE" s-line))
      (unless (memq v '(1 2 4 8))
        (pcd-error who "header line ~a: SIZE must be 1, 2, 4, or 8 bytes (field '~a'), got ~a" s-line f v))
      v))
  (unless (= (length sizes) nf)
    (pcd-error who "header line ~a: SIZE has ~a value(s) but FIELDS (line ~a) has ~a field(s)"
               s-line (length sizes) f-line nf))

  ;; TYPE
  (define t-entry (require-keyword who seen 'TYPE))
  (define t-line (car t-entry))
  (define types
    (for/list ([tok (in-list (cdr t-entry))] [f (in-list fields)] [size (in-list sizes)])
      (define toku (string-upcase tok))
      (unless (= (string-length toku) 1)
        (pcd-error who "header line ~a: TYPE must be a single character F, U, or I (field '~a'), got '~a'" t-line f tok))
      (define c (string-ref toku 0))
      (unless (memq c '(#\F #\U #\I))
        (pcd-error who "header line ~a: unknown TYPE '~a' for field '~a' (expected F, U, or I)" t-line tok f))
      (when (and (char=? c #\F) (not (or (= size 4) (= size 8))))
        (pcd-error who "header line ~a: TYPE F for field '~a' requires SIZE 4 or 8, got SIZE ~a" t-line f size))
      c))
  (unless (= (length types) nf)
    (pcd-error who "header line ~a: TYPE has ~a value(s) but FIELDS (line ~a) has ~a field(s)"
               t-line (length types) f-line nf))

  ;; COUNT (optional, defaults to 1 per field)
  (define counts
    (cond
      [(hash-ref seen 'COUNT #f)
       => (lambda (entry)
            (define line (car entry))
            (define cs
              (for/list ([tok (in-list (cdr entry))] [f (in-list fields)])
                (define v (parse-uint-token who tok "COUNT" line))
                (unless (>= v 1)
                  (pcd-error who "header line ~a: COUNT for field '~a' must be at least 1, got ~a" line f v))
                v))
            (unless (= (length cs) nf)
              (pcd-error who "header line ~a: COUNT has ~a value(s) but FIELDS (line ~a) has ~a field(s)"
                         line (length cs) f-line nf))
            cs)]
      [else (for/list ([f (in-list fields)]) 1)]))

  ;; WIDTH / HEIGHT / POINTS
  (define w-entry (require-keyword who seen 'WIDTH))
  (define width (match-single-uint who w-entry "WIDTH"))
  (define h-entry (require-keyword who seen 'HEIGHT))
  (define height (match-single-uint who h-entry "HEIGHT"))
  (define p-entry (require-keyword who seen 'POINTS))
  (define points-count (match-single-uint who p-entry "POINTS"))
  (unless (= (* width height) points-count)
    (pcd-error who "header line ~a: POINTS ~a does not match WIDTH * HEIGHT = ~a (WIDTH ~a on line ~a, HEIGHT ~a on line ~a)"
               (car p-entry) points-count (* width height)
               width (car w-entry) height (car h-entry)))

  ;; VIEWPOINT (optional, defaults to "0 0 0 1 0 0 0")
  (define viewpoint
    (cond
      [(hash-ref seen 'VIEWPOINT #f)
       => (lambda (entry)
            (define line (car entry))
            (define toks (cdr entry))
            (unless (= (length toks) 7)
              (pcd-error who "header line ~a: VIEWPOINT needs 7 numbers (tx ty tz qw qx qy qz), got ~a"
                         line (length toks)))
            (for/vector #:length 7 ([tok (in-list toks)])
              (define v (string->number tok))
              (unless v
                (pcd-error who "header line ~a: VIEWPOINT value '~a' is not a number" line tok))
              (real->double-flonum v)))]
      [else (vector 0.0 0.0 0.0 1.0 0.0 0.0 0.0)]))

  (values (header fields sizes types counts width height viewpoint
                  points-count data-mode data-line-no)
          (make-column-meta fields sizes types counts)))

(define (match-single-uint who entry what)
  (define line (car entry))
  (define toks (cdr entry))
  (unless (= (length toks) 1)
    (pcd-error who "header line ~a: ~a takes exactly one value, got ~a" line what (length toks)))
  (parse-uint-token who (car toks) what line))

;; ---- header formatting ------------------------------------------------------

(define (format-viewpoint vp)
  (string-join
   (for/list ([v (in-vector vp)]) (ascii-real-string v))
   " "))

;; Renders the complete header (through the DATA line) for the given mode,
;; one of 'ascii, 'binary, 'binary-compressed.
(define (format-header cloud mode)
  (define (nums xs) (string-join (map number->string xs) " "))
  (define mode-str
    (case mode
      [(ascii) "ascii"]
      [(binary) "binary"]
      [(binary-compressed) "binary_compressed"]))
  (string-append
   "# .PCD v0.7 - Point Cloud Data file format\n"
   "VERSION .7\n"
   "FIELDS " (string-join (point-cloud-fields cloud) " ") "\n"
   "SIZE " (nums (point-cloud-sizes cloud)) "\n"
   "TYPE " (string-join (for/list ([t (in-list (point-cloud-types cloud))]) (string t)) " ") "\n"
   "COUNT " (nums (point-cloud-counts cloud)) "\n"
   "WIDTH " (number->string (point-cloud-width cloud)) "\n"
   "HEIGHT " (number->string (point-cloud-height cloud)) "\n"
   "VIEWPOINT " (format-viewpoint (point-cloud-viewpoint cloud)) "\n"
   "POINTS " (number->string (vector-length (point-cloud-points cloud))) "\n"
   "DATA " mode-str "\n"))

(provide (struct-out header)
         parse-header
         format-header)
