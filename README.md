# 键盘小屏时钟 · 静默对时

> Silent, scheduled clock sync for 258A-family mechanical keyboards with a small screen.
> Each day the OEM config app is launched for a few seconds on a **private, invisible
> desktop**, so the keyboard receives host time without any splash window, taskbar entry
> or focus stealing. Windows 10/11, PowerShell 5.1, **no admin rights** required.

给「带小屏幕、能显示时间」的机械键盘用的自动对时小工具。

## 它解决什么问题

这类键盘（258A 方案，厂商软件是 GeGe / RK / Sparrow 这一套 OEM 工具）的屏幕时钟有两个通病：

1. **只有打开厂商软件时才同步时间**，平时靠键盘自己的 RTC 走，越走越偏。
2. **厂商软件每次启动都有启动屏**，会闪一下、还抢焦点，烦人。

所以大多数人干脆不开它，时间就一直错着。

本工具的做法：**每天定时把厂商软件在一个看不见的桌面上唤起几秒，让它把时间写进键盘，然后立刻关掉。** 你不需要点任何东西，屏幕上也不会出现任何窗口。

## 前置条件

- 已经装了这把键盘的**厂商驱动**（就是那个能正常打开、能对上时间的小程序）。
  本工具不替代它，只负责"在正确的时间、不打扰你的情况下把它叫起来"。
- Windows 10 / 11，自带 PowerShell 5.1 即可，**不需要管理员权限**。

## 用法

| 操作 | 做法 |
|---|---|
| 安装 | 双击 `install.cmd` |
| 卸载 | 双击 `uninstall.cmd` |
| 只看检测结果、不改系统 | `install.cmd -DetectOnly` |
| 换时间（默认 04:00） | `install.cmd -At 03:30` |
| 装完先别测试 | `install.cmd -NoTest` |
| 自动找不到程序 | `install.cmd -ExePath "D:\xxx\DeviceDriver.exe"` |

安装过程会打印三行：识别到的设备、找到的厂商程序、注册的计划任务。

## 怎么确认它在工作

看同目录的 `sync.log`：

```
2026-11-14 02:27:48  OK up=5.1s leaked_windows=0
```

- `OK` = 已对时并正常退出
- `up=5.1s` = 厂商程序存活了 5.1 秒
- `leaked_windows=0` = **本次运行在你的桌面上出现过的窗口数**。
  这个值由脚本自己统计，恒为 0 才说明真的没有闪屏。

如果某天显示 `SKIP`，说明键盘没插/休眠，或厂商软件已经开着，跳过是正常行为。

## 它是怎么做到不闪屏的

`SW_HIDE` 对启动屏无效——启动屏是独立窗口，程序自己会 `ShowWindow`。所以本工具不是"藏窗口"，而是：

1. 用 `CreateDesktop` 建一个**私有桌面**；
2. 用 `CreateProcess` 的 `lpDesktop` 让厂商程序整个跑在那个桌面上；
3. 启动屏、主窗口、任何对话框都画在那个桌面里，永远不会出现在你的屏幕上，也不会抢焦点；
4. 发 `WM_CLOSE` 让它正常退出，销毁桌面。

## 它是怎么找到你那把键盘的

- 按 **VID** 识别设备（默认 `258A`，这类方案通用）；
- 按厂商程序目录里 `Cfg.ini` 的 `VID=` 反查是哪套 OEM 软件，**不依赖文件夹名字**（所以 GeGe、RK、Sparrow 等各种马甲都能认）；
- 读 `Dev\<PID>\KB.ini` 判断该机型是否 `SendTimeOnOpenKB=1`，也就是"打开即对时"。

## 常见问题

**检测不到设备**
接收器没插、键盘休眠了，或者用的是另一套芯片方案（不是 258A）。

**找到了设备但找不到程序**
厂商软件装在非标准位置，用 `-ExePath` 指过去；或者你还没装驱动。

**装完时间还是不对**
说明你这把键盘不是"打开程序就对时"。看安装时打印的 `time-on-open` 那一行，如果是 `NOT found`，这条路走不通，需要另想办法（可以反馈给我）。

**公司电脑不让建计划任务**
`schtasks` 会被组策略拦。可以让 IT 放行，或改用"启动"文件夹手动放一个快捷方式（但就只能在开机时对时）。

**杀毒软件报警**
脚本会创建隐藏窗口、启动别的程序、注册计划任务，行为上确实像"可疑"。全部源码都在目录里，可自行审阅，都是明文 PowerShell。

**会不会被误触发、把我厂商软件的设置改掉**
厂商程序打开时会应用它自己缓存里的设置（`ApplyNow=1`）。如果你发现灯效被改回某个状态，那是厂商程序的行为，不是本工具额外做了什么。
