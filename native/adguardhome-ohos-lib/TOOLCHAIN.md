# OHOS Go 交叉编译工具链搭建（WSL / Linux）

本文说明如何在 **WSL（或任意 Linux）** 中搭建工具链，把 `third_party/AdGuardHome` 编译成 OpenHarmony 可加载的 `libadguardhome_ohos.so`，供 ArkTS 经 C/C++/NAPI 调用。

> Windows 本机无法直接编译：标准 Go 的 `GOOS` 列表里**没有** `openharmony`（已对照 Go 源码 `internal/platform/supported.go` 确认），必须用 OpenHarmony 维护的 **patched Go 分支** + **OHOS NDK 的 clang**。`scripts/build_ohos_shared.sh` 里的 `GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1 go build -buildmode=c-shared` 正是依赖这套工具链。

## 为什么用 WSL 而不是原生 Windows

技术上原生 Windows 也能交叉编译（Go 的目标平台与宿主无关），但实践上很折腾、且无人验证，**强烈建议用 WSL**：

- **OHOS clang 的 per-target 包装器是 shell 脚本**：DevEco 装的 Windows SDK 里虽然有真的 `clang.exe`（`...\OpenHarmony\Sdk\<api>\native\llvm\bin\clang.exe`），但 `aarch64-unknown-linux-ohos-clang` 这个 cgo 要当 `CC` 用的文件第一行是 `#!/bin/sh`，原生 Windows 跑不了。要在 Windows 用就得直接拿 `clang.exe` 当 CC，再手动补 `--target=aarch64-linux-ohos --sysroot=<sdk>/native/sysroot` 等包装器本来代劳的参数。
- **patched Go fork 面向 Linux**：`ohos_golang_go` 在 Linux 上开发/CI，Windows 上 `make.bat` 自举 + OHOS patch 未经验证，踩坑概率高。
- **AGH/Go 构建的 Unix 习惯**：路径、换行、脚本等在 WSL 下自然满足。

> 注意：Windows SDK 里的 clang 是 **Windows 二进制**，WSL 里用不了——WSL 需要的是 **Linux 版 OHOS NDK**（独立安装）。

---

## ⚠️ 头号坑：Go 版本必须匹配

- `third_party/AdGuardHome`（v0.107.64）的 `go.mod` 要求 **`go 1.24.5`**。
- patched Go 分支 [`openharmony-sig/ohos_golang_go`](https://gitcode.com/openharmony-sig/ohos_golang_go) 的基线 Go 版本**必须 ≥ 1.24.5**，否则 `go build` 会直接报 `go.mod requires go >= 1.24.5`，根本编不了。
- **动手前先确认**：编出 patched Go 后跑 `go version`，比对是否 ≥ `go1.24.5`。
  - 若该 fork 没有 ≥1.24 的分支 → P3 在工具链这一步就被卡住，需要：① 等/找该 fork 的新版本分支；或 ② 把 AdGuardHome 降到一个 `go.mod` 要求较低 Go 版本的旧 tag（改 `scripts/update_third_party_adguardhome.sh` 的 REF）；或 ③ 自己把 OHOS 的移植 patch 套到对应版本的上游 Go 上。

---

## 1. 编译 patched Go（ohos_golang_go）

```bash
# 1) 取 OpenHarmony 的 Go 分支
git clone https://gitcode.com/openharmony-sig/ohos_golang_go.git

# 2) 准备 bootstrap Go（用于自举编译；版本需满足该 fork 的自举要求，1.20.7 起步，
#    若 fork 基线是 1.24 则 bootstrap 需 >= 1.22.6）
wget https://go.dev/dl/go1.22.6.linux-amd64.tar.gz
sudo tar -C /opt -xzf go1.22.6.linux-amd64.tar.gz   # 解到 /opt/go
export GOROOT_BOOTSTRAP=/opt/go

# 3) 自举编译 patched Go
cd ohos_golang_go/src
./make.bash

# 4) 切到这套工具链
export GOROOT="$(cd .. && pwd)"          # = .../ohos_golang_go
export PATH="$GOROOT/bin:$PATH"

# 5) 验证（关键）
go version                                # 必须 >= go1.24.5
go tool dist list | grep openharmony      # 应能看到 openharmony/arm64
```

## 2. 安装 OHOS NDK（提供 CGO 的 C 编译器）

`CGO_ENABLED=1` 需要一个能编 OHOS 目标的 C 编译器，即 NDK 里的 `aarch64-unknown-linux-ohos-clang`。

- 获取 **OpenHarmony SDK（Linux 版）** 的 native 组件，常见来源：
  - DevEco 的 SDK Manager / 命令行 `ohsdkmgr`；或
  - 直接下 OpenHarmony 发行版里的 `ohos-sdk`（取其中 `native` 目录）。
- 关注 SDK 版本：与应用工程一致即可（本工程目标 `HarmonyOS 6.1.0(23)` / OpenHarmony API 对应版本）。
- clang 位置（示例，随 SDK 版本略有差异）：
  ```
  <ohos-sdk>/native/llvm/bin/aarch64-unknown-linux-ohos-clang
  <ohos-sdk>/native/llvm/bin/aarch64-unknown-linux-ohos-clang++
  <ohos-sdk>/native/llvm/bin/llvm-ar
  ```

## 3. 配置构建环境变量

```bash
export OHOS_NDK=/path/to/ohos-sdk/native           # 改成你的实际路径
export CC="$OHOS_NDK/llvm/bin/aarch64-unknown-linux-ohos-clang"
export CXX="$OHOS_NDK/llvm/bin/aarch64-unknown-linux-ohos-clang++"
export AR="$OHOS_NDK/llvm/bin/llvm-ar"
export GOOS=openharmony
export GOARCH=arm64
export CGO_ENABLED=1
```

## 4. 检出 AdGuardHome 子模块

```bash
# 在仓库根目录
git submodule update --init --recursive
# 固定到匹配版本（脚本默认 v0.107.64）
./native/adguardhome-ohos-lib/scripts/update_third_party_adguardhome.sh v0.107.64
```

## 5. 构建 .so 并安装到应用工程

> **可选：内置 AdGuardHome web 管理面板。** 完整模式的 web 管理端从 `build/static` 提供（main.go 的 `//go:embed build`）。这是生成产物,需先用 Node 编一次前端(产物落到 submodule 的 `build/static`,会被 so 嵌入,so 体积约 +9.5MB):
>
> ```bash
> cd native/adguardhome-ohos-lib/third_party/AdGuardHome/client
> npm ci && npm run build-prod
> ```
>
> 不编也能构建出可用的 DNS 过滤 so,只是 `127.0.0.1:3000` 管理面板会 404。Node 可用 Windows 版(前端是跨平台 JS 工具链);Go 的 so 仍在 WSL 编。

```bash
./native/adguardhome-ohos-lib/scripts/build_ohos_shared.sh --app-root /path/to/home-cloud-shield
```

成功后产物：

- `native/adguardhome-ohos-lib/ohos/prebuilt/openharmony-arm64/libadguardhome_ohos.so`
- 同目录 `libadguardhome_ohos.h`
- 若带 `--app-root`，会复制到：
  - `entry/src/main/libs/arm64-v8a/libadguardhome_ohos.so`
  - `entry/src/main/cpp/include/libadguardhome_ohos.h`

---

## Go 导出层（已实现）

导出层源码已落在本仓库、随主仓库一起分发，**不放进 submodule**（保持上游子模块为纯净 `v0.107.64`），构建时由脚本临时注入：

- `ohos/embed/main_ohos_c_shared.go`：`package main`、`//go:build ohos_c_shared` 的 cgo 导出层。构建时复制到 AGH 模块根（与上游 `main.go` 并存，不重复定义 `func main`，复用 `main.go` 里的 `clientBuildFS`）。
- `ohos/embed/embed_ohos.go`：`package home`、`//go:build ohos_c_shared`，为 `internal/home` 增加可嵌入入口 `StartEmbedded`/`StopEmbedded`。构建时复制到 `internal/home/`。

`build_ohos_shared.sh` 会在 `go build` 前把这两个文件复制进 submodule，构建结束（含失败）再用 `trap` 删除，使 submodule 工作树保持干净。

### 导出的 C ABI（与 `libadguardhome_ohos.h` 一致）

```c
char* AdGuardHomeVersion();
char* AdGuardHomeStart(char* configPath, char* workDir, char* logPath);
char* AdGuardHomeStop();
void  AdGuardHomeFreeCString(char* str);
```

- `AdGuardHomeStart` 成功返回空串、失败返回错误信息串；所有返回的 `char*` 由调用方用 `AdGuardHomeFreeCString` 释放。
- `StartEmbedded` 是 `home.run`（见 `internal/home/home.go`）的「库化」镜像：用错误返回代替 `fatalOnError`/`os.Exit`（坏配置不会杀宿主进程），不安装 OS 信号处理，把阻塞的 `web.start` 放到后台 goroutine，启动完所有 server 后返回。**升级 AGH submodule 版本时需同步核对 `home.run` 的变化。**

### 集成模型（建议）

完整模式下 `.so` 按 `AdGuardHome.yaml` 在本地起完整 AGH（DNS + web 管理端 + querylog/stats，可按需在 yaml 关 DHCP / 收紧端口）；C++ 把 TUN 的 DNS 包转发到 AGH 绑定的本地端口（复用现有上游转发逻辑，关掉 C++ 自身匹配）。

> ⚠️ 由调用方生成的 `AdGuardHome.yaml` 必须把 DNS 与 HTTP 都绑到**空闲、非特权的回环端口**：宿主 app 无 root 绑不了 53，且 AGH 的 web server 绑定失败会直接终止进程。

### 本机已验证的工具链位置（仅供参考）

- patched Go：`/home/tlntin/frp_ohos/ohos_golang_go`（`go1.24.5`，`go tool dist list` 含 `openharmony/arm64`）
- OHOS NDK：`/home/tlntin/frp_ohos/command-line-tools/sdk/default/openharmony/native`（设为 `OHOS_NDK`，脚本据此推导 `CC/CXX/AR`）

---

## 参考

- patched Go：<https://gitcode.com/openharmony-sig/ohos_golang_go>
- 鸿蒙引入 Golang SO 库（含完整配方与 DevEco 集成）：<https://blog.csdn.net/weixin_44517645/article/details/148105102>
- Go 官方 GOOS 列表（确认无 openharmony）：<https://go.dev/src/internal/platform/supported.go>
