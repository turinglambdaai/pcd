# AGENTS.md

PCD 点云文件（PCL 原生格式）的纯 Racket 读写（MIT）。

## 结构

Multi-collection 包：collection 即 `pcd/` 子目录，scribblings 声明在 `pcd/info.rkt`（collection 级）。

## 常用命令

```bash
raco pkg install --auto --link "$(pwd)"
raco test -p pcd
```

## 验证与发版

- CI（`ci.yml`）：即上面两条命令，三平台跑。
- 发版 = tag `v<版本>` + CHANGELOG 同步；catalog 侧为手动提交（pkgd）。

## 仓库特定规矩

- 依赖 `lzf` 包（PCD binary_compressed 段解压用）。
