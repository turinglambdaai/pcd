#lang racket/base

;; PCD writers: DATA ascii, DATA binary, and DATA binary_compressed.

(require lzf
         racket/string
         pcd/private/cloud
         pcd/private/codec
         pcd/private/header)

(define (pcd-write out cloud #:data [mode 'ascii])
  (display (format-header cloud mode) out)
  (case mode
    [(ascii) (write-ascii-data out cloud)]
    [(binary) (write-binary-data out cloud)]
    [else (write-binary-compressed-data out cloud)])
  (void))

(define (pcd-write-file path cloud #:data [mode 'ascii])
  (call-with-output-file path
    (lambda (out) (pcd-write out cloud #:data mode))
    #:exists 'truncate/replace))

;; ---- ascii -----------------------------------------------------------------

(define (write-ascii-data out cloud)
  (define meta (make-column-meta (point-cloud-fields cloud)
                                 (point-cloud-sizes cloud)
                                 (point-cloud-types cloud)
                                 (point-cloud-counts cloud)))
  (define total (colmeta-total meta))
  (define points (point-cloud-points cloud))
  (for ([p (in-vector points)])
    (display
     (string-join
      (for/list ([j (in-range total)])
        (ascii-value-string (vector-ref p j) (vector-ref (colmeta-vtypes meta) j)))
      " ")
     out)
    (newline out)))

;; ---- binary -------------------------------------------------------------------

(define (write-binary-data out cloud)
  (define meta (make-column-meta (point-cloud-fields cloud)
                                 (point-cloud-sizes cloud)
                                 (point-cloud-types cloud)
                                 (point-cloud-counts cloud)))
  (define points (point-cloud-points cloud))
  (define n (vector-length points))
  (define step (colmeta-step meta))
  (define buf (make-bytes (* step n)))
  (for ([i (in-range n)])
    (define p (vector-ref points i))
    (define base (* i step))
    (for ([j (in-range (colmeta-total meta))])
      (bytes-copy! buf (+ base (vector-ref (colmeta-vbyte-offs meta) j))
                   (encode-value 'pcd-write (vector-ref p j)
                                 (vector-ref (colmeta-vtypes meta) j)
                                 (vector-ref (colmeta-vsizes meta) j))
                   0)))
  (write-bytes buf out))

;; ---- binary_compressed -----------------------------------------------------------

;; Matches PCL's on-disk layout: for each non-padding field, in field order, a
;; little-endian u32 compressed size, a little-endian u32 uncompressed size,
;; then the LZF chunk holding that field's values stored field-major (all
;; values of the field contiguously, in point order). Padding fields (named
;; "_") are omitted from the stream.
(define (write-binary-compressed-data out cloud)
  (define meta (make-column-meta (point-cloud-fields cloud)
                                 (point-cloud-sizes cloud)
                                 (point-cloud-types cloud)
                                 (point-cloud-counts cloud)))
  (define points (point-cloud-points cloud))
  (define n (vector-length points))
  (define step (colmeta-step meta))
  (define nf (colmeta-nfields meta))
  (for ([k (in-range nf)] #:unless (vector-ref (colmeta-fpadding meta) k))
    (define type (vector-ref (colmeta-ftypes meta) k))
    (define size (vector-ref (colmeta-fsizes meta) k))
    (define count (vector-ref (colmeta-fcounts meta) k))
    (define plane (make-bytes (* count size n)))
    (define col0 (vector-ref (colmeta-fcol0 meta) k))
    (for ([i (in-range n)])
      (define p (vector-ref points i))
      (define base (* i count size))
      (for ([e (in-range count)])
        (bytes-copy! plane (+ base (* e size))
                     (encode-value 'pcd-write (vector-ref p (+ col0 e)) type size)
                     0)))
    (define chunk (lzf-compress plane))
    (write-u32-le out (bytes-length chunk))
    (write-u32-le out (bytes-length plane))
    (write-bytes chunk out)))

(provide pcd-write
         pcd-write-file)
