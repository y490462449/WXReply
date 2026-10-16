# 候选名适配指南

微信没有公开 API，内部类名/方法名每个大版本都可能变。WXReply 的所有调用都是
**"候选列表 + 存在才用"**：找不到只写日志，不会崩，但功能也就不生效。

本插件只需要挂**一个**回调（收新消息），所以适配面很小。

---

## 1. 默认候选名（在 `src/WXRWeChat.m` 顶部）

| 用途 | 覆盖键 | 默认候选 |
|---|---|---|
| 服务总线类 | `servicecenter` | `MMServiceCenter` / `MMServiceCenterLogic` / `ServiceCenter` |
| 服务总线单例方法 | `servicecenterinit` | `defaultCenter` / `sharedInstance` / `sharedServiceCenter` |
| 消息服务类 | `msgclass` | `CMessageMgr` / `MessageService` / `MessageMgr` |
| **收消息回调** | `incoming` | `AsyncOnAddMsg:MsgWrap:` / `OnAddMsg:MsgWrap:` / `onAddMsg:MsgWrap:` / `AddMsg:MsgWrap:` / `AsyncOnAddMsg:MsgWrap:Ext:` / `OnAddMsg:MsgWrap:Ext:` |
| 发消息（收 MsgWrap） | `sendmsg` | `SendMsg:` / `AsyncSendMsg:` / `sendMsg:` … |
| 发消息（收文本+会话） | `sendtext` | `AsyncSendTextMsg:toSession:` … |
| 通讯录服务类 | `contactclass` | `CContactMgr` / `ContactService` / `CContactService` |
| 正文字段 | `content` | `m_nsContent` / `nsContent` / `content` |
| 消息类型字段 | `type` | `m_uiMessageType` / `uiMessageType` … |
| 发送者字段 | `from` | `m_nsFromUsr` / `nsFromUsr` … |
| 接收者字段 | `to` | `m_nsToUsr` / `nsToUsr` / `toUsr` |
| 服务端消息 id | `svrid` | `m_n64MesSvrID` … |
| 本地消息 id | `localid` | `m_uiMesLocalID` … |
| 消息来源 XML（群里判断 @我 用） | `msgsource` | `m_nsMsgSource` / `nsMsgSource` / `msgSource` |

## 2. 怎么知道该填什么

1. 打开 微信「我 → 设置 → 自动回复 → 诊断报告（含候选名）」
2. 报告里会列出：每个候选类/方法**在你的微信版本里是否存在**，以及当前生效的清单
3. 把报告内容发回给维护者，或者自己按第 3 节填覆盖

## 3. 自己填覆盖（不用重新编译）

设置 → 候选名覆盖，一行一条：

```
incoming=AsyncOnAddMsg:MsgWrap:
msgclass=CMessageMgr
content=m_nsContent
```

- 分隔符用 `=`（selector 里本身有冒号，所以别用 `:`）
- 多个候选用英文逗号分隔，按顺序尝试：`incoming=AsyncOnAddMsg:MsgWrap:,OnAddMsg:MsgWrap:`
- `#` 开头的行是注释
- 保存后**下次收到消息就生效**；想立刻重挂，重新打开一次微信即可（代码里也有自动重试）

> 覆盖只是**追加并优先**使用你填的名字，原来的默认候选仍然保留在后面，填错了不会更糟。

## 4. 常见症状对照

| 症状 | 可能原因 | 处理 |
|---|---|---|
| 设置页没有「自动回复」那一行 | 微信把设置页类名改了（默认只认名字里含 `newsetting` 的） | 用**长按底部标签栏 1 秒**进设置；把诊断报告发我补类名 |
| 连首次「WXReply 已加载」弹窗都没有 | dylib 没被加载 | 检查 TrollFools 是否注入成功、微信包是否解密版 |
| 有设置页、开关也打开了，但从不回复 | `incoming` 回调没挂上，或字段名不对 | 看设置 → 运行状态 / 日志；把诊断报告发我 |
| 回复了但内容不对 | 规则/默认回复配置问题 | 检查关键词规则格式 `关键词 => 回复` |
| 群里不回复 | 默认"群里仅在 @我 时回复" | 在设置里关掉这一项 |
| 同一个人连发消息只回一次 | 同会话冷却 | 把「同会话冷却」改成 0 |

## 5. 想自己加日志排查

设置 → 详细日志（打开），复现一次，然后 设置 → 查看日志 / 诊断报告。
日志里关键前缀：`[init]` `[bridge]` `[reply]` `[entry]` `[settings]`。
