# MaPay 码支付系统

> 基于个人微信收款码的轻量级支付接口系统，由 **PHP 服务端** 与 **iOS 微信收款监控插件** 两部分组成。
> 适用于需要把"扫码付款"接入自有网站/系统的个人开发者与小微商户场景。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-PHP%20%7C%20iOS-blue.svg)]()
[![GitHub](https://img.shields.io/badge/GitHub-yZFAIU%2FMaPay-blue?logo=github)](https://github.com/yZFAIU/MaPay)

> 📦 **仓库地址：** https://github.com/yZFAIU/MaPay

---

## 📖 简介

传统的微信支付商户接口需要企业资质、繁琐审核与手续费。**MaPay** 换了一条更轻量的路：直接用你自己的微信**个人收款码**收款，再通过一个"监控端"实时监听微信「收款助手」的到账通知，把金额上报给服务端，服务端据此自动完成订单匹配与回调。

整个系统分为两端：

| 端 | 技术栈 | 职责 |
|----|--------|------|
| **服务端** (`server/`) | PHP 7.4+ · MySQL · PDO | 订单管理、收款码展示、金额匹配、商户回调、管理后台 |
| **监控端** (`PayHook-iOS/`) | iOS Tweak (Theos/ObjC) | 注入微信，监听「微信收款助手」到账消息，提取金额并上报服务端 |

> 监控端目前提供 **iOS 插件** 实现（TrollStore / 自签注入）。如需 PC 端（Windows/Mac 监控器）可基于 `monitor_report` 接口自行实现。

---

## 🧩 系统架构

```
┌──────────┐   创建订单    ┌─────────────┐   展示收款码   ┌──────────────┐
│  商户网站 │ ───────────► │  MaPay 服务端 │ ───────────► │  用户微信扫码  │
│ (网站/App)│              │  (server/)   │              │   付给收款码   │
└──────────┘ ◄─────────── └──────┬──────┘               └──────┬───────┘
           回调通知(异步)          │ 金额匹配 / 标记已支付        │ 微信官方下发
                                  │                            │「收款助手」通知
                                  │                            ▼
                          ┌───────┴────────┐           ┌─────────────────┐
                          │  订单状态=已支付 │ ◄──────── │ iOS 监控插件     │
                          └────────────────┘  上报金额  │ (PayHook-iOS/)  │
                                                      └─────────────────┘
```

**核心流程：** 商户创建订单 → 用户扫码付款 → 微信下发「收款助手」到账通知 → iOS 插件提取金额上报 → 服务端按金额匹配待支付订单 → 标记已支付并异步回调商户网站。

---

## ✨ 功能特性

- **订单全生命周期管理**：创建 / 查询 / 关闭 / 过期自动清理
- **收款码支付页**：自动展示微信收款码 + 倒计时 + 前端轮询到账状态
- **到账金额匹配**：监控端上报金额后自动匹配最早待支付订单（基于金额精确匹配）
- **去重机制**：服务端基于时间窗口去重，监控端基于 `svrMsgId` 做 LRU 去重，避免重复记账
- **商户回调**：支付成功后按 `notify_url` 异步回调，支持失败重试（默认 5 次，商户返回 `success` 视为成功）
- **MD5 签名**：商户 API 与监控端上报均支持签名 / 密钥校验
- **管理后台**：`admin.php` 提供订单与收款记录的可视化查看
- **监控端白名单**：iOS 插件仅识别「微信收款助手」(`gh_f0a92aa7146c`) 的真实消息，杜绝误判
- **远程配置热更新**：iOS 端支持远程 JSON 配置（关键词 / 正则 / 白名单）

---

## 📁 目录结构

```
MaPay/
├── README.md
├── LICENSE
├── .gitignore
├── server/                     # PHP 服务端
│   ├── api.php                 # 统一 API 入口（订单 / 监控 / 统计）
│   ├── pay.php                 # 支付页（收款码 + 轮询）
│   ├── check.php               # 订单状态轮询接口
│   ├── admin.php               # 管理后台
│   ├── index.php               # 入口（重定向到后台）
│   ├── qrcode.php              # 二维码生成
│   ├── config.php              # 配置 + 签名工具函数
│   ├── db.php                  # 数据库操作（PDO 单例）
│   ├── init.php                # 初始化脚本（建表 + 默认商户）
│   ├── callback_demo.php       # 商户回调接收示例
│   └── data/                   # 运行时目录（放收款码、日志）
└── PayHook-iOS/                # iOS 微信收款监控插件（Theos Tweak）
    ├── Tweak.x                 # 主控 + CMessageMgr Hook + 收款识别 + 上报
    ├── XJPaymentXMLParser.*    # 解析 <wcpayinfo> 获取金额 / 流水号
    ├── XJRemoteConfig.*        # 远程 JSON 配置热更新
    ├── XJPaySourceConfig.*     # 公众号白名单查找
    ├── XJMessageDedup.*        # 基于 svrMsgId 的 LRU 去重
    ├── build.sh                # 自动版本号递增编译
    ├── Makefile / control      # Theos 构建配置
    └── README.md               # 插件专属说明
```

---

## 🚀 快速开始

### 一、部署服务端 (`server/`)

**环境要求**：PHP 7.4+，MySQL 5.7+，并启用扩展 `pdo`、`pdo_mysql`、`curl`、`json`、`mbstring`、`gd`。

1. **配置** `server/config.php`：
   - 修改 `DB_HOST / DB_PORT / DB_NAME / DB_USER / DB_PASS` 为你的数据库
   - 修改 `SITE_URL` 为你的站点地址（回调与支付页依赖它）
   - 修改监控密钥 `MAPAY_MONITOR_SECRET`（默认 `mapay_monitor_2024`，可通过环境变量覆盖）

2. **初始化**（命令行）：
   ```bash
   cd server
   php init.php
   ```
   该脚本会自动建表，并创建一个默认测试商户 `M100001`（控制台会打印其 `api_key`）。

3. **放置收款码**：把你的微信收款码图片命名为 `wechat_qr.png` 放到 `server/data/` 目录。

4. **访问后台**：浏览器打开 `https://你的域名/admin.php`。

### 二、部署 iOS 监控插件 (`PayHook-iOS/`)

> 仅用于已越狱或支持 TrollStore / 自签注入的设备，用于监控**你自己**的微信收款到账。

1. 准备环境：theos + Xcode iOS SDK。
2. 编译：
   ```bash
   cd PayHook-iOS
   ./build.sh          # 自动版本号递增 3.0.0-{N}
   ```
3. 安装（二选一，无需越狱）：
   - **TrollStore（推荐）**：解密微信 IPA → `insert_dylib` 注入 → TrollStore 安装，一次永久（支持 iOS 14–16.6.1）
   - **自签**：同上注入 → `azule` 打包 → 个人 Apple ID 签名 → AltStore/SideStore 安装（7 天续签）
4. 在插件配置中填写你的服务端上报地址 `https://你的域名/api.php?action=monitor_report` 与监控密钥。
5. 微信内 **我 → 设置** 连点标题 5 次打开控制面板。

---

## 🔌 API 接口

所有接口基于 `server/api.php?action=xxx`，除健康检查/统计外均需签名或密钥校验。

### 商户 API（MD5 签名）

**1. 创建订单** `POST /api.php?action=order_create`

| 参数 | 必填 | 说明 |
|------|------|------|
| merchant_id | ✅ | 商户号 |
| out_trade_no | ✅ | 商户侧订单号 |
| amount | ✅ | 金额（0 < amount ≤ 100000） |
| title / attach | ❌ | 订单标题 / 附加数据 |
| notify_url | ❌ | 回调地址（缺省用商户配置的 callback_url） |
| sign | ✅ | MD5 签名 |

返回：`trade_no`、`pay_amount`、`pay_url`、`expires_at` 等。

**2. 查询订单** `POST /api.php?action=order_query`（参数：`merchant_id`、`trade_no` 或 `out_trade_no`、`sign`）

**3. 关闭订单** `POST /api.php?action=order_close`（仅 `created` 状态可关闭）

### 监控端 API

**4. 收款上报** `POST /api.php?action=monitor_report`
接收 JSON：`{ amount, pay_type, raw_text, monitor, source, monitor_secret | sign }`
服务端按金额匹配待支付订单并标记已支付，返回 `{ matched, trade_no, amount }`。

**5. 日志上报 / 查看** `monitor_upload_logs` / `monitor_view_logs`

### 系统 API

**6. 健康检查** `GET /api.php?action=health`
**7. 统计数据** `GET /api.php?action=stats`（返回总订单数、已支付数、总金额、收款记录数）

### 回调（推送给商户 `notify_url`）

服务端 POST 表单：`trade_no`、`out_trade_no`、`merchant_id`、`amount`、`pay_amount`、`status=paid`、`paid_at`、`timestamp`、`sign`。商户业务逻辑处理完毕后**返回字符串 `success`** 即视为回调成功。

---

## ⚙️ 配置说明（服务端 `config.php`）

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `ORDER_EXPIRE_SECONDS` | 300 | 订单过期时间（秒） |
| `MONITOR_DEDUP_SECONDS` | 30 | 监控端上报去重窗口（秒） |
| `CALLBACK_TIMEOUT` | 10 | 回调超时（秒） |
| `CALLBACK_RETRY` | 5 | 回调最大重试次数 |
| `AMOUNT_RANDOM_MIN/MAX` | 0.01/0.99 | 金额随机化区间（当前已禁用，实付=请求金额） |
| `MAPAY_MONITOR_SECRET` | `mapay_monitor_2024` | 监控端密钥（建议用环境变量覆盖） |

---

## 🔐 安全说明

- 商户 API 与监控端上报均使用 MD5 签名 / 密钥校验，**生产环境请务必修改默认密钥**并改用环境变量注入。
- `server/data/` 包含收款码与运行日志，已通过 `.gitignore` 排除，请勿将私人收款码提交到公开仓库。
- 监控端仅识别微信官方「收款助手」的真实到账消息，不 hook 任何消息构造方法，不进行任何支付伪造或篡改。
- 建议服务端仅对内网 / 受信任的监控端开放 `monitor_report` 接口（如限制来源 IP）。

---

## ⚠️ 合规声明

本项目用于帮助个人 / 小微商户以更轻量的方式管理**自有**收款码的到账确认与订单对接。

- 请遵守微信支付相关用户协议与当地法律法规，**仅将其用于合法、真实的小额收款场景**。
- 不得用于欺诈、洗钱、虚假交易、规避监管等任何违法违规用途；因违规使用产生的后果由使用者自行承担。
- 本项目按 **"现状"（AS-IS）** 提供，作者不对使用后果作任何担保。

---

## 🤝 贡献者

- [@yZFAIU](https://github.com/yZFAIU) — 项目作者 / 维护者

欢迎提交 Issue 与 Pull Request。

---

## 📄 许可证

[MIT License](LICENSE) © yZFAIU
