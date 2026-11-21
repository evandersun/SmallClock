# SmallClock（Liquid glass 工作区）

iOS 16 锁屏「小时钟」：把锁屏的大时钟缩成一小行，和日期并排显示。

## 怎么构建
- 工作区用自己的脚本：`apelin-project.json` 里的 `external.script` 指向 `apelin/build.sh`，
  由 `apelin_project_build` 调用（不要直接跑脚本，也不要用 dpkg-deb 自己打包）。
- 编译器用 bootstrap 自带的 clang 14（`shell_run` 的 PATH 上就有），SDK 由 `SDKROOT` 给出；
  这台 A11 的 ld 不接受 arm64e，所以只编 arm64，包里的 `Architecture` 仍是 iphoneos-arm64e。
- 产物：`SmallClock.dylib` + `SmallClock.plist`（过滤器，只注入 com.apple.springboard），
  装到 `/Library/MobileSubstrate/DynamicLibraries/`。
- 包标识 `com.evander.smallclock`（作者 evander）。

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
- 系统的时间/日期标签都不能直接改：SpringBoard 每轮布局会把它们拉回原位并居中，而且可见画面是
  `BSUIVibrancyAnimatingPortalView` 那条链路渲染的，改 frame 不生效（实测：日期原地不动，时间压在上面）。
  做法是把两个系统标签都隐藏，读走系统给的日期文本，自己画两个 UILabel：**时间在左、日期在右**，
  整行居中；放不下时按比例缩字号（最小 13）。
- 日志只留开关状态变化两行（`enabled: small row applied` / `disabled: system clock restored`）。

## 设置面板
- `Sources/Prefs.m` + `Resources/Root.plist` → `/Library/PreferenceBundles/SmallClockPrefs.bundle`，
  入口 `/Library/PreferenceLoader/Preferences/SmallClock.plist`，三个开关：`enabled`、`lunar`、`battery`。
- 坑：设置 App 通过 cfprefsd 写 `com.evander.smallclock` 域在 iOS 16 上会被丢掉（域文件根本没生成，
  重启设置后开关又变回默认）。所以 `setPreferenceValue:specifier:` 里直接把
  `/var/mobile/Library/Preferences/com.evander.smallclock.plist` 写出来，插件优先读这个文件。
- 面板地址：`prefs:root=SmallClock` 可以直接打开。
- arm64e 切片：本机 ld 对 arm64e 会报 “incompatible arm64e ABI compiler” 警告，但仍能产出切片，
  包里 arm64 与 arm64e 都带（本机 A11 用 arm64，其它设备用 arm64e；arm64e 切片未在真机验证过）。

## 设备上的冲突
- 用户装了 **SystemBoxClockGlass**（`com.wkk.systembox`），它在锁屏时钟位置画玻璃面板
  （`LGClockGlassView` / `LGClockReplacementTimeView`）并隐藏系统时间标签。本插件把这些视图
  强制隐藏，锁屏上只留小时间行。要恢复玻璃时钟就停用本插件，或以后加开关。
- 充电时系统会在头部画一段灰色“电量 N%”，它不是 `SBFLockScreenDateView` 里的 UILabel
  （遍历所有窗口也找不到），最后是靠整块隐藏 `CSProminentDisplayView` 才消失的。

## 怎么看效果
- 只有设备真的在锁屏页（CoverSheet 已生成）时才会布局；解锁在首页时看不到、也抓不到。
  可以用 `icli button power` + `icli button wake` 让它停在锁屏。
- 日志：`apelin_log_read`，子系统 `local.apelin.smallclock`。
