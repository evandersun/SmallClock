# SmallClock（Liquid glass 工作区）

iOS 16 锁屏「小时钟」：把锁屏的大时钟缩成一小行，和日期并排显示。

## 怎么构建
- 工作区用自己的脚本：`apelin-project.json` 里的 `external.script` 指向 `apelin/build.sh`，
  由 `apelin_project_build` 调用（不要直接跑脚本，也不要用 dpkg-deb 自己打包）。
- 编译器用 bootstrap 自带的 clang 14（`shell_run` 的 PATH 上就有），SDK 由 `SDKROOT` 给出；
  这台 A11 的 ld 不接受 arm64e，所以只编 arm64，包里的 `Architecture` 仍是 iphoneos-arm64e。
- 产物：`SmallClock.dylib` + `SmallClock.plist`（过滤器，只注入 com.apple.springboard），
  装到 `/Library/MobileSubstrate/DynamicLibraries/`。
- 包标识目前是占位的 `local.apelin.smallclock`，发布前要和用户确认正式标识。

## 源码
- `Sources/Tweak.m`：全部逻辑。钩子走 `dlsym` 拿到 `MSHookMessageEx`，不直接链接
  libsubstrate，避免 roothide 下的路径问题。
- 日志子系统 = 包标识，启动标记 `ApelinLoaded <build id>` 供 `apelin_package_confirm_loaded` 使用。

## iOS 16.7.15 锁屏结构（实测）
```
SBFLockScreenDateView
  CSProminentDisplayView
    BSUIVibrancyEffectView
      UIView
        CSProminentTimeView            <- 大时钟容器（100pt _UIAnimatingLabel）
        CSProminentSubtitleDateView    <- 日期（22pt _UIAnimatingLabel）
        CSProminentEmptyElementView
```
- 钩 `-[SBFLockScreenDateView layoutSubviews]`，在原实现之后改布局；再留一个 1 秒定时器兜底并刷新时间文本。
- 不要用 transform 缩放系统时间标签：系统每轮布局都会重设它的 frame，bounds 会被放大到爆炸。
  自己的标签更稳。

## 设备上的冲突
- 用户装了 **SystemBoxClockGlass**（`com.wkk.systembox`），它在锁屏时钟位置画玻璃面板
  （`LGClockGlassView` / `LGClockReplacementTimeView`）并隐藏系统时间标签。本插件把这些视图
  强制隐藏，锁屏上只留小时间行。要恢复玻璃时钟就停用本插件，或以后加开关。

## 怎么看效果
- 只有设备真的在锁屏页（CoverSheet 已生成）时才会布局；解锁在首页时看不到、也抓不到。
  可以用 `icli button power` + `icli button wake` 让它停在锁屏。
- 日志：`apelin_log_read`，子系统 `local.apelin.smallclock`。
