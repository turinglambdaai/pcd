#lang scribble/manual

@(require (for-label racket/base
                     racket/contract/base
                     pcd
                     lzf))

@title[#:tag "pcd"]{PCD: Point Cloud Data Files}
@author{turinglambdaai}

@defmodule[pcd]

This package reads and writes @deftech{PCD} point-cloud files — the native
file format of the @hyperlink["https://pointclouds.org/"]{Point Cloud Library
(PCL)}, version 0.7. All three PCD storage modes are supported:
@litchar{DATA ascii}, @litchar{DATA binary}, and @litchar{DATA
binary_compressed}. The compressed mode uses the LZF algorithm (as PCL does)
and requires the pure-Racket @hyperlink["https://pkgs.racket-lang.org/package/lzf"]{@racketfont{lzf}}
package, a declared runtime dependency.

@section[#:tag "pcd-quickstart"]{Quick start}

@racketblock[
(require pcd)

(define cloud
  (point-cloud
   '("x" "y" "z" "intensity")             ; FIELDS
   '(4 4 4 4)                             ; SIZE
   '(#\F #\F #\F #\F)                     ; TYPE
   '(1 1 1 1)                             ; COUNT
   3 1                                    ; WIDTH, HEIGHT
   (vector 0.0 0.0 0.0 1.0 0.0 0.0 0.0)   ; VIEWPOINT
   (vector (vector 0.5 1.25 -3.75 10.5)
           (vector 1.0 2.0 3.0 -0.5)
           (vector 4.0 5.0 6.0 1.5))))

(pcd-write-file "/tmp/example.pcd" cloud #:data 'binary-compressed)
(define cloud2 (pcd-read-file "/tmp/example.pcd"))
(equal? cloud cloud2)  ; #t — round-trips are exact
]

@section[#:tag "pcd-record"]{The point-cloud record}

@defstruct*[point-cloud
            ([fields (listof string?)]
             [sizes (listof pcd-size/c)]
             [types (listof pcd-type/c)]
             [counts (listof pcd-count/c)]
             [width exact-nonnegative-integer?]
             [height exact-nonnegative-integer?]
             [viewpoint (vectorof flonum?)]
             [points (vectorof (vectorof real?))])]{

A parsed (or to-be-written) PCD file. The constructor validates its
arguments and raises @racket[exn:fail] on malformed clouds, so any
@racket[point-cloud?] value is well-formed. Two clouds with equal field
values are @racket[equal?], so a round-trip yields an @racket[equal?] value.

@itemlist[
 @item{@racket[fields] — the @litchar{FIELDS} names in file order. A field
  named @litchar{"_"} is PCL's padding marker: it occupies space in
  @racket['ascii] and @racket['binary] data and is skipped in
  @racket['binary-compressed] chunks (its values read back as @racket[0],
  exactly like PCL).}
 @item{@racket[sizes] — bytes per field element: @racket[1], @racket[2],
  @racket[4], or @racket[8] (the @litchar{SIZE} line).}
 @item{@racket[types] — one of @racket[#\F] (float), @racket[#\U] (unsigned
  integer), or @racket[#\I] (signed integer) per field (the @litchar{TYPE}
  line). Float fields require size 4 or 8.}
 @item{@racket[counts] — elements per field (the @litchar{COUNT} line). A
  file that omits the line is read as all-1. A field with count @racket[n]
  contributes @racket[n] consecutive elements to every point's value vector.}
 @item{@racket[width], @racket[height] — the @litchar{WIDTH} and
  @litchar{HEIGHT} lines. Organized clouds (@racket[height] greater than 1) are
  supported; @racket[points] is stored @emph{row-major}, with
  @racket[width] consecutive points per row. For unorganized clouds
  @racket[height] is 1. The constraint that @racket[(* width height)] equals
  the number of points is enforced.}
 @item{@racket[viewpoint] — seven flonums: translation @tt{tx ty tz} then
  quaternion @tt{qw qx qy qz}; defaults to @racket[(vector 0.0 0.0 0.0 1.0
  0.0 0.0 0.0)] when a file omits the @litchar{VIEWPOINT} line.}
 @item{@racket[points] — point-major vector; each point is a flat vector of
  every field element in file order (its length is the sum of
  @racket[counts]). Float columns hold flonums; integer columns hold exact
  integers within the range of their size and signedness.}]

@defproc[(pcd-size/c [v any/c]) boolean?]{Recognizes legal SIZE values.}
@defproc[(pcd-type/c [v any/c]) boolean?]{Recognizes legal TYPE values.}
@defproc[(pcd-count/c [v any/c]) boolean?]{Flat contracts for the field
tables: size in @racket['(1 2 4 8)], type in @racket['(#\F #\U #\I)], count
a positive exact integer.}
}

@section[#:tag "pcd-io"]{Reading and writing}

@defproc[(pcd-read [in input-port?]) point-cloud?]{
Reads a PCD file from @racket[in], consuming the header and the entire data
section. Trailing bytes after the data section are ignored (some writers pad
files).}

@defproc[(pcd-read-file [path path-string?]) point-cloud?]{
Opens @racket[path] and @racket[pcd-read]s it.}

@defproc[(pcd-read-bytes [bs bytes?]) point-cloud?]{
Reads a PCD file from a byte string.}

@defproc[(pcd-write [out output-port?] [cloud point-cloud?]
                    [#:data data (or/c 'ascii 'binary 'binary-compressed) 'ascii])
         void?]{
Writes @racket[cloud] to @racket[out] as a PCD v0.7 file with the given
storage mode.}

@defproc[(pcd-write-file [path path-string?] [cloud point-cloud?]
                         [#:data data (or/c 'ascii 'binary 'binary-compressed) 'ascii])
         void?]{
Writes @racket[cloud] to @racket[path] (truncating any existing file).}

@section[#:tag "pcd-formats"]{Data formats}

@subsection[#:tag "pcd-ascii"]{ascii}

One point per line; values separated by spaces or tabs. Float values are
printed so that they read back bit-exactly for float32-representable values;
@litchar{nan}, @litchar{inf}, and @litchar{-inf} follow PCL's conventions
and round-trip.

@subsection[#:tag "pcd-binary"]{binary}

A little-endian array of structures: for each point, every field element in
file order at its @racket[sizes] width. Reading requires
@tt{POINTS × step} bytes and rejects truncated data.

@subsection[#:tag "pcd-compressed"]{binary_compressed}

Matches PCL's on-disk layout: the data is reordered field-major (all values
of the first field, then the second, ...), each field's chunk is LZF
compressed, and for each field — in field order, skipping @litchar{"_"}
padding fields — the file stores a little-endian unsigned 32-bit compressed
size, then an unsigned 32-bit uncompressed size, then the compressed chunk.
The reader validates each field's uncompressed size against
@tt{SIZE × COUNT × POINTS}, de-interleaves the planes back to point-major
order, and decodes values as in the binary format. Truncated or corrupt LZF
chunks raise @racket[exn:fail] naming the field.

@section[#:tag "pcd-errors"]{Errors}

All format errors raise @racket[exn:fail]. Messages name the offending
header line number, field, or point index, e.g. @litchar{header line 3:
unknown TYPE 'Q' for field 'z'}, @litchar{truncated DATA section: needed 12
byte(s) of binary point data, got only 4}, or @litchar{header line 8:
POINTS 5 does not match WIDTH * HEIGHT = 1}.

@section[#:tag "pcd-scope"]{Scope}

This package is a file-format codec for PCD v0.7. It does not re-create
PCL's @tt{pcl::PointCloud} C++ type system, Kd-trees, filters, or readers
for other formats (PLY, STL, OBJ, ...).
