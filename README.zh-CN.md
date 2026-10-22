# pcd

[English](README.md) · **中文**

[![CI](https://github.com/turinglambdaai/pcd/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/pcd/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

一个用于 **PCD 点云文件** 的纯 Racket 读写器。PCD 是 [Point Cloud Library (PCL)](https://pointclouds.org/) 的原生文件格式，此处支持 0.7 版。它支持全部三种 PCD 存储模式的读写：`DATA ascii`、`DATA binary` 和 `DATA binary_compressed`。

## 安装

```
raco pkg install pcd
```

## 示例

```racket
(require pcd)

(define cloud
  (point-cloud
   '("x" "y" "z" "intensity")     ; FIELDS
   '(4 4 4 4)                     ; SIZE (bytes per element)
   '(#\F #\F #\F #\F)             ; TYPE
   '(1 1 1 1)                     ; COUNT
   3 1                            ; WIDTH, HEIGHT
   (vector 0.0 0.0 0.0 1.0 0.0 0.0 0.0)  ; VIEWPOINT
   (vector (vector 0.5 1.25 -3.75 10.5)
           (vector 1.0 2.0 3.0 -0.5)
           (vector 4.0 5.0 6.0 1.5))))

(pcd-write-file "/tmp/example.pcd" cloud #:data 'binary-compressed)
(define cloud2 (pcd-read-file "/tmp/example.pcd"))
```

读取任意 PCD 文件（无论之前是否调用过 `pcd-write`）：

```racket
(define c (pcd-read-file "table_scene_lms400.pcd"))
(point-cloud-fields c)   ; '("x" "y" "z" "intensity")
(point-cloud-points c)   ; point-major vector of value vectors
```

## point-cloud 结构体

`point-cloud` 保存头字段和数据：

- `fields` — `(listof string?)`，按文件顺序排列的 `FIELDS` 名称
- `sizes` — 每个字段元素的字节数：`1`、`2`、`4` 或 `8`
- `types` — 每个字段的类型：`#\F`（float）、`#\U`（unsigned）或 `#\I`（signed）
- `counts` — 每个字段的元素数，对应 `COUNT` 行（文件省略该行时默认为 1）
- `width`、`height` — 对应 `WIDTH` 和 `HEIGHT` 行。支持有组织的点云（`HEIGHT` > 1）；`points` 按**行优先**存储（每行 `WIDTH` 个连续点）
- `viewpoint` — 7 个浮点数：先平移量 `tx ty tz`，后四元数 `qw qx qy qz`
- `points` — 点优先的 `(vectorof (vectorof real?))`；每个点是一个扁平向量，按文件顺序保存所有字段元素，每个字段 `COUNT` 个元素。`'F'` 列保存浮点数；`'U'`/`'I'` 列保存精确整数。

## 范围说明

- 针对 PCD **0.7 版**（当前的 PCL 格式）。
- `binary` 与 `binary_compressed` 载荷采用小端序，与 PCL 一致。
- `binary_compressed` 支持依赖纯 Racket 的 [`lzf`](https://pkgs.racket-lang.org/package/lzf) 包（即 PCL 使用的 LZF 编解码器），已声明为运行时依赖。
- 支持 `COUNT` > 1 的字段（n 维描述子）：字段的各元素被展平存入每个点值向量的连续位置。
- 名为 `_` 的字段（PCL 的填充标记）在 `ascii`/`binary` 数据中占据空间，在 `binary_compressed` 块中被跳过——读取时其值为 `0`，与 PCL 的行为完全一致。
- 读写往返时遵循 PCL 的 NaN/inf 约定（ascii 数据中的 `nan`、`inf`、`-inf`；二进制数据中的原始位模式）。
- 本包仅为文件格式编解码器——不重新实现 PCL 的 `pcl::PointCloud` 类型系统、Kd-树、滤波器或其他格式的 I/O。
