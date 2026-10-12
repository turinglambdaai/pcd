#lang racket/base

;; Core point-cloud record and shared field type/size tables.
;;
;; The `point-cloud` struct is the package's single representation of a PCD
;; file. Validation and normalization live in the struct guard so that any
;; successfully constructed value is a well-formed cloud:
;;
;;   - `fields`  names of the PCD FIELDS, in file order
;;   - `sizes`   bytes per field element: 1, 2, 4, or 8
;;   - `types`   one of #\F (float), #\U (unsigned), #\I (signed) per field
;;   - `counts`  elements per field (the PCD COUNT line), each >= 1
;;   - `width`   WIDTH line: points-per-row for organized clouds, total
;;               point count for unorganized clouds (HEIGHT 1)
;;   - `height`  HEIGHT line: number of rows
;;   - `viewpoint` translation + quaternion (tx ty tz qw qx qy qz) as
;;               flonums
;;   - `points`  point-major vector; each point is a flat vector holding
;;               every field element in file order, COUNT elements per
;;               field (so its length is (sum of counts)). 'F' columns hold
;;               flonums, 'U'/'I' columns hold exact integers.

(require racket/contract/base)

;; ---- flat contracts ----------------------------------------------------

;; Not provided by racket/base in this distribution; defined here so the
;; struct and its contracts need no extra dependency.
(define (exact-nonneg-integer? v) (and (exact-integer? v) (>= v 0)))

(define (pcd-size/c v) (and (exact-integer? v) (memq v '(1 2 4 8)) #t))
(define (pcd-type/c v) (and (char? v) (memq v '(#\F #\U #\I)) #t))
(define (pcd-count/c v) (and (exact-integer? v) (>= v 1) #t))

;; ---- guard -------------------------------------------------------------

(define (point-cloud-guard fields sizes types counts width height viewpoint points name)
  (define (fail fmt . args)
    (apply error 'point-cloud fmt args))

  (unless (and (list? fields) (andmap string? fields))
    (fail "expected a list of field-name strings for `fields`, got: ~a" fields))
  (define nf (length fields))

  (unless (list? sizes)
    (fail "expected a list for `sizes`, got: ~a" sizes))
  (unless (list? types)
    (fail "expected a list for `types`, got: ~a" types))
  (unless (list? counts)
    (fail "expected a list for `counts`, got: ~a" counts))
  (unless (= (length sizes) nf)
    (fail "`sizes` has ~a element(s) but `fields` has ~a" (length sizes) nf))
  (unless (= (length types) nf)
    (fail "`types` has ~a element(s) but `fields` has ~a" (length types) nf))
  (unless (= (length counts) nf)
    (fail "`counts` has ~a element(s) but `fields` has ~a" (length counts) nf))

  ;; Normalize types: accept chars or single-character strings, store chars.
  (define norm-types
    (for/list ([t (in-list types)] [f (in-list fields)])
      (define c
        (cond
          [(char? t) t]
          [(and (string? t) (= (string-length t) 1) (string-ref t 0))]
          [else (fail "field '~a': TYPE must be #\\F, #\\U, or #\\I (or \"F\", \"U\", \"I\"), got: ~a" f t)]))
      (unless (memq c '(#\F #\U #\I))
        (fail "field '~a': unknown TYPE '~a' (expected F, U, or I)" f c))
      c))
  (for ([s (in-list sizes)] [f (in-list fields)])
    (unless (pcd-size/c s)
      (fail "field '~a': SIZE must be 1, 2, 4, or 8, got: ~a" f s)))
  (for ([t (in-list norm-types)] [s (in-list sizes)] [f (in-list fields)])
    (when (and (char=? t #\F) (not (or (= s 4) (= s 8))))
      (fail "field '~a': TYPE F requires SIZE 4 or 8, got: ~a" f s)))
  (for ([c (in-list counts)] [f (in-list fields)])
    (unless (pcd-count/c c)
      (fail "field '~a': COUNT must be a positive integer, got: ~a" f c)))

  (unless (exact-nonneg-integer? width)
    (fail "`width` must be an exact nonnegative integer, got: ~a" width))
  (unless (exact-nonneg-integer? height)
    (fail "`height` must be an exact nonnegative integer, got: ~a" height))

  (unless (and (vector? viewpoint)
               (= (vector-length viewpoint) 7)
               (andmap real? (vector->list viewpoint)))
    (fail "`viewpoint` must be a vector of 7 real numbers (tx ty tz qw qx qy qz), got: ~a" viewpoint))
  (define vp (for/vector #:length 7 ([v (in-vector viewpoint)]) (real->double-flonum v)))

  ;; Per-value metadata: what type/size/name governs each element of a point.
  (define total (for/sum ([c (in-list counts)]) c))
  (define vtypes (make-vector total #\F))
  (define vsizes (make-vector total 4))
  (define vfields (make-vector total 0))          ; field index per value
  (let loop ([j 0] [k 0])
    (when (< k nf)
      (define c (list-ref counts k))
      (for ([e (in-range c)])
        (vector-set! vtypes (+ j e) (list-ref norm-types k))
        (vector-set! vsizes (+ j e) (list-ref sizes k))
        (vector-set! vfields (+ j e) k))
      (loop (+ j c) (add1 k))))

  (unless (vector? points)
    (fail "`points` must be a vector of per-point vectors, got: ~a" points))
  (define np (vector-length points))
  (for ([i (in-range np)])
    (define p (vector-ref points i))
    (unless (vector? p)
      (fail "point ~a: expected a vector of field values, got: ~a" i p))
    (unless (= (vector-length p) total)
      (fail "point ~a: expected ~a value(s) per point (every field element, honoring COUNT), got ~a"
            i total (vector-length p)))
    (for ([j (in-range total)])
      (define v (vector-ref p j))
      (define t (vector-ref vtypes j))
      (define f (list-ref fields (vector-ref vfields j)))
      (cond
        [(char=? t #\F)
         (unless (real? v)
           (fail "point ~a, field '~a': expected a real number for a float field, got: ~a" i f v))]
        [else
         (unless (exact-integer? v)
           (fail "point ~a, field '~a': expected an exact integer for an integer field, got: ~a" i f v))
         (define s (vector-ref vsizes j))
         (define limit (arithmetic-shift 1 (* 8 s)))
         (if (char=? t #\U)
             (unless (and (>= v 0) (< v limit))
               (fail "point ~a, field '~a': value ~a out of range for unsigned SIZE ~a" i f v s))
             (unless (and (>= v (- limit)) (< v (sub1 limit)))
               (fail "point ~a, field '~a': value ~a out of range for signed SIZE ~a" i f v s)))])))

  (unless (= (* width height) np)
    (fail "WIDTH * HEIGHT = ~a does not match the number of points, ~a" (* width height) np))

  (values fields sizes norm-types counts width height vp points))

;; #:transparent so that point clouds compare structurally with equal? —
;; round-tripping a file yields an equal? value.
(struct point-cloud (fields sizes types counts width height viewpoint points)
  #:transparent
  #:guard point-cloud-guard)

;; ---- derived quantities -------------------------------------------------

(define (values-per-point cloud)
  (for/sum ([c (in-list (point-cloud-counts cloud))]) c))

(define (point-byte-size cloud)
  (for/sum ([c (in-list (point-cloud-counts cloud))]
            [s (in-list (point-cloud-sizes cloud))])
    (* c s)))

;; The raw struct (guard-validated) is provided here for the package's own
;; modules; the contracted public boundary is built in `pcd/main.rkt` with
;; contract-out.
(provide (struct-out point-cloud)
         pcd-size/c
         pcd-type/c
         pcd-count/c
         exact-nonneg-integer?
         values-per-point
         point-byte-size)
