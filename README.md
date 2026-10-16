# WXReply —— 微信自动回复

**只有一个功能：自动回复。** 没有悬浮窗，设置入口就在微信自己的「我 → 设置」里。

- 目标环境：iPhone（A12 及以上）· iOS 15.4.1 · TrollStore + TrollFools 注入 dylib（不需要越狱）
- 也提供了越狱用的 `control` / `layout` / `Makefile`（Dopamine rootless 之类）
- 纯 Objective-C runtime 方法交换，**不链接 CydiaSubstrate/ElleKit**，所以能在未越狱的 TrollFools 下加载

---

## 1. 它做什么

收到**文本**消息时，按这个顺序决定回复内容：

1. **关键词规则**（设置里一行一条，格式 `关键词 => 回复内容`）
2. 没命中就用 **默认回复**
3. 如果打开了 **AI 回复** 且填好了接口/Key/模型 → 改为让模型生成（规则和默认回复都不再用）

外加三个过滤条件：**只回私聊**、**群里仅在 @我 时回复**、**同会话冷却秒数**。

总开关默认是**关**的 —— 装上不会立刻乱回，先去设置里打开。

## 2. 它不做什么

- 没有悬浮窗、没有防撤回、不碰微信其它任何行为
- 不内置、不破解任何账号或授权；AI 用的是**你自己的**接口和 Key
- 除了你自己配置的 AI 接口，不向任何第三方发送数据（日志默认不记消息正文）

## 3. 安装

**TrollStore + TrollFools（推荐）**

1. 从 CI 产物下载 `WXReply.dylib`（或 `WXReply.zip`）
2. 打开 TrollFools → 选「微信」→ 注入这个 dylib
3. **从后台卡片彻底退出微信**，再重新打开
4. 首次打开会弹一次「WXReply 已加载」——这就是"注入成功"的信号

> 如果连这个弹窗都没有，说明 dylib 没被加载（包加密 / 签名问题），先解决注入，再谈功能。

**越狱（rootless）**：把 `WXReply.dylib` 放到 `/var/jb/Library/MobileSubstrate/DynamicLibraries/`，或用 Theos `make package`。

## 4. 打开设置的两条路

| 入口 | 说明 |
|---|---|
| 微信「我 → 设置」顶部的一行「自动回复」 | 主入口，右边会显示当前状态（未开启 / 规则回复 / AI 回复） |
| **长按底部标签栏 1 秒** | 兜底入口。万一微信某个版本改了设置页类名，你仍然进得去设置 |

## 5. 设置项

| 分组 | 项目 |
|---|---|
| 自动回复 | 总开关 · 只回私聊 · 群里仅在 @我 时回复 · 同会话冷却（秒） |
| 回复内容 | 默认回复 · 关键词规则（一行一条 `关键词 => 回复`） |
| AI 回复（可选） | 开关 · 接口地址（OpenAI 兼容，如 `https://api.deepseek.com/v1`）· API Key · 模型名 · 系统提示词 · 最大字数 · 温度 · 上下文条数 · 测试连接 |
| 入口与诊断 | 长按标签栏开关 · 运行状态 · 查看日志 · 诊断报告（含候选名） · 清空冷却 · 详细日志 · 日志记录消息正文 · 候选名覆盖 · 重置配置 |

## 6. 适配你的微信版本（重要，先看这段）

微信没有公开 API，它的内部类名/方法名**每个大版本都可能变**。本插件靠一个"新消息回调"工作，默认会依次尝试一批候选名：

- 消息服务类：`CMessageMgr` / `MessageService` / `MessageMgr` …
- 回调 selector：`AsyncOnAddMsg:MsgWrap:` / `OnAddMsg:MsgWrap:` / `onAddMsg:MsgWrap:` / `AddMsg:MsgWrap:` / `…Ext:` …
- 字段名：`m_nsContent` / `m_uiMessageType` / `m_nsFromUsr` / `m_nsToUsr` / `m_nsMsgSource` …

**全都没挂上时不会崩，只是不回复。** 这时：

1. 打开 设置 → 诊断报告（含候选名），把内容发回来；
2. 或者自己填 设置 → 候选名覆盖，格式：

```
incoming=真实回调Selector
msgclass=真实消息服务类名
content=真实正文字段名
```

支持的键：`servicecenter` `servicecenterinit` `msgclass` `incoming` `sendmsg` `sendtext` `contactclass` `content` `type` `from` `to` `svrid` `localid` `msgsource`（详见 [docs/HOOKS.md](docs/HOOKS.md)）。
**改完不用重新编译，也不用重新注入**，下次收到消息就按新的名字走。

## 7. 构建与自检

```bash
# 静态检查（不需要 macOS）：括号/@end/声明实现/selector/C 函数参数/引号/非法点语法
python tools/check_sources.py .

# 证明检查器有效：故意注入 8 类错误，必须都被抓出来
python tools/selftest_checker.py

# 构建脚本自测（用假 xcrun 验证成功/失败路径，不需要 macOS）
bash tools/selftest_build_scripts.sh

# 真正编译（需要 macOS + Xcode）
bash scripts/build-dylib.sh      # 产出 build/WXReply.dylib
```

CI（`.github/workflows/build.yml`）：`lint`（上面三个自检）→ `dylib`（macos-14 编译 + 签名副本 + 上传产物）。

## 8. 目录结构

```
src/WXRCommon.h/.m        配置键、版本号
src/WXRLog.h/.m           日志（内存环 + 文件）
src/WXRPrefs.h/.m         配置存储（存在微信容器里，不污染微信偏好）
src/WXRHook.h/.m          纯 runtime 方法交换 + 安全调用小工具
src/WXROverrides.h/.m     候选名覆盖（适配不同微信版本）
src/WXRWeChat.h/.m        微信内部对象定位：收消息、发消息、字段读取、诊断报告
src/WXRAutoReply.h/.m     ★ 唯一的业务：自动回复引擎（规则 / 默认 / AI）
src/WXRSettings.h/.m      设置界面
src/WXRSettingsEntry.h/.m 入口：微信设置页那一行 + 长按标签栏 + 首次提示
src/WXRBoot.m             dylib 入口（构造函数）
tools/                    静态检查器 + 变异自测 + 构建脚本自测
scripts/build-dylib.sh    纯 clang 编译 dylib（带阶段标记）
docs/HOOKS.md             候选名适配指南
```

## 9. 已知限制（说实话）

- **尚未在真机验证**：默认候选名来自公开的微信内部命名习惯，需要用第 6 节的诊断报告确认；不匹配只会"不回复"，不会崩。
- 注入微信违反其服务条款，**有账号风险**；建议先备份聊天记录。
- AI 回复会把命中的聊天内容发到**你自己配置的**接口；不想外发就用规则/默认回复。
- 日志默认不记录消息正文（设置里可开，仅用于排查）。
