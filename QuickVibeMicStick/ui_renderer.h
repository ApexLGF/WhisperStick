// ui_renderer.h
// v1.0.0 三区主界面(REQ-008):AI Agent 信息区 / 会话列表区 / footer
// 渲染目标 170×320 竖屏,整屏 sprite(PSRAM)+ pushSprite,数据模型见 ui_model.h

#pragma once
#include <stdint.h>
#include "claude_status_parser.h"   // PermissionToastState / AsrFeedbackState
#include "ui_model.h"
#include "session_rows.h"           // T-034: 显示行 ↔ 会话下标 映射(渲染侧与输入侧共用)

enum BatteryThermalState : uint8_t {
    BAT_THERMAL_NORMAL = 0,
    BAT_THERMAL_WARM,
    BAT_THERMAL_COOL,
    BAT_THERMAL_COLD,
    BAT_THERMAL_HOT,
    BAT_THERMAL_UNKNOWN,
};

struct BatteryInfo {
    uint8_t pct;          // 0..100
    bool    charging;     // 充电中(未充满)
    bool    full;         // 充满(charging 完成,USB 仍在)
    bool    percentageAvailable; // false when the board has no battery ADC/fuel gauge
    bool    statusKnown;  // charger/status backend is reachable
    bool    fault;        // non-NTC fault, or severe Cold/Hot/unknown NTC state
    BatteryThermalState thermalState; // decoded REG09.NTC_FAULT
};

// ── 语音电平/波形视图(README_VOICE_UI §9)──
// 音频任务(Core 1)按 chunk 发布,主循环复制快照后传入 ui_render;渲染侧只读
struct VoiceMeterView {
    int16_t db10;          // RMS dBFS ×10,-600..0(-600 = -60.0 dBFS)
    uint8_t waveform[21];  // 21 段峰值,0..255
};

// 电源/亮度状态
enum UiPowerLabel {
    UI_PWR_ACT = 0,
    UI_PWR_IDLE,
    UI_PWR_DIM,
    UI_PWR_OFF,
};

// UI 顶层状态
enum UiTopState {
    UI_DASHBOARD = 0,   // 默认主屏
    UI_ERROR,           // 错误页(占位,目前未使用)
};

// overlay 浮层状态
enum UiOverlayState {
    UI_OV_NONE = 0,      // 显示主界面
    UI_OV_PTT_PRESS,     // BtnA 按下,PTT 三阶段动画
    UI_OV_ASR_PROC,      // BtnA 松开后等 ASR
    UI_OV_ASR_SUCCESS,   // ASR 成功,2s 自动消失
    UI_OV_ASR_FAILURE,   // ASR 失败,2s 自动消失
    UI_OV_SHIP_CONFIRM,  // Mac 请求后显示的全屏运输模式确认页
};

enum UiShipModeState : uint8_t {
    UI_SHIP_READY = 0,
    UI_SHIP_USB_BLOCKED,
    UI_SHIP_ERROR,
    UI_SHIP_ENTERING,
};

struct UiOverlayCtx {
    UiOverlayState state;
    unsigned long  pttStartMs;       // PTT 按下时间(三阶段判定)
    unsigned long  overlayStartMs;   // overlay 当前阶段进入时间
    unsigned long  asrFailExpireMs;  // ASR 反馈 2s 自动回主界面
    char           asrFailMsg[64];   // ASR Failure 消息
    bool           toggleHint;       // REQ-010: 长语音模式录音提示("Tap A to stop")
    char           infoNote[48];     // REQ-010: 附加提示(如"录音超时已自动停止"),ASR_PROC 页显示
    bool           systemMic;        // T-033: 系统麦模式 → 录音页文案标注"非设备麦克风"
    UiShipModeState shipModeState;    // 运输模式确认/USB拦截/I2C错误/正在进入
};

// splash 渲染状态:未连 / 已连等数据
enum SplashStatus {
    SPLASH_DISCONNECTED = 1,   // 红点 + "Disconnected"
    SPLASH_CONNECTED    = 2,   // 绿点 + "Connected"(已连但 Mac 还没推数据)
};

// ── REQ-022 审批模态视图模型(输入/队列侧维护,渲染侧只读)──
// 内容字段均为 NUL 结尾 UTF-8(由 .ino 从 ApprovalRequestFrame 定长字段拷出补 NUL)
struct ApprovalUiView {
    bool     active;            // false = 队列空,不渲染
    uint16_t reqId;
    uint8_t  agentId;           // 0=Claude 1=Codex 其他=通用占位图标
    uint8_t  riskLevel;         // 0/1/2(解码侧已钳制)→ 外框白/黄/红
    bool     truncated;         // flags.bit0 → 显示"…(已截断)"
    bool     notifyOnly;        // flags.bit1 → 底行换"请在 Mac 处理"
    bool     alwaysDisabled;    // flags.bit2 → AA 灰显
    uint8_t  state;             // ApprovalEntryState 数值:0=ACTIVE 1=SENT_AWAITING_ACK 2=SEND_FAILED
    char     sessName[25];
    char     tool[65];
    char     body[257];
    uint32_t remainMs;          // 倒计时剩余(已钳制 ≥0)
    uint8_t  index1;            // 队列序号 N(1-based)
    uint8_t  total;             // 队列总数 M
    unsigned long pressFeedbackMs;  // A 按下时刻(0=无);280ms 双击迟滞期间的按压反馈高亮
};

// 注册视图指针(setup 调一次;渲染在 modeCtx.mode==DEV_MODE_APPROVAL 时读取)
void ui_set_approval_view(const ApprovalUiView *v);

void ui_init();

// splash 7 秒品牌循环从头开始(SPL 演示命令用;真实路径靠连接状态边沿自动重置)
void ui_splash_restart_cycle();

// 截图 dump:把整屏 sprite 帧缓冲经 Serial 原样输出(RGB565 标准序,行主序)。
// 格式:"<<<SCR BEGIN 170 320>>>\n" + 108800 字节裸数据 + "\n<<<SCR END>>>\n"
// sprite 未分配(fallback 直绘模式)时输出 "<<<SCR ERR nosprite>>>"。
void ui_dump_screen();

// 黑匣子诊断两行(开机取证,splash 版本号下方小字显示);传 nullptr/空串则不画
void ui_set_diag(const char *line1, const char *line2);

void ui_render_splash(SplashStatus status,
                      const char *deviceName,
                      const char *fwVersion);

// OTA 独占期间覆盖主页，明确告知按键暂不可用并显示设备实际接收进度。
void ui_render_firmware_update(uint8_t progressPercent, bool finalizing);

void ui_set_overlay(UiOverlayCtx &ctx, UiOverlayState newState);

void ui_clear();

// 会话列表当前可视行数(随 Agent 区块数变化;输入侧滚动钳制用)
struct V5Config;   // v5_protocol.h
int ui_session_vis_rows(const V5Status &st);

// 顶层入口:overlay 优先,其次 splash / 三区主界面(+ 模式窗口叠加)
void ui_render(const V5Status &st,
               const BatteryInfo &bat,
               const char *fwVersion,
               uint8_t bleBars,               // REQ-021:BLE 信号格(0..4);替代原 pwr 位
               const UiOverlayCtx &ov,
               const PermissionToastState &perm,
               bool bleConnected,
               const char *deviceName,
               const UiListSel &sel,
               const V5Config &cfg,
               const UiModeCtx &modeCtx,
               int topMinOfDay,               // T-025:当日分钟数;-1=未收时间帧 → "--:--"
               const VoiceMeterView &voiceMeter);   // 录音页波形/电平(2026-07 voice_ui 改版)
