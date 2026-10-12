#lang info

(define collection 'multi)
(define version "0.1")
(define deps '("base" "lzf" "rackunit-lib"))
(define build-deps '("scribble-lib" "racket-doc" "rackunit-lib"))
(define pkg-desc "Reader and writer for PCD point-cloud files (Point Cloud Library format v0.7): ascii, binary, and binary_compressed")
(define pkg-authors '("turinglambdaai"))
(define license 'MIT)
(define scribblings '(("pcd/scribblings/pcd.scrbl" ())))
(define test-omit-paths '("pcd/scribblings"))
