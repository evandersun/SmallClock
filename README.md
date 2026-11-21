# SmallClock

把 iOS 锁屏的大时钟缩成一小行，直接放进日期栏：左边是时间，右边是日期，整行居中。

- 适用：iOS 16（在 iPhone X / iOS 16.7.15 上开发与测试），二进制同时带 arm64 与 arm64e 切片
- 注入：SpringBoard（`com.apple.springboard`）
- 包标识：`com.evander.smallclock`
- 设置：设置 App 里的 **SmallClock** 一页，一个「小时间」开关

## 做了什么

iOS 16 的锁屏头部来自 `SBFLockScreenDateView`：`CSProminentTimeView` 里一个 100pt 的时间标签，
`CSProminentSubtitleDateView` 里 22pt 的日期标签，两处都经过 `BSUIVibrancyEffectView` 渲染。

本插件隐藏这两个系统标签（连大时钟一起），读出系统给出的日期文本，再用两个自己的 `UILabel`
排成一行：时间在最左，日期紧随其后，宽度不够时按比例缩小字号。

设备上若装了 **SystemBoxClockGlass**（`com.wkk.systembox`）的玻璃锁屏时钟，它画的
`LGClockGlassView` / `LGClockReplacementTimeView` 会被强制隐藏——大玻璃面板和小时间行没法共存。

## 开关

设置 App ▸ SmallClock ▸ 小时间：打开是小数时间行，关闭立即把系统原来的大时钟交还回去，不用注销。

开关值写在 `/var/mobile/Library/Preferences/com.evander.smallclock.plist` 的 `enabled` 键。
iOS 16 上设置 App 通过 cfprefsd 写这个域会被丢掉，所以设置页自己把 plist 文件写出来，
插件也优先读这个文件。

## 构建

工作区用自己的构建脚本，由 Apelin 的 `apelin_project_build` 调用：

```sh
apelin/build.sh   # 由 apelin_project_build 运行，不要直接执行
```

脚本用 bootstrap 自带的 clang 编译 `Sources/Tweak.m`（只出 arm64）、`ldid` 签名，
再把 dylib 和过滤器 `SmallClock.plist` 打进 `.deb`。

## 安装

```sh
# 通过 Apelin 或系统包管理器安装构建出的 .deb
# 之后 respring（或重启 SpringBoard）生效
```

## 文件

```
Sources/Tweak.m       钩子与布局逻辑
apelin/build.sh       构建脚本
apelin/SmallClock.plist  注入过滤器
AGENTS.md             构建与调试笔记（锁屏结构、踩过的坑）
```
