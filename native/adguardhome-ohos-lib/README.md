# adguardhome-ohos-lib

将上游 `AdGuardHome` 适配为 OpenHarmony 可加载的 `.so`，供 ArkTS 通过 C/C++/NAPI bridge 调用。

当前该目录随主仓库一起分发，其中上游 `AdGuardHome` 以 git submodule 方式接入，便于固定版本并避免重复拷贝源码。

## 目录结构

```text
native/adguardhome-ohos-lib/
├── scripts/
└── third_party/
    └── AdGuardHome/
```

## 当前状态

- `third_party/AdGuardHome/`：以 git submodule 方式接入的上游源码，当前固定为 `v0.107.64`。
- `scripts/build_ohos_shared.sh`：构建 `.so` 并可复制到应用工程。
- `scripts/update_third_party_adguardhome.sh`：切换上游版本。

## 获取源码

若首次拉取主仓库，请一并初始化子模块：

```bash
git submodule update --init --recursive
```

否则 `third_party/AdGuardHome/` 会为空目录，构建与版本切换脚本都无法正常工作。

## 构建

```bash
./scripts/build_ohos_shared.sh --app-root /path/to/home_cloud_shield
```

会尝试输出到：

- `ohos/prebuilt/openharmony-arm64/libadguardhome_ohos.so`
- `ohos/prebuilt/openharmony-arm64/libadguardhome_ohos.h`

并在指定 `--app-root` 时复制到应用工程。

## 许可证说明

上游 `AdGuardHome` 采用 `GPL-3.0`。本目录中的移植与修改部分随主仓库一起按 GPL 条件分发。

如以源码包形式重新分发本项目，请确保同时提供子模块内容，或提供可复现的子模块提交与拉取说明。
