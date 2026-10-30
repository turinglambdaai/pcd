#lang racket/base
;; Self-contained PCD v0.7 quickstart: validates all three storage encodings.
;; Uses only memory ports, synthetic point values and the declared lzf dependency.
(require racket/port
         pcd)

(define cloud
  (point-cloud
   '("x" "y" "z" "intensity")
   '(4 4 4 4)
   '(#\F #\F #\F #\F)
   '(1 1 1 1)
   3 1
   (vector 0.0 0.0 0.0 1.0 0.0 0.0 0.0)
   (vector (vector 0.5 1.25 -3.75 10.5)
           (vector 1.0 2.0 3.0 -0.5)
           (vector 4.0 5.0 6.0 1.5))))

(for ([mode (in-list '(ascii binary binary-compressed))])
  (define encoded
    (call-with-output-bytes
     (lambda (port)
       (pcd-write port cloud #:data mode))))
  (define decoded (pcd-read-bytes encoded))
  (unless (equal? decoded cloud)
    (error 'pcd-quickstart "~a round-trip mismatch" mode))
  (unless (equal? (point-cloud-fields decoded) '("x" "y" "z" "intensity"))
    (error 'pcd-quickstart "~a lost the field table" mode))
  (unless (= (point-cloud-width decoded) 3)
    (error 'pcd-quickstart "~a lost the point count" mode)))

(displayln "PCD quickstart OK: ascii / binary / binary_compressed")
