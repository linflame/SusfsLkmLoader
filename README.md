# SUSFS LKM Loader

开机自动加载 susfs 内核模块的 Root 模块，兼容 Magisk / KernelSU / APatch。
ko / 加载器来源：[susfs4ksu-lkm](https://gitee.com/inforcqb/susfs4ksu-lkm)（[GitHub](https://github.com/inforcqb/susfs4ksu-lkm)）

## 双线

| | next | legacy |
|---|---|---|
| 定位 | 自主更新 | 极简安装 |
| 更新方式 | Action 按钮 / WebUI | root管理器更新或重刷 zip |

互刷无需卸载。

## 目录

- `shared/`：两线公共文件（kos/、susfs_insmod、upstream_version、安装与加载脚本）
- `legacy/build/`、`next/build/`：各线专有文件（module.prop；next 另有 action/updater/webui/webroot）
- `modules/`：打包产物与 update.json

## 特性

- 安装时自动识别内核版本
- 便于用户更新
- 日志：`/data/adb/susfs_lkm.log`

## 打包

各线目录下运行 `pack.bat`，产物统一输出到 `modules/`：

- legacy/：查上游，无更新且本地有 zip 则停止，否则打包；有更新则拉取 ko 替换，versionCode 同 tag （`v2.3.0-r18.2 → 230182`），并生成 `modules/update.json`、写 updateJson 进 module.prop
- next/：仅打包本地内容（1.0 / versionCode 1）
