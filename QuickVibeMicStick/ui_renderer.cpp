// ui_renderer.cpp
// Stage 3a: 170×320 竖屏 Dashboard 静态骨架
//
// 内存策略:
//   - 优先整屏 sprite (170×320×2 = 109KB, PSRAM 分配)
//   - 失败 fallback 到 batt(170×16) + main(170×304) 两段 sprite
//   - 都失败再 fallback 到直接 tft 绘制(撕裂可见但不黑屏)
//
// 字体(TFT_eSPI 内建):
//   - font 1 (默认) 6×8 ASCII — 电池条 / token 统计
//   - font 2          8×16     — session list / tool bar
//
// 颜色阈值(对齐 Stick S3 drawStatusBar):
//   - usagePct < 80 → CYAN,>= 80 → RED
//   - ctxPct  < 80 → ORANGE,>= 80 → RED
//
// session 调色板:复用 Stick S3 11 色,索引 0..10。

#include <Arduino.h>
#include <TFT_eSPI.h>
#include <U8g2_for_TFT_eSPI.h>
#include "ui_renderer.h"
#include "v5_protocol.h"   // V5Config(Prompt 标题列表)
#include "agent_icons.h"    // claude/codex 32×32 RGB565(v1.0.0 三区布局)
#include "splash_assets.h"  // REQ-023 二期:透明合成 Logo + 字母/everything 切片
#include "modal_assets.h"   // REQ-023 二期:审批盾牌 14×14
#include "token_format.h"   // REQ-020:当日 token K/M 缩写
#include "i18n_catalog.generated.h"
#include "i18n_font.generated.h"

extern TFT_eSPI tft;  // 主 .ino 全局

// ── 屏尺寸契约 ───────────────────────────────────────────
// 本文件 Dashboard / overlay / splash 的所有坐标都是按 170×320 竖屏手工排版的
// (createSprite(170,320)、CX=85、CY=160、各分段 y 等魔法数字)。
// v10 面板 = GoldenMorning 1.9" ST7789P3 170×320 4线SPI,与面包板 T-Display-S3 同分辨率,
// 故 v10 直接复用本布局、无需改坐标。
// 若将来换屏:改 platformio.ini 的 TFT_WIDTH/HEIGHT 会触发下面断言,强制提醒先重排坐标,
// 而不是默默渲染错位。
#if defined(TFT_WIDTH) && defined(TFT_HEIGHT)
static_assert(TFT_WIDTH == 170 && TFT_HEIGHT == 320,
              "ui_renderer layout is hand-tuned for 170x320; re-tune all coordinates before changing panel size");
#endif

// ── Sprite 池 ───────────────────────────────────────────
static TFT_eSprite spr(&tft);            // 整屏 170×320
static bool        sprFull = false;      // 整屏 sprite 是否成功

static void buildIcon14();               // 定义在 Agent 区段(ui_init 调用)

// ── U8g2 CJK 字体桥(session/tool/proj 中文显示)──────────
// wqy16_t_chinese3: WenQuanYi 16px,GBK 全集(~22K 字符)
// 字高 16 与原 TFT_eSPI font2 (8x16) 等高,排版兼容
// 注:chinese1 缺常用字(实测 "日" 不在),chinese3 多 6KB 但全覆盖,值得
static U8g2_for_TFT_eSPI g_u8g2;
static bool              g_u8g2_ready = false;
// wqy16 字体 baseline y 基准:ascent ≈ 13,在 y_top 渲染需 setCursor(x, y_top + 13)
#define U8G2_WQY16_BASELINE_OFFSET 13

// ── 2026-07 新版视觉调色板(res/homepage + res/voice_ui 设计交付)──
// RGB565 值直接取自 homepage_design_spec.json / README,不要用颜色名近似换算。
// 注:#34505F 与 #37515A 量化到 RGB565 后同为 0x328B,属预期。
static constexpr uint16_t UI_BG              = 0x0083; // #061018 全屏背景
static constexpr uint16_t UI_AGENT_BG        = 0x08C4; // #0C1821 Agent 区背景(=voice PANEL)
static constexpr uint16_t UI_SEPARATOR       = 0x328B; // #34505F Agent 区底部 2px 横线
static constexpr uint16_t UI_SELECTED_BG     = 0x1BF5; // 直通行全宽色带;设计值 #145873(0x12CE)在
                                                       // ST7789 实机上偏暗不显眼,提亮 ~50% 至 ≈#1E84AC(用户 2026-07-25 反馈)
static constexpr uint16_t UI_TEXT_PRIMARY    = 0xEFBF; // #EEF5F8 主文字
static constexpr uint16_t UI_TEXT_SECONDARY  = 0x9536; // #91A4B2 辅助文字
static constexpr uint16_t UI_LAMP_GREEN      = 0x2F0E; // #2BE276
static constexpr uint16_t UI_LAMP_BLUE       = 0x247F; // #278CFF
static constexpr uint16_t UI_LAMP_YELLOW     = 0xFDE7; // #FFBE3D
static constexpr uint16_t UI_LAMP_RED        = 0xFA8C; // #FF5263
static constexpr uint16_t UI_LAMP_GRAY       = 0x530D; // #53616D
static constexpr uint16_t UI_LAMP_HOUSING    = 0x10C3; // #111A1F 灯座
static constexpr uint16_t UI_LAMP_BORDER     = 0x328B; // #37515A 灯座描边
static constexpr uint16_t UI_TRACK           = 0x2187; // #22323D 进度条轨道
static constexpr uint16_t UI_CYAN            = 0x263D; // #27C7E8 API 徽标等
static constexpr uint16_t UI_USAGE_5H        = 0xFD86; // #FFB331 5h 用量条
static constexpr uint16_t UI_USAGE_7D        = 0xE3E7; // #E77F39 7d 用量条
static constexpr uint16_t UI_LAMP_SCREW      = 0x7410; // 灯座四角固定点
static constexpr uint16_t UI_ROW_DIVIDER     = 0x1146; // #172B37 会话行间细分隔线

// voice_ui 专属色(README_VOICE_UI §3)
static constexpr uint16_t VC_TEXT_SECONDARY  = 0x84B4; // #8194A3
static constexpr uint16_t VC_DIVIDER         = 0x1146; // #172B37 顶部分隔线
static constexpr uint16_t VC_PANEL           = 0x08C4; // #0C1821 普通模式卡片
static constexpr uint16_t VC_PANEL_BORDER    = 0x1987; // #1A303E 卡片边线
static constexpr uint16_t VC_CYAN            = 0x365E; // #31C9F3 波形/计时/工作动画
static constexpr uint16_t VC_CYAN_MID        = 0x2C96; // 工作动画中间亮度(CYAN→DARK 插值)
static constexpr uint16_t VC_CYAN_DARK       = 0x22EE; // #225D70 工作动画暗态
static constexpr uint16_t VC_DIRECT_BG       = 0x1168; // #102F42 直通模式卡片
static constexpr uint16_t VC_GREEN           = 0x2F0E; // #2BE276 成功
static constexpr uint16_t VC_RED             = 0xFA8C; // #FF5263 录音/错误
static constexpr uint16_t VC_OK_SHELL_FILL   = 0x0944; // #0D2A20 成功外壳填充
static constexpr uint16_t VC_OK_SHELL_EDGE   = 0x22E8; // #245D43 成功外壳描边
static constexpr uint16_t VC_ERR_SHELL_FILL  = 0x28A3; // #2B171C 错误外壳填充
static constexpr uint16_t VC_ERR_SHELL_EDGE  = 0x7187; // #71303A 错误外壳描边
static constexpr uint16_t VC_BUSY_OUTER      = 0x08E4; // #0A1C26 工作动画外圆
static constexpr uint16_t VC_BUSY_INNER      = 0x0926; // #0D2633 工作动画内圆

// splash 专属色(README_SPLASH §连接状态/动效)
static constexpr uint16_t SP_EDGE_DIS   = 0x3925; // #39242B 未连接状态卡边线
static constexpr uint16_t SP_TEXT_DIS   = 0xFBB0; // #FF7583 未连接状态文字
static constexpr uint16_t SP_EDGE_CON   = 0x1A46; // #1D4934 已连接状态卡边线
static constexpr uint16_t SP_TEXT_CON   = 0x5752; // #54EA91 已连接状态文字
static constexpr uint16_t SP_DOT_DIM    = 0x5125; // #51252D 搜索点非活跃
static constexpr uint16_t SP_SPOT_OUTER = 0x11C9; // #14384A 扫光外层光晕
static constexpr uint16_t SP_SPOT_MID   = 0x2BF3; // #2B7C99 扫光中层(高亮切片合成底色)
static constexpr uint16_t SP_SPOT_CORE  = 0xDFDF; // #D9F8FF 扫光中心亮线

// 模态窗色板(README_MODAL §5;审批紫用设计稿 #6D35C5,LED 保持 #8C00C8,
// 同为紫色家族,用户 2026-07-25 拍板)
static constexpr uint16_t MD_BG         = 0x08C4; // #0C1821 窗口正文背景
static constexpr uint16_t MD_TITLE_BG   = 0x1126; // #102432 普通标题栏
static constexpr uint16_t MD_TITLE_PUR  = 0x69B8; // #6D35C5 审批标题栏
static constexpr uint16_t MD_BORDER_C   = 0x365E; // #31C9F3 普通窗口边框
static constexpr uint16_t MD_BORDER_P   = 0xA3DF; // #A77BFF 审批窗口边框
static constexpr uint16_t MD_TEXT_MAIN  = 0xF7BF; // #F2F7FA 标题/主文字
static constexpr uint16_t MD_TEXT_BODY  = 0xDF5D; // #DFE8ED 正文
static constexpr uint16_t MD_TEXT_MUTED = 0x84B4; // #8194A3 辅助
static constexpr uint16_t MD_SEL_BG     = 0x1168; // #102F42 列表选中实底
static constexpr uint16_t MD_SEL_ACC    = 0x56DF; // #55DAF8 选中强调
static constexpr uint16_t MD_ALLOW      = 0x2F0E; // #2BE276 B允许
static constexpr uint16_t MD_ALWAYS     = 0xF6C9; // #F1DB4B BB总是
static constexpr uint16_t MD_DENY       = 0xFCE7; // #FF9C3D C拒绝
static constexpr uint16_t MD_CD_BG      = 0x39EC; // 倒计时胶囊底(标题紫 ×0.55)

// ── RGB565 亮度缩放(圆点动效呼吸/暗态用)──────────────────
static uint16_t scale565(uint16_t c, float f) {
    if (f > 1.0f) f = 1.0f;
    if (f < 0.0f) f = 0.0f;
    uint8_t r = (uint8_t)(((c >> 11) & 0x1F) * f);
    uint8_t g = (uint8_t)(((c >> 5) & 0x3F) * f);
    uint8_t b = (uint8_t)((c & 0x1F) * f);
    return (uint16_t)((r << 11) | (g << 5) | b);
}

// ── RGB565 线性插值(splash 扫光光晕渐变用):f=0 → a,f=1 → b ──
static uint16_t blend565(uint16_t a, uint16_t b, float f) {
    if (f <= 0.0f) return a;
    if (f >= 1.0f) return b;
    int ar = (a >> 11) & 0x1F, ag = (a >> 5) & 0x3F, ab = a & 0x1F;
    int br = (b >> 11) & 0x1F, bg = (b >> 5) & 0x3F, bb = b & 0x1F;
    int r = ar + (int)((br - ar) * f);
    int g = ag + (int)((bg - ag) * f);
    int bl = ab + (int)((bb - ab) * f);
    return (uint16_t)((r << 11) | (g << 5) | bl);
}

// ──────────────────────────────────────────────────────────
// 抽象绘制目标:整屏 sprite 模式下用 spr,fallback 模式用 tft
// 简化:始终用一个引用变量返回当前 canvas
// ──────────────────────────────────────────────────────────
static inline TFT_eSPI *canvasTft() { return &tft; }
static inline TFT_eSprite *canvasSpr() { return &spr; }

#define CANVAS_DO(call)            \
    do {                           \
        if (sprFull) spr.call;     \
        else         tft.call;     \
    } while (0)

// 包一层方便写
static void cFillRect(int x, int y, int w, int h, uint16_t c) {
    if (sprFull) spr.fillRect(x, y, w, h, c);
    else         tft.fillRect(x, y, w, h, c);
}
static void cDrawRect(int x, int y, int w, int h, uint16_t c) {
    if (sprFull) spr.drawRect(x, y, w, h, c);
    else         tft.drawRect(x, y, w, h, c);
}
static void cDrawFastHLine(int x, int y, int w, uint16_t c) {
    if (sprFull) spr.drawFastHLine(x, y, w, c);
    else         tft.drawFastHLine(x, y, w, c);
}
static void cDrawLine(int x0, int y0, int x1, int y1, uint16_t c) {
    if (sprFull) spr.drawLine(x0, y0, x1, y1, c);
    else         tft.drawLine(x0, y0, x1, y1, c);
}
static void cFillCircle(int x, int y, int r, uint16_t c) {
    if (sprFull) spr.fillCircle(x, y, r, c);
    else         tft.fillCircle(x, y, r, c);
}
static void cFillScreen(uint16_t c) {
    if (sprFull) spr.fillScreen(c);
    else         tft.fillScreen(c);
}
static void cSetTextColor(uint16_t fg, uint16_t bg) {
    if (sprFull) spr.setTextColor(fg, bg);
    else         tft.setTextColor(fg, bg);
}
static void cSetCursor(int x, int y) {
    if (sprFull) spr.setCursor(x, y);
    else         tft.setCursor(x, y);
}
static void cSetTextFont(uint8_t f) {
    if (sprFull) spr.setTextFont(f);
    else         tft.setTextFont(f);
}
static void cSetTextSize(uint8_t s) {
    if (sprFull) spr.setTextSize(s);
    else         tft.setTextSize(s);
}
static void cPrint(const char *s) {
    if (sprFull) spr.print(s);
    else         tft.print(s);
}
static void cPrintf(const char *fmt, ...) {
    char buf[96];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    cPrint(buf);
}
static void cPushImage(int x, int y, int w, int h, const uint16_t *data) {
    if (sprFull) spr.pushImage(x, y, w, h, data);
    else         tft.pushImage(x, y, w, h, data);
}
static void cDrawPixel(int x, int y, uint16_t c) {
    if (sprFull) spr.drawPixel(x, y, c);
    else         tft.drawPixel(x, y, c);
}
static void cFillRoundRect(int x, int y, int w, int h, int r, uint16_t c) {
    if (sprFull) spr.fillRoundRect(x, y, w, h, r, c);
    else         tft.fillRoundRect(x, y, w, h, r, c);
}
static void cDrawRoundRect(int x, int y, int w, int h, int r, uint16_t c) {
    if (sprFull) spr.drawRoundRect(x, y, w, h, r, c);
    else         tft.drawRoundRect(x, y, w, h, r, c);
}
static void cDrawCircle(int x, int y, int r, uint16_t c) {
    if (sprFull) spr.drawCircle(x, y, r, c);
    else         tft.drawCircle(x, y, r, c);
}
// 圆头粗线(工作动画胶囊 / 结果页对勾叉号);bg 用于 AA 混色
static void cDrawWideLine(float ax, float ay, float bx, float by,
                          float wd, uint16_t fg, uint16_t bg) {
    if (sprFull) spr.drawWideLine(ax, ay, bx, by, wd, fg, bg);
    else         tft.drawWideLine(ax, ay, bx, by, wd, fg, bg);
}
// TFT_eSPI 内建字体水平居中(font4 计时等比例字体必须用 textWidth 实测)
static void cDrawStringCentered(const char *s, int cx, int yTop,
                                uint8_t font, uint16_t fg, uint16_t bg) {
    if (sprFull) {
        spr.setTextDatum(TC_DATUM);
        spr.setTextColor(fg, bg);
        spr.drawString(s, cx, yTop, font);
        spr.setTextDatum(TL_DATUM);
    } else {
        tft.setTextDatum(TC_DATUM);
        tft.setTextColor(fg, bg);
        tft.drawString(s, cx, yTop, font);
        tft.setTextDatum(TL_DATUM);
    }
}

// ──────────────────────────────────────────────────────────
// init
// ──────────────────────────────────────────────────────────
void ui_init() {
    // 竖屏 170×320。v10 PCB 屏体安装方向与面包板相反 → 翻 180°(2026-06-18 实测)
#ifdef BOARD_V10
    tft.setRotation(2);
#else
    tft.setRotation(0);
#endif
    tft.fillScreen(UI_BG);

    // TFT_eSPI 2.5.43:TFT_eSprite ctor 默认 _psram_enable=true,
    // psramFound() 时 createSprite 自动 ps_calloc 到 PSRAM。
    spr.setColorDepth(16);
    void *p = spr.createSprite(170, 320);
    if (p != nullptr) {
        sprFull = true;
        spr.fillSprite(UI_BG);
        Serial.printf("Sprite allocated: 170x320, free PSRAM=%u, free heap=%u\n",
                      (unsigned)ESP.getFreePsram(), (unsigned)ESP.getFreeHeap());
    } else {
        sprFull = false;
        Serial.println("WARN: 170x320 sprite alloc failed; fallback to direct tft draw");
    }

    // U8g2 CJK 桥:绑定到当前 canvas (sprite 优先,fallback 时直绘 tft)
    // TFT_eSprite : public TFT_eSPI, drawFastH/VLine 是 virtual,所以传 spr 时
    // U8g2 内部 tft->drawFastHLine 会通过虚函数派发到 sprite 的覆盖实现
    if (sprFull) g_u8g2.begin(spr);
    else         g_u8g2.begin(tft);
    // GB2312 全集 + 三语资源额外字形。既保留动态简体会话名覆盖,也补足台湾繁体。
    g_u8g2.setFont(u8g2_font_qvms16_t_i18n);
    g_u8g2.setFontMode(0);   // 0 = 不透明背景(让背景色生效,与 TFT_eSPI font2 行为一致)
    g_u8g2_ready = true;

    buildIcon14();   // 14×14 agent 图标预生成(README_HOME_PAGE §10)
}

// ── U8g2 CJK 文字绘制 helper ─────────────────────────────
// y_top: 文字框顶部 y;函数内部会加 baseline offset 转成 U8g2 基线坐标
static void cDrawCJK(int x, int y_top, const char *utf8,
                     uint16_t fg, uint16_t bg) {
    if (!g_u8g2_ready || !utf8) return;
    g_u8g2.setForegroundColor(fg);
    g_u8g2.setBackgroundColor(bg);
    g_u8g2.drawUTF8(x, y_top + U8G2_WQY16_BASELINE_OFFSET, utf8);
}

// CJK 整行水平居中(170px 画布)
static void cDrawCJKCentered(int y_top, const char *utf8, uint16_t fg, uint16_t bg) {
    if (!g_u8g2_ready || !utf8) return;
    int w = g_u8g2.getUTF8Width(utf8);
    int x = (170 - w) / 2;
    if (x < 0) x = 0;
    cDrawCJK(x, y_top, utf8, fg, bg);
}

// ── wqy12 紧凑 CJK(REQ-023 二期:模态正文 11 行密度 / splash 文字)──
// 常驻字体仍是 wqy16;12px 调用后立即切回,避免污染其他绘制路径
#define U8G2_WQY12_BASELINE_OFFSET 10
static inline void cSetFont12() { g_u8g2.setFont(u8g2_font_qvms12_t_i18n); }
static inline void cSetFont16() { g_u8g2.setFont(u8g2_font_qvms16_t_i18n); }

static void cDrawCJK12(int x, int y_top, const char *utf8, uint16_t fg, uint16_t bg) {
    if (!g_u8g2_ready || !utf8) return;
    cSetFont12();
    g_u8g2.setForegroundColor(fg);
    g_u8g2.setBackgroundColor(bg);
    g_u8g2.drawUTF8(x, y_top + U8G2_WQY12_BASELINE_OFFSET, utf8);
    cSetFont16();
}

static int cjk12Width(const char *utf8) {
    if (!g_u8g2_ready || !utf8) return 0;
    cSetFont12();
    int w = g_u8g2.getUTF8Width(utf8);
    cSetFont16();
    return w;
}

static void cDrawCJK12Centered(int cx, int y_top, const char *utf8,
                               uint16_t fg, uint16_t bg) {
    int x = cx - cjk12Width(utf8) / 2;
    if (x < 0) x = 0;
    cDrawCJK12(x, y_top, utf8, fg, bg);
}

// PROGMEM RGB565 图块绘制(splash logo/切片/盾牌;数据同 agent_icons 字节序)
static void cDrawImage(int x, int y, int w, int h, const uint16_t *data) {
    if (sprFull) {
        spr.setSwapBytes(true);
        spr.pushImage(x, y, w, h, data);
        spr.setSwapBytes(false);
    } else {
        tft.setSwapBytes(true);
        tft.pushImage(x, y, w, h, data);
        tft.setSwapBytes(false);
    }
}

// 按像素宽度截断 UTF-8 字符串,超长 buf 末尾追加 ".."
// max_pixels:可用像素宽度;reserve_dots:是否给 ".." 预留 ~16px (8 px × 2)
//   返回:写入 dst 的字节数(不含 \0)
//   dst 必须至少 src 长度 + 3 字节
static int truncUtf8ByPixels(char *dst, size_t dstCap,
                             const char *src, int max_pixels,
                             bool reserve_dots) {
    if (!g_u8g2_ready || !dst || dstCap < 3) return 0;
    if (!src) { dst[0] = 0; return 0; }

    int srcLen = (int)strlen(src);
    int fullW  = g_u8g2.getUTF8Width(src);
    if (fullW <= max_pixels) {
        int n = (srcLen < (int)dstCap - 1) ? srcLen : (int)dstCap - 1;
        memcpy(dst, src, n);
        dst[n] = 0;
        return n;
    }

    // 需要截断;按 codepoint 边界 walk 回退
    int dotsW = reserve_dots ? g_u8g2.getUTF8Width("..") : 0;
    int budget = max_pixels - dotsW;
    if (budget < 0) budget = 0;

    // 临时 copy + 逐次缩短直到放得下
    int n = srcLen;
    char tmp[64];
    if (n > (int)sizeof(tmp) - 1) n = (int)sizeof(tmp) - 1;
    memcpy(tmp, src, n);
    tmp[n] = 0;

    while (n > 0) {
        // 退到合法 UTF-8 边界
        if ((tmp[n - 1] & 0xC0) == 0x80) {
            // 续字节,继续退
            n--;
            tmp[n] = 0;
            continue;
        }
        // 多字节起始字节(0xC0..0xFF)在末尾,退掉
        if ((tmp[n - 1] & 0xC0) == 0xC0) {
            n--;
            tmp[n] = 0;
        }
        if (g_u8g2.getUTF8Width(tmp) <= budget) break;
        n--;
        tmp[n] = 0;
    }

    int outLen = n + (reserve_dots ? 2 : 0);
    if (outLen >= (int)dstCap) outLen = dstCap - 1;
    int copyN = n;
    if (copyN > outLen - (reserve_dots ? 2 : 0)) {
        copyN = outLen - (reserve_dots ? 2 : 0);
    }
    memcpy(dst, tmp, copyN);
    if (reserve_dots) {
        dst[copyN]     = '.';
        dst[copyN + 1] = '.';
        dst[copyN + 2] = 0;
        return copyN + 2;
    }
    dst[copyN] = 0;
    return copyN;
}

// ── 截图 dump(REQ-008 验证基建)────────────────────────────
// readPixel 返回标准 RGB565(与内部字节序无关),逐行凑缓冲后整块写,
// 108800 字节经原生 USB-CDC 约 0.3s。期间其他任务的日志打印可能插入,
// host 端脚本按 BEGIN 标记后精确字节数收帧 + 失败重试来兜。
void ui_dump_screen() {
    if (!sprFull) {
        Serial.print("<<<SCR ERR nosprite>>>\n");
        return;
    }
    // 全局 setTxTimeoutMs(0) 让 HWCDC 写满即丢(防拔线卡死);dump 是 host 主动
    // 请求、对端必在读,临时切阻塞式写保完整,结束恢复 0。
    Serial.setTxTimeoutMs(200);
    Serial.print("<<<SCR BEGIN 170 320>>>\n");
    Serial.flush();
    static uint8_t rowBuf[170 * 2];
    for (int y = 0; y < 320; y++) {
        for (int x = 0; x < 170; x++) {
            uint16_t c = spr.readPixel(x, y);
            rowBuf[x * 2]     = (uint8_t)(c >> 8);
            rowBuf[x * 2 + 1] = (uint8_t)(c & 0xFF);
        }
        Serial.write(rowBuf, sizeof(rowBuf));
    }
    Serial.print("\n<<<SCR END>>>\n");
    Serial.flush();
    Serial.setTxTimeoutMs(0);
}

void ui_clear() {
    if (sprFull) {
        spr.fillSprite(TFT_BLACK);
    } else {
        tft.fillScreen(TFT_BLACK);
    }
}

// ──────────────────────────────────────────────────────────
// Dashboard 主渲染
// ──────────────────────────────────────────────────────────

// ══════════════════════════════════════════════════════════
// 2026-07 新版布局(res/homepage 设计交付):
//   状态栏: y=0..23(时间 / 3 级信号柱 / 电池 + 百分比)
//   区 1: AI Agent 信息区(y=24 起;Claude 订阅 40 / Codex 订阅 32 / API 24)
//   区 1 底: 2px UI_SEPARATOR 横线 + 2px 呼吸间隔
//   区 2: 会话列表区(每行 24px,下探到屏底)
// ══════════════════════════════════════════════════════════
#define STATUS_BAR_H              24
#define ZONE_TOP                  STATUS_BAR_H
#define ZONE_BOTTOM               320
#define AGENT_ROW_CLAUDE_SUB_H    40
#define AGENT_ROW_CODEX_SUB_H     32
#define AGENT_ROW_API_H           24
#define AGENT_BOTTOM_SEPARATOR_H   2
#define AGENT_TO_SESSION_GAP       2
#define SESSION_ROW_H             24

// 顶部状态栏(design_spec.json status_bar):左=24h 时间;右=3 级信号柱→电池→百分比。
// minOfDay<0(未收时间帧)显示 "--:--"。信号柱源数据仍是 0..4 格(REQ-021 滞回),
// 此处压到 0..3 级;断开态三柱灰 + 整体 1Hz 红色慢闪(设计要求不恢复蓝牙 rune 图标)。
static void drawStatusBar(const BatteryInfo &bat, bool connected, uint8_t bars, int minOfDay) {
    cFillRect(0, 0, 170, STATUS_BAR_H, UI_BG);

    // ── 左:24h 时间 HH:MM(font1 6×8,x=6 top=5)──
    char tb[8];
    if (minOfDay < 0) snprintf(tb, sizeof(tb), "--:--");
    else              snprintf(tb, sizeof(tb), "%02d:%02d", minOfDay / 60, minOfDay % 60);
    cSetTextFont(1);
    cSetTextSize(1);
    cSetTextColor(UI_TEXT_PRIMARY, UI_BG);
    cSetCursor(6, 5);
    cPrint(tb);

    // 电量色(电池填充 + 百分比共用)
    uint16_t batColor = bat.percentageAvailable ? UI_LAMP_GREEN : UI_TEXT_SECONDARY;
    if (bat.fault || !bat.statusKnown) batColor = UI_LAMP_RED;
    else if (bat.thermalState == BAT_THERMAL_WARM) batColor = UI_LAMP_YELLOW;
    else if (bat.thermalState == BAT_THERMAL_COOL) batColor = UI_LAMP_BLUE;
    else if (bat.percentageAvailable && bat.pct <= 20) batColor = UI_LAMP_RED;
    else if (bat.percentageAvailable && bat.pct <= 50) batColor = UI_LAMP_YELLOW;

    // ── 信号柱:x=108 起,柱宽 2 间距 2,高 3/6/9,基线 y=15 ──
    {
        uint8_t lvl = connected ? (uint8_t)((bars * 3 + 2) / 4) : 0;   // 0..4 → 0..3
        if (lvl > 3) lvl = 3;
        // 断开态:三柱灰 + 1Hz 红色慢闪提示
        bool blinkRed = !connected && (millis() % 1000) < 500;
        static const int kH[3] = { 3, 6, 9 };
        for (int i = 0; i < 3; i++) {
            int xi = 108 + i * 4;
            uint16_t c;
            if (!connected) c = blinkRed ? UI_LAMP_RED : UI_TRACK;
            else            c = (i < lvl) ? UI_LAMP_GREEN : UI_TRACK;
            cFillRect(xi, 15 - kH[i], 2, kH[i], c);
        }
    }

    // ── 电池:x=125 y=6 w=18 h=9 + 正极 2px ──
    {
        const int bx = 125, by = 6, bw = 18, bh = 9;
        cDrawRect(bx, by, bw, bh, UI_TEXT_SECONDARY);
        cFillRect(bx + bw, by + 2, 2, bh - 4, UI_TEXT_SECONDARY);
        int fillW = bat.percentageAvailable ? (bw - 2) * bat.pct / 100 : 0;
        if (fillW > 0) cFillRect(bx + 1, by + 1, fillW, bh - 2, batColor);
        if (bat.charging) {
            int cxp = bx + bw / 2;
            cDrawLine(cxp + 2, by + 1,      cxp - 2, by + bh / 2, UI_LAMP_YELLOW);
            cDrawLine(cxp - 2, by + bh / 2, cxp + 1, by + bh / 2, UI_LAMP_YELLOW);
            cDrawLine(cxp + 1, by + bh / 2, cxp - 2, by + bh - 1, UI_LAMP_YELLOW);
        }
    }

    // ── 百分比:右边界 x=169,top=5;"100%" 从 x=146 起完整可见 ──
    {
        char pb[8];
        if (bat.percentageAvailable) snprintf(pb, sizeof(pb), "%u%%", bat.pct);
        else if (!bat.statusKnown) snprintf(pb, sizeof(pb), "!");
        // Until a valid ADC sample is available, use compact, distinct JEITA
        // labels: advisory WM/CL versus severe CD/HT; generic faults remain '!'.
        else if (bat.thermalState == BAT_THERMAL_WARM) snprintf(pb, sizeof(pb), "WM");
        else if (bat.thermalState == BAT_THERMAL_COOL) snprintf(pb, sizeof(pb), "CL");
        else if (bat.thermalState == BAT_THERMAL_COLD) snprintf(pb, sizeof(pb), "CD");
        else if (bat.thermalState == BAT_THERMAL_HOT) snprintf(pb, sizeof(pb), "HT");
        else if (bat.thermalState == BAT_THERMAL_UNKNOWN || bat.fault) snprintf(pb, sizeof(pb), "!");
        else if (bat.full) snprintf(pb, sizeof(pb), "OK");
        else snprintf(pb, sizeof(pb), "--");
        int pw = (int)strlen(pb) * 6;
        cSetTextColor((bat.full && bat.statusKnown) ? UI_LAMP_GREEN : batColor, UI_BG);
        cSetCursor(170 - pw, 5);   // 末像素落在 x=169;"100%" 从 x=146 起(spec)
        cPrint(pb);
    }
}

// 32×32 图标(RGB565 PROGMEM)
static void drawIcon32(int x, int y, const uint16_t *icon) {
    if (sprFull) {
        spr.setSwapBytes(true);
        spr.pushImage(x, y, AGENT_ICON_SIZE, AGENT_ICON_SIZE, icon);
        spr.setSwapBytes(false);
    } else {
        tft.setSwapBytes(true);
        tft.pushImage(x, y, AGENT_ICON_SIZE, AGENT_ICON_SIZE, icon);
        tft.setSwapBytes(false);
    }
}

// 14×14 agent 图标(所有 Agent 行通用):32×32 最近邻降采样,init 预生成;
// 逐像素绘制且黑色视作透明(icons 为黑底合成,UI_AGENT_BG 上不能出现黑方块)
static uint16_t s_icon14[3][14 * 14];
static void buildIcon14() {
    for (int a = 0; a < 3; a++) {
        const uint16_t *src = a == 2 ? workbuddyIcon32
                            : (a == 1 ? codexIcon32 : claudeIcon32);
        for (int sy = 0; sy < 14; sy++)
            for (int sx = 0; sx < 14; sx++)
                s_icon14[a][sy * 14 + sx] =
                    src[(sy * 32 / 14) * AGENT_ICON_SIZE + (sx * 32 / 14)];
    }
}
static void drawAgentIcon14(int x, int y, uint8_t agentId) {
    if (agentId != AGENT_CLAUDE_CODE && agentId != AGENT_CODEX &&
        agentId != AGENT_WORKBUDDY) {
        cFillRoundRect(x, y, 14, 14, 4, UI_TRACK);
        cSetTextFont(1);
        cSetTextSize(1);
        cSetTextColor(UI_TEXT_PRIMARY, UI_TRACK);
        cSetCursor(x + 4, y + 3);
        cPrint("A");
        return;
    }
    const uint16_t *icon = s_icon14[agentId == AGENT_WORKBUDDY ? 2
                                    : (agentId == AGENT_CODEX ? 1 : 0)];
    for (int sy = 0; sy < 14; sy++)
        for (int sx = 0; sx < 14; sx++) {
            uint16_t c = icon[sy * 14 + sx];
            if (c != 0) cDrawPixel(x + sx, y + sy, c);
        }
}

static const char *agentFallbackName(uint8_t id, bool full) {
    if (id == AGENT_CLAUDE_CODE) return full ? "Claude Code" : "Claude";
    if (id == AGENT_CODEX) return "Codex";
    if (id == AGENT_WORKBUDDY) return "WorkBuddy";
    return "Agent";
}
static const char *agentName(const AgentInfoV5 &a, bool full = true) {
    return a.displayName[0] ? a.displayName : agentFallbackName(a.agentId, full);
}

// 身份 + 计费模式 → 行高(README §6);drawAgentZone 与 ui_session_vis_rows
// 必须共用本函数,否则会话滚动钳制与实际可视行数失配
static inline int agentRowHeight(const AgentInfoV5 &a) {
    if (a.metricKind == V5_AGENT_METRIC_CUMULATIVE_CREDITS) return AGENT_ROW_API_H;
    if (a.metricKind == V5_AGENT_METRIC_COUNTS_ONLY) return AGENT_ROW_API_H;
    if (a.billingMode == V5_BILLING_API) return AGENT_ROW_API_H;
    return (a.agentId == AGENT_CLAUDE_CODE) ? AGENT_ROW_CLAUDE_SUB_H
                                            : AGENT_ROW_CODEX_SUB_H;
}

// 订阅用量行:标签(x=24)+ 圆角无边框条(x=44 w=84 h=6)+ 右对齐百分比(x=164)
// BUG-023:0xFF 哨兵判定必须在 clamp 之前;哨兵 → 空条 + "--"
static void drawUsageBarRow(int y, const char *label, uint8_t pct, uint16_t fill) {
    cSetTextFont(1);
    cSetTextSize(1);
    cSetTextColor(UI_TEXT_SECONDARY, UI_AGENT_BG);
    cSetCursor(24, y);
    cPrint(label);

    bool unknown = (pct == V5_USAGE_UNKNOWN);
    if (!unknown && pct > 100) pct = 100;
    cFillRoundRect(44, y + 1, 84, 6, 3, UI_TRACK);
    int fw = unknown ? 0 : 84 * pct / 100;
    if (fw > 0) cFillRoundRect(44, y + 1, (fw < 6) ? 6 : fw, 6, 3, fill);

    char t[8];
    if (unknown) snprintf(t, sizeof(t), "--");
    else         snprintf(t, sizeof(t), "%u%%", pct);
    int tw = (int)strlen(t) * 6;
    cSetTextColor((!unknown && pct >= 80) ? UI_LAMP_RED : UI_TEXT_PRIMARY, UI_AGENT_BG);
    cSetCursor(165 - tw, y);   // 末像素 x=164,与 S 列对齐
    cPrint(t);
}

// 订阅行头:图标 + 全名 + R 重置 + S 会话数(slice_agents_subscription 基准)
static void drawAgentHeader(int y, const AgentInfoV5 &a) {
    drawAgentIcon14(5, y + 2, a.agentId);
    cSetTextFont(1);
    cSetTextSize(1);
    cSetTextColor(UI_TEXT_PRIMARY, UI_AGENT_BG);
    cSetCursor(24, y + 5);
    cPrint(agentName(a));

    // R 重置(BUG-023:201..254 = 天数编码,codex 30d 窗口超 UInt8 小时上限)
    cSetTextColor(UI_TEXT_SECONDARY, UI_AGENT_BG);
    cSetCursor(96, y + 5);
    if (a.resetInHours == V5_RESET_UNKNOWN)        cPrint("R --");
    else if (a.resetInHours > V5_RESET_DAYS_BASE)  cPrintf("R %ud", a.resetInHours - V5_RESET_DAYS_BASE);
    else                                           cPrintf("R %uh", a.resetInHours);

    char sb[16];
    snprintf(sb, sizeof(sb), "S %u/%u", a.activeCount, a.totalCount);
    int sw = (int)strlen(sb) * 6;
    cSetTextColor(UI_TEXT_SECONDARY, UI_AGENT_BG);
    cSetCursor(165 - sw, y + 5);   // 末像素 x=164(spec session_count_right)
    cPrint(sb);
}

// Claude 订阅行 40px:头行 + 5h + 7d 双进度
static void drawAgentBlockClaudeSub(int y, const AgentInfoV5 &a) {
    drawAgentHeader(y, a);
    drawUsageBarRow(y + 17, "5h", a.usage5hPct, UI_USAGE_5H);
    drawUsageBarRow(y + 29, "7d", a.usage7dPct, UI_USAGE_7D);
}

// Codex 订阅行 32px:头行 + 单条进度(用户 2026-07-25 定:Codex 唯一有效窗口是 7d)
static void drawAgentBlockCodexSub(int y, const AgentInfoV5 &a) {
    drawAgentHeader(y, a);
    drawUsageBarRow(y + 20, "7d", a.usage7dPct, UI_USAGE_7D);
}

// API 计费行 24px(REQ-020 语义 + 新布局):图标|名|API 徽标|当日 token|今日|S
// 无 R、无百分比、无进度条;token UNKNOWN → "--"(徽标已表达 API 态)
static void drawAgentBlockApi(int y, const AgentInfoV5 &a) {
    drawAgentIcon14(6, y + 5, a.agentId);
    cSetTextFont(1);
    cSetTextSize(1);
    const char *nm = agentName(a, false);
    cSetTextColor(UI_TEXT_PRIMARY, UI_AGENT_BG);
    cSetCursor(25, y + 8);
    cPrint(nm);

    // API 徽标(spec 18×11;font1 "API"=18px,徽标放宽到 22px 留 2px 内边距)
    int bx = 25 + (int)strlen(nm) * 6 + 5;
    cFillRoundRect(bx, y + 6, 22, 11, 2, UI_TRACK);
    cSetTextColor(UI_CYAN, UI_TRACK);
    cSetCursor(bx + 2, y + 8);
    cPrint("API");

    // 当日 token(主数据,亮白;Mac 按本地时区自然日算好下发,固件只渲染)
    // 设计稿 token 后有 ~10px 小字"今日"标签;固件 CJK 最小 wqy16(32px 宽),
    // 与右侧 S 列必然重叠 → 本版省略该标签(语义由 API 徽标 + 文档承担),
    // 后续若引入 10~12px 小字库再补
    int tx = bx + 22 + 6;
    char tk[12];
    if (a.dailyTokens != V5_DAILY_TOKENS_UNKNOWN) formatTokensKM(a.dailyTokens, tk, sizeof(tk));
    else                                          snprintf(tk, sizeof(tk), "--");
    cSetTextColor(UI_TEXT_PRIMARY, UI_AGENT_BG);
    cSetCursor(tx, y + 8);
    cPrint(tk);

    char sb[16];
    snprintf(sb, sizeof(sb), "S %u/%u", a.activeCount, a.totalCount);
    int sw = (int)strlen(sb) * 6;
    cSetTextColor(UI_TEXT_SECONDARY, UI_AGENT_BG);
    cSetCursor(165 - sw, y + 8);
    cPrint(sb);
}

static void formatCredits(uint32_t cents, char *out, size_t cap) {
    if (cents == V5_DAILY_TOKENS_UNKNOWN) {
        snprintf(out, cap, "--");
    } else if (cents % 100 == 0) {
        snprintf(out, cap, "%lu", (unsigned long)(cents / 100));
    } else if (cents % 10 == 0) {
        snprintf(out, cap, "%lu.%lu", (unsigned long)(cents / 100),
                 (unsigned long)((cents / 10) % 10));
    } else {
        snprintf(out, cap, "%lu.%02lu", (unsigned long)(cents / 100),
                 (unsigned long)(cents % 100));
    }
}

static void drawAgentBlockCredits(int y, const AgentInfoV5 &a) {
    // WorkBuddy is intentionally a compact single row, matching the API card:
    // [icon] WorkBuddy PT 58.24                         S 0/3
    drawAgentIcon14(6, y + 5, a.agentId);
    cSetTextFont(1);
    cSetTextSize(1);
    cSetTextColor(UI_TEXT_PRIMARY, UI_AGENT_BG);
    cSetCursor(25, y + 8);
    cPrint(agentName(a));

    cSetTextColor(UI_CYAN, UI_AGENT_BG);
    cSetCursor(84, y + 8);
    cPrint("PT");

    char value[20];
    formatCredits(a.dailyTokens, value, sizeof(value));
    cSetTextColor(UI_TEXT_PRIMARY, UI_AGENT_BG);
    cSetCursor(100, y + 8);
    cPrint(value);

    char sb[16];
    snprintf(sb, sizeof(sb), "S %u/%u", a.activeCount, a.totalCount);
    int sw = (int)strlen(sb) * 6;
    cSetTextColor(UI_TEXT_SECONDARY, UI_AGENT_BG);
    cSetCursor(165 - sw, y + 8);
    cPrint(sb);
}

static void drawAgentBlockCounts(int y, const AgentInfoV5 &a) {
    drawAgentIcon14(6, y + 5, a.agentId);
    cSetTextFont(1);
    cSetTextSize(1);
    cSetTextColor(UI_TEXT_PRIMARY, UI_AGENT_BG);
    cSetCursor(25, y + 8);
    cPrint(agentName(a));
    char sb[16];
    snprintf(sb, sizeof(sb), "S %u/%u", a.activeCount, a.totalCount);
    int sw = (int)strlen(sb) * 6;
    cSetTextColor(UI_TEXT_SECONDARY, UI_AGENT_BG);
    cSetCursor(165 - sw, y + 8);
    cPrint(sb);
}

// Agent 信息区:全宽 UI_AGENT_BG、行间无分隔线、底部 2px 横线(README §6)。
// BUG-026:0 会话也展示用量,S 0/0 如实显示。返回会话列表起始 y(含 2px 呼吸间隔)。
static int drawAgentZone(const V5Status &st) {
    int y = ZONE_TOP;
    int n = (st.agentCount < V5_MAX_AGENTS) ? st.agentCount : V5_MAX_AGENTS;
    int totalH = 0;
    for (int i = 0; i < n; i++) totalH += agentRowHeight(st.agents[i]);
    cFillRect(0, y, 170, totalH, UI_AGENT_BG);
    for (int i = 0; i < n; i++) {
        const AgentInfoV5 &a = st.agents[i];
        if (a.metricKind == V5_AGENT_METRIC_CUMULATIVE_CREDITS) drawAgentBlockCredits(y, a);
        else if (a.metricKind == V5_AGENT_METRIC_COUNTS_ONLY) drawAgentBlockCounts(y, a);
        else if (a.billingMode == V5_BILLING_API) drawAgentBlockApi(y, a);
        else if (a.agentId == AGENT_CLAUDE_CODE) drawAgentBlockClaudeSub(y, a);
        else                                     drawAgentBlockCodexSub(y, a);
        y += agentRowHeight(a);
    }
    cFillRect(0, y, 170, AGENT_BOTTOM_SEPARATOR_H, UI_SEPARATOR);
    return y + AGENT_BOTTOM_SEPARATOR_H + AGENT_TO_SESSION_GAP;
}

// REQ-030:无 Agent 不是“空/加载中”，而是基础语音输入已就绪。
// drawWaveLetter 在 Splash 区段实现；yOffset 让首页 Logo 在状态栏下方复用同一套字母切片。
static void drawWaveLetter(int idx, float p, int yOffset);

static void drawBasicReadyBluetoothIcon(int x, int y) {
    // 简化蓝牙 rune，避免新增位图资源。
    cDrawLine(x,     y - 10, x + 8, y - 2, UI_LAMP_GREEN);
    cDrawLine(x + 8, y - 2,  x,     y + 6, UI_LAMP_GREEN);
    cDrawLine(x,     y + 6, x,     y - 10, UI_LAMP_GREEN);
    cDrawLine(x,     y - 10, x + 8, y + 6, UI_LAMP_GREEN);
    cDrawLine(x - 5, y - 6, x + 8, y + 6, UI_LAMP_GREEN);
    cDrawLine(x - 5, y + 2, x + 8, y - 2, UI_LAMP_GREEN);
}

static void drawBasicReadyMicIcon(int x, int y) {
    // 胶囊麦克风 + U 形支架，复用现有矢量绘制路径。
    cFillRoundRect(x - 4, y - 10, 8, 15, 4, VC_CYAN);
    cDrawRoundRect(x - 4, y - 10, 8, 15, 4, UI_TEXT_PRIMARY);
    cDrawLine(x - 8, y, x - 8, y + 3, VC_CYAN);
    cDrawLine(x + 8, y, x + 8, y + 3, VC_CYAN);
    cDrawLine(x - 8, y + 3, x - 4, y + 8, VC_CYAN);
    cDrawLine(x + 8, y + 3, x + 4, y + 8, VC_CYAN);
    cDrawFastHLine(x - 4, y + 8, 9, VC_CYAN);
    cDrawLine(x, y + 8, x, y + 12, VC_CYAN);
    cDrawFastHLine(x - 5, y + 12, 11, VC_CYAN);
}

static void drawBasicReadyPage() {
    // 上半屏 Logo 使用 Splash 原图；向下偏 7px 留出状态栏，字母每 7.5 秒跳动一次。
    static const int kLogoTop = 24;
    static const int kLogoYOffset = kLogoTop - 17;
    uint32_t cyc = (uint32_t)(millis() % 7500UL);
    bool wave = cyc >= 3500 && cyc < 4880;
    if (!wave) {
        cDrawImage(33, kLogoTop, SPLASH_LOGO_W, SPLASH_LOGO_H, splashLogo104);
    } else {
        cFillRect(33, kLogoTop, SPLASH_LOGO_W, SPLASH_LOGO_H, UI_BG);
        cDrawImage(EVERYTHING_X, EVERYTHING_Y + kLogoYOffset,
                   EVERYTHING_W, EVERYTHING_H, splashEverything);
        for (int i = 0; i < 4; i++) {
            int32_t local = (int32_t)cyc - 3500 - i * 220;
            float p = (local < 0 || local >= 720) ? 0.0f
                    : sinf((float)local / 720.0f * 3.14159f);
            drawWaveLetter(i, p, kLogoYOffset);
        }
    }

    cDrawFastHLine(35, 195, 100, UI_ROW_DIVIDER);

    // 卡 1：明确连接已完成；拆为两行保证英文在 170px 屏上不截断。
    cFillRoundRect(18, 204, 134, 39, 7, MD_BG);
    cDrawRoundRect(18, 204, 134, 39, 7, SP_EDGE_CON);
    drawBasicReadyBluetoothIcon(35, 222);
    cDrawCJK12Centered(100, 209, i18nText(UI_STR_BASIC_BLUETOOTH), UI_TEXT_PRIMARY, MD_BG);
    cDrawCJK12Centered(100, 222, i18nText(UI_STR_BASIC_CONNECTED), SP_TEXT_CON, MD_BG);

    // 卡 2：说明默认可直接长按说话；没有额外菜单或选择态。
    cFillRoundRect(18, 251, 134, 39, 7, MD_BG);
    cDrawRoundRect(18, 251, 134, 39, 7, VC_PANEL_BORDER);
    drawBasicReadyMicIcon(35, 269);
    cDrawCJK12Centered(100, 256, i18nText(UI_STR_BASIC_SPEAK_READY), UI_TEXT_PRIMARY, MD_BG);
    cDrawCJK12Centered(100, 269, i18nText(UI_STR_BASIC_HOLD_TO_TALK), VC_CYAN, MD_BG);
}

// ── 状态灯样式(REQ-009 8 态语义 + 新调色板动效参数,spec lamp_animation)──
//   绿=正常 黄=needs_review 红=permission/blocked 灰=paused/stale 蓝=thinking
struct DotStyle { uint16_t color; int r; float bright; };

static DotStyle dotStyleFor(uint8_t state, unsigned long now) {
    DotStyle d = { UI_LAMP_GREEN, 5, 1.0f };
    float slow = (float)(now % 1600) / 1600.0f;   // 慢周期 1.6s(全局共享相位)
    float fast = (float)(now % 400) / 400.0f;     // 快周期 0.4s
    switch (state) {
        case SDS_READY:
            break;
        case SDS_ACTIVE:
            d.bright = 0.45f + 0.55f * fabsf(sinf(slow * 3.14159f));
            break;
        case SDS_COMPLETED:
            if ((now % 1000) > 600) d.bright = 0.25f;
            break;
        case SDS_STALE:
            d.color  = UI_LAMP_GRAY;
            d.bright = (slow < 0.5f) ? 1.0f : 0.40f;
            break;
        case SDS_NEEDS_REVIEW:
            d.color  = UI_LAMP_YELLOW;
            d.bright = (slow < 0.5f) ? 1.0f : 0.35f;
            break;
        case SDS_PERMISSION:
            d.color  = UI_LAMP_RED;
            d.bright = (slow < 0.5f) ? 1.0f : 0.35f;
            d.r      = (slow < 0.5f) ? 5 : 3;      // 半径 5/3 缩放
            break;
        case SDS_BLOCKED:
            d.color  = UI_LAMP_RED;
            d.bright = (fast < 0.5f) ? 1.0f : 0.20f;
            break;
        case SDS_THINKING:
            d.color  = UI_LAMP_BLUE;
            d.bright = 0.60f + 0.40f * fabsf(sinf(slow * 3.14159f));
            break;
        case SDS_PAUSED:
        default:
            d.color = UI_LAMP_GRAY;
            break;
    }
    d.color = scale565(d.color, d.bright);
    return d;
}

// 交通灯组件(README §7.2):14×14 圆角灯座 + 四角固定点 + 彩色灯芯 + 高光。
// 只有灯芯与高光做动画;灯座、描边、固定点静止。
static void drawSessionLamp(int rowY, const DotStyle &ds) {
    cFillRoundRect(5, rowY + 5, 14, 14, 2, UI_LAMP_HOUSING);
    cDrawRoundRect(5, rowY + 5, 14, 14, 2, UI_LAMP_BORDER);
    cFillCircle(7,  rowY + 7,  1, UI_LAMP_SCREW);
    cFillCircle(17, rowY + 7,  1, UI_LAMP_SCREW);
    cFillCircle(7,  rowY + 17, 1, UI_LAMP_SCREW);
    cFillCircle(17, rowY + 17, 1, UI_LAMP_SCREW);
    cFillCircle(12, rowY + 12, ds.r, ds.color);
    cFillCircle(11, rowY + 11, 1, scale565(UI_TEXT_PRIMARY, ds.bright));   // 高光随亮度,不独立闪
}

// 会话列表区(README §7/§8):每行 24px = 交通灯 + 名称(主文字色)+ ctx%
//   直通行:全宽 UI_SELECTED_BG 纯色带(取代旧 x=17 起会话色高亮,REQ-016 会话色规则废止)
//   框选行:上下两条 1px 白线,左右不闭合(不再整行线框,避免与色带混淆)
//   滚动:sel.scrollTop 起画满可视行数
static void drawSessionZone(const V5Status &st, const UiListSel &sel, int yTop) {
    int y0 = yTop;
    int visRows = (ZONE_BOTTOM - y0) / SESSION_ROW_H;
    if (visRows < 1) visRows = 1;

    unsigned long now = millis();
    uint8_t start = sel.scrollTop;
    int totalRows = ui_row_count(st, sel.inactiveExpanded);
    if (start >= totalRows) start = 0;

    for (int vi = 0; vi < visRows; vi++) {
        int row = (int)start + vi;
        if (row >= totalRows) break;
        int rowY = y0 + vi * SESSION_ROW_H;
        int si = ui_row_to_session(st, sel.inactiveExpanded, row);
        if (si == -1) {                        // T-034 非活跃标签行
            char lb[32];
            char countLabel[28];
            snprintf(countLabel, sizeof(countLabel), i18nText(UI_STR_HOME_INACTIVE_COUNT),
                     ui_inactive_shown(st));
            snprintf(lb, sizeof(lb), "%s %s", sel.inactiveExpanded ? "v" : ">", countLabel);
            cDrawCJK(8, rowY + 4, lb, UI_TEXT_SECONDARY, UI_BG);
            cDrawFastHLine(12, rowY + SESSION_ROW_H - 1, 152, UI_ROW_DIVIDER);
            if (sel.visible && sel.framedIdx == (int8_t)row) {
                cDrawFastHLine(0, rowY, 170, TFT_WHITE);
                cDrawFastHLine(0, rowY + SESSION_ROW_H - 1, 170, TFT_WHITE);
            }
            continue;
        }
        if (si < 0) break;
        uint8_t i = (uint8_t)si;
        const SessionV5 &s = st.sessions[i];

        bool isExclusive = (st.exclusiveIdx >= 0) && ((uint8_t)st.exclusiveIdx == i);
        uint16_t rowBg = isExclusive ? UI_SELECTED_BG : UI_BG;
        if (isExclusive) {
            cFillRect(0, rowY, 170, SESSION_ROW_H, rowBg);   // 全宽色带,无边框
        }

        // 状态灯(色带之上重画,永远可见)
        drawSessionLamp(rowY, dotStyleFor(s.state, now));

        // ctx 已用%(REQ-017 语义),右边界 x=166;unknown "--";≥80% 红字告警
        char cb[8];
        if (s.ctxPct == V5_CTX_UNKNOWN) snprintf(cb, sizeof(cb), "--");
        else                            snprintf(cb, sizeof(cb), "%u%%", s.ctxPct);
        int cbw = (int)strlen(cb) * 6;
        cSetTextFont(1);
        cSetTextSize(1);
        uint16_t ctxColor = isExclusive ? UI_TEXT_PRIMARY : UI_TEXT_SECONDARY;
        if (!isExclusive && s.ctxPct != V5_CTX_UNKNOWN && s.ctxPct >= 80) ctxColor = UI_LAMP_RED;
        cSetTextColor(ctxColor, rowBg);
        cSetCursor(167 - cbw, rowY + 8);   // 末像素 x=166(spec context.right)
        cPrint(cb);

        // 名称(CJK):x=24 到 ctx% 左边界留 6px;统一主文字色(状态色只出现在灯芯)
        int nameMax = (167 - cbw) - 24 - 6;
        char nameBuf[64];
        truncUtf8ByPixels(nameBuf, sizeof(nameBuf), s.name, nameMax, true);
        cDrawCJK(24, rowY + 4, nameBuf, UI_TEXT_PRIMARY, rowBg);

        // 行间细分隔线(x=12..163;色带行不画)
        if (!isExclusive) {
            cDrawFastHLine(12, rowY + SESSION_ROW_H - 1, 152, UI_ROW_DIVIDER);
        }

        // 框选(REQ-013 交互不变,视觉改上下白线;落在直通行时画在色带上)
        // T-034:框选判据按**显示行** row(含非活跃标签行);isExclusive 仍按会话下标 i
        if (sel.visible && sel.framedIdx == (int8_t)row) {
            cDrawFastHLine(0, rowY, 170, TFT_WHITE);
            cDrawFastHLine(0, rowY + SESSION_ROW_H - 1, 170, TFT_WHITE);
        }
    }

    // 溢出指示:上/下箭头
    if (start > 0) {
        cSetTextFont(1); cSetTextColor(UI_TEXT_SECONDARY, UI_BG);
        cSetCursor(160, y0 + 1); cPrint("^");
    }
    if (totalRows - (int)start > visRows) {
        cSetTextFont(1); cSetTextColor(UI_TEXT_SECONDARY, UI_BG);
        cSetCursor(160, ZONE_BOTTOM - 9); cPrint("v");
    }
}

// 会话列表可视行数(输入侧滚动钳制;与 drawAgentZone/drawSessionZone 几何一致)
int ui_session_vis_rows(const V5Status &st) {
    int top = ZONE_TOP;
    int n = (st.agentCount < V5_MAX_AGENTS) ? st.agentCount : V5_MAX_AGENTS;
    for (int i = 0; i < n; i++) top += agentRowHeight(st.agents[i]);
    top += AGENT_BOTTOM_SEPARATOR_H + AGENT_TO_SESSION_GAP;
    int rows = (ZONE_BOTTOM - top) / SESSION_ROW_H;
    return rows < 1 ? 1 : rows;
}

// ══════════════════════════════════════════════════════════
// 模式窗口(方框比主界面小一圈,盖在主界面上)
// ══════════════════════════════════════════════════════════

// ══════════════════════════════════════════════════════════
// REQ-023 二期:统一模态窗壳(README_MODAL §3/§7)
//   几何:窗口 (9,50,152,210) r7;标题栏 (10,51,150,25) 顶圆角 6;
//         内容区 y=78..228;底部分隔线 y=229;底栏 (10,230,150,29)
//   进入模态先把整屏压暗到 38% 亮度,再画窗口(每帧执行,主界面每帧重绘)
// ══════════════════════════════════════════════════════════

// UTF-8 安全截断/扫描(定义在审批段;Prompt 列表也用)
static int  apvUtf8Len(const char *s);
static void apvTruncPx(char *dst, size_t dstCap, const char *src, int maxPx);

// 整屏压暗(sprite 帧缓冲直接改;直绘 fallback 无法读回则跳过,README §4 允许)
static void dimScreenForModal() {
    if (!sprFull) return;
    uint16_t *buf = (uint16_t *)spr.getPointer();
    if (!buf) return;
    static uint8_t lut5[32], lut6[64];
    static bool lutReady = false;
    if (!lutReady) {
        for (int i = 0; i < 32; i++) lut5[i] = (uint8_t)(i * 38 / 100);
        for (int i = 0; i < 64; i++) lut6[i] = (uint8_t)(i * 38 / 100);
        lutReady = true;
    }
    for (int i = 0; i < 170 * 320; i++) {
        uint16_t c = buf[i];
        c = (uint16_t)((c >> 8) | (c << 8));   // sprite 内存为面板字节序
        c = (uint16_t)((lut5[(c >> 11) & 0x1F] << 11) |
                       (lut6[(c >> 5) & 0x3F] << 5) |
                        lut5[c & 0x1F]);
        buf[i] = (uint16_t)((c >> 8) | (c << 8));
    }
}

// 模态壳:压暗 + 实底 + 边框 + 标题栏 + 底部分隔线。
// approval=true 时紫标题栏且不画标题文字/青短条(标题栏内容由审批窗自画)
static void drawModalShell(const char *title, bool approval) {
    dimScreenForModal();
    cFillRoundRect(9, 50, 152, 210, 7, MD_BG);
    cDrawRoundRect(9, 50, 152, 210, 7, approval ? MD_BORDER_P : MD_BORDER_C);
    uint16_t tb = approval ? MD_TITLE_PUR : MD_TITLE_BG;
    cFillRoundRect(10, 51, 150, 25, 6, tb);
    cFillRect(10, 70, 150, 6, tb);              // 盖掉标题栏底部圆角
    if (!approval && title) {
        cFillRect(10, 57, 3, 13, MD_BORDER_C);  // 标题左青色短条
        cDrawCJK12(18, 58, title, MD_TEXT_MAIN, tb);
    }
    cDrawFastHLine(10, 229, 150, UI_TRACK);     // 底部上分隔线
}

// 底栏键帽:圆角 4px 键帽 + 灰标签;返回本组占用宽度
static int drawFooterKeyAt(int x, int y, int h,
                           const char *cap, const char *label, uint16_t capEdge) {
    int cw = cjk12Width(cap) + 8;
    cFillRoundRect(x, y, cw, h, 4, MD_TITLE_BG);
    cDrawRoundRect(x, y, cw, h, 4, capEdge);
    int textY = y + (h >= 17 ? 3 : 1);
    cDrawCJK12(x + 4, textY, cap, MD_TEXT_MAIN, MD_TITLE_BG);
    int lx = x + cw + 3;
    cDrawCJK12(lx, textY, label, MD_TEXT_MUTED, MD_BG);
    return (lx + cjk12Width(label)) - x;
}

static int drawFooterKey(int x, const char *cap, const char *label, uint16_t capEdge) {
    return drawFooterKeyAt(x, 234, 17, cap, label, capEdge);
}

static int footerKeyWidth(const char *cap, const char *label) {
    return cjk12Width(cap) + 8 + 3 + cjk12Width(label);
}

// 英文标签较长时把第三组移到第二行;中文仍保持原单行布局。
static void drawFooterTriplet(const char *cap1, const char *label1, uint16_t edge1,
                              const char *cap2, const char *label2, uint16_t edge2,
                              const char *cap3, const char *label3, uint16_t edge3) {
    int w1 = footerKeyWidth(cap1, label1);
    int w2 = footerKeyWidth(cap2, label2);
    int w3 = footerKeyWidth(cap3, label3);
    if (w1 + w2 + w3 + 10 <= 146) {
        int x = 12;
        x += drawFooterKey(x, cap1, label1, edge1) + 5;
        x += drawFooterKey(x, cap2, label2, edge2) + 5;
        drawFooterKey(x, cap3, label3, edge3);
        return;
    }
    int x = 12;
    x += drawFooterKeyAt(x, 231, 14, cap1, label1, edge1) + 5;
    drawFooterKeyAt(x, 231, 14, cap2, label2, edge2);
    drawFooterKeyAt(12, 246, 14, cap3, label3, edge3);
}

// REQ-011: Prompt 选择窗口(旋钮选择,按旋钮发送;第 0 条 = 内置"AI推荐")
// 行高 26 / 选中 27;可视 5 行,超出随选中项滚动;右上角全列表计数
static void drawPromptWindow(const V5Config &cfg, const UiModeCtx &ctx) {
    drawModalShell(i18nText(UI_STR_PROMPT_TITLE), false);

    if (ctx.promptLoading) {
        cSetFont12();
        cDrawCJK12(24, 126, i18nText(UI_STR_PROMPT_LOADING), MD_TEXT_BODY, MD_BG);
        const int active = (millis() / 260) % 3;
        for (int i = 0; i < 3; i++) {
            cFillCircle(72 + i * 13, 158, 3, i == active ? MD_SEL_ACC : MD_TEXT_MUTED);
        }
        drawFooterKey(12, "B", i18nText(UI_STR_COMMON_EXIT), MD_TEXT_MUTED);
        return;
    }

    int8_t sel = ctx.promptSel;
    int total = ctx.promptDynamic ? ctx.promptCount : 1 + (cfg.valid ? cfg.promptCount : 0);
    // 标题栏右上角 current/total(font1)
    {
        char cb[12];
        snprintf(cb, sizeof(cb), "%d / %d", (int)sel + 1, total);
        int w = (int)strlen(cb) * 6;
        cSetTextFont(1);
        cSetTextSize(1);
        cSetTextColor(MD_TEXT_MUTED, MD_TITLE_BG);
        cSetCursor(154 - w, 60);
        cPrint(cb);
    }

    const int visRows = 5;   // (229-82)/26
    int scrollTop = (int)sel - 2;                       // 选中项居中跟随
    if (scrollTop > total - visRows) scrollTop = total - visRows;
    if (scrollTop < 0) scrollTop = 0;

    for (int vi = 0; vi < visRows; vi++) {
        int i = scrollTop + vi;
        if (i >= total) break;
        int rowY = 82 + vi * 26;
        const char *title = ctx.promptDynamic ? ctx.promptTitles[i]
            : ((i == 0) ? i18nText(UI_STR_PROMPT_AI_RECOMMENDED) : cfg.promptTitles[i - 1]);
        char buf[40];
        bool hi = ((int)sel == i);
        if (hi) {
            cFillRoundRect(12, rowY, 146, 27, 5, MD_SEL_BG);
            cDrawRoundRect(12, rowY, 146, 27, 5, MD_BORDER_C);
            cFillRect(13, rowY + 5, 3, 17, MD_SEL_ACC);      // 左强调条
            cSetFont12();
            apvTruncPx(buf, sizeof(buf), title, 118);
            cSetFont16();
            cDrawCJK12(22, rowY + 7, buf, TFT_WHITE, MD_SEL_BG);
            cSetTextFont(1);
            cSetTextSize(1);
            cSetTextColor(MD_SEL_ACC, MD_SEL_BG);
            cSetCursor(148, rowY + 10);
            cPrint(">");
        } else {
            cSetFont12();
            apvTruncPx(buf, sizeof(buf), title, 128);
            cSetFont16();
            cDrawCJK12(22, rowY + 7, buf, MD_TEXT_BODY, MD_BG);
            cDrawFastHLine(14, rowY + 25, 142, UI_ROW_DIVIDER);
        }
    }

    // 底栏键帽(按实际语义:发送=按旋钮,REQ-011;设计稿"A 确认"与固件按键不符)
    drawFooterTriplet(
        i18nText(UI_STR_COMMON_ROTATE), i18nText(UI_STR_COMMON_SELECT), MD_BORDER_C,
        i18nText(UI_STR_COMMON_PRESS), i18nText(UI_STR_COMMON_SEND), MD_BORDER_C,
        "B", i18nText(UI_STR_COMMON_EXIT), MD_TEXT_MUTED
    );
}

static void drawInputAssistantWindow(const V5Config &cfg, const UiModeCtx &ctx) {
    (void)cfg;
    drawModalShell(i18nText(UI_STR_ASSISTANT_TITLE), false);
    if (ctx.assistantState == 0 || ctx.assistantState == 2) {
        const char *label = ctx.assistantState == 0
            ? i18nText(UI_STR_ASSISTANT_READING) : i18nText(UI_STR_ASSISTANT_REWRITING);
        cDrawCJK12(24, 126, label, MD_TEXT_BODY, MD_BG);
        const int active = (millis() / 260) % 3;
        for (int i = 0; i < 3; i++) cFillCircle(72 + i * 13, 158, 3, i == active ? MD_SEL_ACC : MD_TEXT_MUTED);
        drawFooterKey(12, "C", i18nText(UI_STR_ASSISTANT_CANCEL), MD_TEXT_MUTED);
        return;
    }
    if (ctx.assistantState >= 3) {
        const char *label = ctx.assistantState == 3
            ? i18nText(UI_STR_ASSISTANT_FAILED)
            : (ctx.assistantState == 5
               ? i18nText(UI_STR_ASSISTANT_REPLACED) : i18nText(UI_STR_ASSISTANT_UNAVAILABLE));
        cDrawCJK12(24, 136, label, ctx.assistantState == 5 ? MD_ALLOW : UI_LAMP_RED, MD_BG);
        return;
    }

    char preview[49];
    apvTruncPx(preview, sizeof(preview), ctx.assistantPreview, 134);
    cDrawCJK12(18, 81, ctx.assistantSelectedScope
        ? i18nText(UI_STR_ASSISTANT_SELECTED) : i18nText(UI_STR_ASSISTANT_ALL), MD_TEXT_MUTED, MD_BG);
    cDrawCJK12(18, 96, preview, MD_TEXT_BODY, MD_BG);
    cDrawFastHLine(14, 113, 142, UI_ROW_DIVIDER);

    const int visible = 4;
    int scrollTop = ctx.assistantSel - 1;
    if (scrollTop > (int)ctx.assistantCount - visible) scrollTop = ctx.assistantCount - visible;
    if (scrollTop < 0) scrollTop = 0;
    for (int vi = 0; vi < visible; vi++) {
        int i = scrollTop + vi; if (i >= ctx.assistantCount) break;
        int y = 117 + vi * 27; bool hi = i == ctx.assistantSel;
        char title[40]; apvTruncPx(title, sizeof(title), ctx.assistantTitles[i], 118);
        if (hi) {
            cFillRoundRect(12, y, 146, 26, 5, MD_SEL_BG);
            cDrawRoundRect(12, y, 146, 26, 5, MD_BORDER_C);
            cFillRect(13, y + 5, 3, 16, MD_SEL_ACC);
        }
        cDrawCJK12(22, y + 6, title, hi ? TFT_WHITE : MD_TEXT_BODY, hi ? MD_SEL_BG : MD_BG);
    }
    int x = 12;
    if (ctx.assistantSelectedScope)
        x += drawFooterKey(x, "B", i18nText(UI_STR_ASSISTANT_WHOLE), MD_TEXT_MUTED) + 5;
    drawFooterKey(x, "C", i18nText(UI_STR_ASSISTANT_CANCEL), MD_TEXT_MUTED);
}

static int splitActionLine(const char *src, char first[49], char second[49], int maxPx);

static void drawApplicationSwitcherWindow(const ApplicationSwitcherDefinition &apps) {
    drawModalShell(apps.title[0] ? apps.title : i18nText(UI_STR_APP_SWITCHER_TITLE), false);
    if (apps.loading) {
        cDrawCJK12(24, 126, i18nText(UI_STR_APP_SWITCHER_LOADING), MD_TEXT_BODY, MD_BG);
        return;
    }
    if (!apps.valid || apps.count == 0) {
        cDrawCJK12(24, 126, i18nText(UI_STR_APP_SWITCHER_NO_APPS), MD_TEXT_MUTED, MD_BG);
        return;
    }

    const int visible = 5;
    int scrollTop = apps.selected - 2;
    if (scrollTop > (int)apps.count - visible) scrollTop = apps.count - visible;
    if (scrollTop < 0) scrollTop = 0;
    for (int row = 0; row < visible; row++) {
        const int index = scrollTop + row;
        if (index >= apps.count) break;
        const int y = 75 + row * 28;
        const bool highlighted = index == apps.selected;
        char name[APP_SWITCHER_NAME_CAP];
        apvTruncPx(name, sizeof(name), apps.names[index], 118);
        if (highlighted) {
            cFillRoundRect(12, y, 146, 26, 5, MD_SEL_BG);
            cDrawRoundRect(12, y, 146, 26, 5, MD_BORDER_C);
            cFillRect(13, y + 5, 3, 16, MD_SEL_ACC);
        }
        cDrawCJK12(22, y + 6, name,
                   highlighted ? TFT_WHITE : MD_TEXT_BODY,
                   highlighted ? MD_SEL_BG : MD_BG);
    }
    char counter[12];
    snprintf(counter, sizeof(counter), "%d/%u", (int)apps.selected + 1, apps.count);
    cDrawCJK12(14, 218, counter, MD_TEXT_MUTED, MD_BG);
    if (apps.footer[0]) {
        char footer[APP_SWITCHER_FOOTER_CAP];
        apvTruncPx(footer, sizeof(footer), apps.footer, 104);
        cDrawCJK12(48, 218, footer, MD_TEXT_MUTED, MD_BG);
    }
}

// REQ-012: 文字编辑模式窗口(按键定义 + 回显;2026-07-10 用户改版键位)
static void drawEditWindow(const char *echo) {
    drawModalShell(i18nText(UI_STR_EDIT_TITLE), false);

    const UiStringId kLineIds[] = {
        UI_STR_EDIT_HELP_ROTATE_CURSOR,
        UI_STR_EDIT_HELP_A_ACTIONS,
        UI_STR_EDIT_HELP_B_ACTIONS,
        UI_STR_EDIT_HELP_B_HOLD,
        UI_STR_EDIT_HELP_A_HOLD,
        UI_STR_EDIT_HELP_PRESS_EXIT,
    };
    int y = 84;
    for (size_t i = 0; i < sizeof(kLineIds) / sizeof(kLineIds[0]); i++) {
        cFillCircle(20, y + 5, 1, MD_TEXT_MUTED);
        char first[49], second[49];
        int lineCount = splitActionLine(i18nText(kLineIds[i]), first, second, 126);
        cDrawCJK12(26, y, first, MD_TEXT_BODY, MD_BG);
        if (lineCount == 2) cDrawCJK12(26, y + 13, second, MD_TEXT_BODY, MD_BG);
        y += lineCount * 13 + 4;
    }
    // 按键回显(REQ-012)
    if (echo && echo[0]) {
        const char *keyLabel = i18nText(UI_STR_EDIT_KEY_LABEL);
        cDrawCJK12(26, y + 2, keyLabel, MD_TEXT_MUTED, MD_BG);
        cDrawCJK12(26 + cjk12Width(keyLabel) + 4, y + 2, echo, UI_LAMP_YELLOW, MD_BG);
    }

    // 底栏键帽(按实际语义:退出=按旋钮;设计稿"B 退出"与固件按键不符)
    drawFooterTriplet(
        i18nText(UI_STR_COMMON_ROTATE), i18nText(UI_STR_COMMON_CURSOR), MD_BORDER_C,
        "AB", i18nText(UI_STR_COMMON_UP_DOWN), MD_BORDER_C,
        i18nText(UI_STR_COMMON_PRESS), i18nText(UI_STR_COMMON_EXIT), MD_TEXT_MUTED
    );
}

static void trimActionPart(char *s) {
    if (!s) return;
    size_t start = 0;
    while (s[start] == ' ') start++;
    if (start > 0) memmove(s, s + start, strlen(s + start) + 1);
    size_t n = strlen(s);
    while (n > 0 && s[n - 1] == ' ') s[--n] = '\0';
}

// 已确认动作说明最多折成两行。优先在空格或 '/' 处分行,且绝不切断 UTF-8 字符。
static int splitActionLine(const char *src, char first[49], char second[49], int maxPx) {
    first[0] = second[0] = '\0';
    if (!src || !src[0]) return 0;
    size_t len = strnlen(src, 48);
    memcpy(first, src, len);
    first[len] = '\0';
    if (cjk12Width(first) <= maxPx) return 1;

    int best = -1;
    int bestScore = 0x7FFFFFFF;
    for (size_t i = 1; i < len; i++) {
        if ((((uint8_t)src[i]) & 0xC0) == 0x80) continue;
        bool preferred = src[i - 1] == ' ' || src[i - 1] == '/' || src[i] == ' ';
        if (!preferred) continue;
        char a[49] = {0}, b[49] = {0};
        memcpy(a, src, i);
        memcpy(b, src + i, len - i);
        trimActionPart(a);
        trimActionPart(b);
        int wa = cjk12Width(a), wb = cjk12Width(b);
        if (wa <= maxPx && wb <= maxPx) {
            int score = max(wa, wb) * 4 + abs(wa - wb);
            if (score < bestScore) { best = (int)i; bestScore = score; }
        }
    }
    // 极端情况下没有可用分隔符,才按完整 code point 寻找可容纳两行的断点。
    if (best < 0) {
        for (size_t i = 1; i < len; i++) {
            if ((((uint8_t)src[i]) & 0xC0) == 0x80) continue;
            char a[49] = {0}, b[49] = {0};
            memcpy(a, src, i);
            memcpy(b, src + i, len - i);
            int wa = cjk12Width(a), wb = cjk12Width(b);
            if (wa <= maxPx && wb <= maxPx) {
                int score = max(wa, wb) * 4 + abs(wa - wb);
                if (score < bestScore) { best = (int)i; bestScore = score; }
            }
        }
    }
    if (best < 0) return 1;  // 协议上限 48B 下不应发生;保留完整文字便于暴露布局问题。
    memcpy(first, src, (size_t)best);
    first[best] = '\0';
    memcpy(second, src + best, len - (size_t)best);
    second[len - (size_t)best] = '\0';
    trimActionPart(first);
    trimActionPart(second);
    return second[0] ? 2 : 1;
}

// Host 下发的通用动作模式窗口。A 键是全局语音键，不重复占用三行说明区。
static void drawActionModeWindow(const ActionModeDefinition &mode) {
    drawModalShell(mode.title[0] ? mode.title : i18nText(UI_STR_ACTION_FALLBACK_TITLE), false);
    int y = 84;
    for (uint8_t i = 0; i < 3; i++) {
        if (!mode.lines[i][0]) continue;
        cFillCircle(20, y + 5, 1, MD_TEXT_MUTED);
        char first[49], second[49];
        int lineCount = splitActionLine(mode.lines[i], first, second, 126);
        cDrawCJK12(26, y, first, MD_TEXT_BODY, MD_BG);
        if (lineCount == 2) cDrawCJK12(26, y + 14, second, MD_TEXT_BODY, MD_BG);
        y += lineCount == 2 ? 38 : 27;
    }
    if (mode.footer[0]) {
        char first[49], second[49];
        int lineCount = splitActionLine(mode.footer, first, second, 142);
        cDrawCJK12(14, lineCount == 2 ? 188 : 204, first, MD_TEXT_MUTED, MD_BG);
        if (lineCount == 2) cDrawCJK12(14, 202, second, MD_TEXT_MUTED, MD_BG);
    }
    int x = 18;
    x += drawFooterKey(x, "A", i18nText(UI_STR_COMMON_VOICE), MD_BORDER_C) + 5;
    drawFooterKey(x, i18nText(UI_STR_ACTION_HOLD_D), i18nText(UI_STR_COMMON_EXIT), MD_TEXT_MUTED);
}

// REQ-011: B 长按连删浮窗(计数动画:计数 + 退格脉冲条)
static void drawDeleteOverlay(uint16_t count) {
    const int BX = 30, BY = 120, BW = 110, BH = 74;
    cFillRect(BX, BY, BW, BH, UI_BG);
    cDrawRect(BX, BY, BW, BH, TFT_RED);
    cDrawCJK(BX + 8, BY + 6, i18nText(UI_STR_DELETE_REPEAT), TFT_WHITE, UI_BG);

    char buf[16];
    snprintf(buf, sizeof(buf), "x%u", count);
    cSetTextFont(2);
    cSetTextSize(2);
    cSetTextColor(TFT_RED, UI_BG);
    cSetCursor(BX + 8, BY + 28);
    cPrint(buf);
    cSetTextSize(1);

    // 脉冲条:随删除节奏左移的块(毫秒相位动画)
    int ph = (int)((millis() / 60) % (BW - 24));
    cFillRect(BX + 8, BY + BH - 14, BW - 16, 6, 0x2104);
    cFillRect(BX + 8 + (BW - 24) - ph, BY + BH - 14, 8, 6, TFT_RED);
}

// ══════════════════════════════════════════════════════════
// REQ-022: 设备端审批模态窗口(REQ-023 二期改版,README_MODAL §10)
//   统一模态壳 (9,50,152,210);标题栏紫 #6D35C5 + 边框 #A77BFF(设计稿定稿,
//   LED 保持 #8C00C8,同为紫色家族);风险外框语义保留:1=黄 2=红 覆盖紫边框;
//   正文改 wqy12 纯文本(行高 12,最多 11 行,末行省略号);
//   倒计时 ≥60s 白 M:SS / <60s 黄 NNs / <10s 白 1Hz 闪。
//   审批文本(tool/body/sessName)严禁走 truncUtf8ByPixels(内部 tmp[64] 会把
//   ≥64B 源串静默截断,tool 上限恰为 64B),以下用前向扫描的 UTF-8 安全实现。
// ══════════════════════════════════════════════════════════
static const ApprovalUiView *s_apvView = nullptr;

// 审批窗文字不能贴着右边框绘制。wqy12 的部分 ASCII/标点字形会有少量
// 右侧外伸，因此不能直接使用内容区的全部几何宽度。
static constexpr int APV_TEXT_X = 15;
static constexpr int APV_TEXT_MAX_PX = 128;
static constexpr int APV_SAFE_RIGHT = 147;
static constexpr int APV_TITLE_MAX_PX = 86;
static_assert(APV_TEXT_X + APV_TEXT_MAX_PX <= APV_SAFE_RIGHT,
              "approval text must retain a safe right gutter");

void ui_set_approval_view(const ApprovalUiView *v) {
    s_apvView = v;
}

// UTF-8 前向扫描:当前字节起的 codepoint 字节数(非法序列按 1 字节推进,防死循环)
static int apvUtf8Len(const char *s) {
    uint8_t c = (uint8_t)s[0];
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0) return 2;
    if ((c & 0xF0) == 0xE0) return 3;
    if ((c & 0xF8) == 0xF0) return 4;
    return 1;
}

// 按像素宽度截断(单行,UTF-8 安全,无 64 字节上限):前向逐 codepoint 累计宽度
static void apvTruncPx(char *dst, size_t dstCap, const char *src, int maxPx) {
    size_t o = 0;
    int used = 0;
    dst[0] = 0;
    if (!g_u8g2_ready || !src) return;
    for (const char *p = src; *p; ) {
        int n = apvUtf8Len(p);
        char cb[5];
        memcpy(cb, p, n);
        cb[n] = 0;
        int w = g_u8g2.getUTF8Width(cb);
        if (used + w > maxPx) break;
        if (o + (size_t)n + 1 > dstCap) break;
        memcpy(dst + o, cb, n);
        o += n;
        used += w;
        p += n;
    }
    dst[o] = 0;
}

// 逐行 wrap 绘制(wqy12,UTF-8 安全,README_MODAL §10):按像素宽换行,
// 尊重 \n;超过 maxLines 时末行退字符补 ".."。返回下一行的 y。
static int drawWrapped12(int x, int yTop, int maxPx, int lineH, int maxLines,
                         const char *src, uint16_t fg, uint16_t bg) {
    if (!g_u8g2_ready || !src || maxLines <= 0) return yTop;
    const char *p = src;
    int y = yTop, line = 0;
    while (*p && line < maxLines) {
        bool lastLine = (line == maxLines - 1);
        char buf[96];
        size_t o = 0;
        int used = 0;
        const char *lineStart = p;
        cSetFont12();
        while (*p) {
            if (*p == '\n') { p++; break; }
            int n = apvUtf8Len(p);
            char cb[5];
            memcpy(cb, p, n);
            cb[n] = 0;
            int w = g_u8g2.getUTF8Width(cb);
            if (used + w > maxPx) break;
            if (o + (size_t)n + 1 > sizeof(buf)) break;
            memcpy(buf + o, cb, n);
            o += n;
            used += w;
            p += n;
        }
        buf[o] = 0;
        if (p == lineStart && *p) { cSetFont16(); break; }   // 无进展防死循环
        if (lastLine && *p) {
            // 末行截断:退 codepoint 腾出 ".." 宽度(maxPx 窄于 ".." 时不追加,防越界)
            int dotsW = g_u8g2.getUTF8Width("..");
            if (dotsW <= maxPx) {
                while (o > 0 && used + dotsW > maxPx) {
                    do { o--; } while (o > 0 && ((buf[o] & 0xC0) == 0x80));
                    buf[o] = 0;
                    used = g_u8g2.getUTF8Width(buf);
                }
                if (o + 3 < sizeof(buf)) { buf[o] = '.'; buf[o + 1] = '.'; buf[o + 2] = 0; }
            }
        }
        cSetFont16();
        cDrawCJK12(x, y, buf, fg, bg);
        y += lineH;
        line++;
    }
    cSetFont16();
    return y;
}

static void drawApprovalWindow(const ApprovalUiView &v) {
    drawModalShell(nullptr, true);

    // 风险外框(REQ-022 D1 语义保留,README §13"保留业务逻辑"):1=黄 2=红 覆盖紫框
    if (v.riskLevel == 1)      cDrawRoundRect(9, 50, 152, 210, 7, UI_LAMP_YELLOW);
    else if (v.riskLevel >= 2) cDrawRoundRect(9, 50, 152, 210, 7, UI_LAMP_RED);

    // ── 标题栏:盾牌(15,57)+ 会话名(31,57)+ 倒计时胶囊(129,57,25,13)──
    cDrawImage(15, 57, 14, 14, modalApprovalShield14);

    unsigned long remainS = (v.remainMs + 999) / 1000;   // 向上取整
    char cd[10];
    uint16_t cdColor = TFT_WHITE;
    bool cdShow = true;
    if (remainS >= 60) {
        snprintf(cd, sizeof(cd), "%lu:%02lu", remainS / 60, remainS % 60);
    } else {
        snprintf(cd, sizeof(cd), "%lus", remainS);
        if (remainS >= 10) cdColor = UI_LAMP_YELLOW;              // <60s 黄
        else               cdShow = (millis() % 1000) < 500;      // <10s 白 1Hz 闪(不用红)
    }
    cFillRoundRect(129, 57, 25, 13, 3, MD_CD_BG);
    if (cdShow) {
        int cdW = (int)strlen(cd) * 6;
        cSetTextFont(1);
        cSetTextSize(1);
        cSetTextColor(cdColor, MD_CD_BG);
        cSetCursor(129 + (25 - cdW) / 2, 60);
        cPrint(cd);
    }

    {
        char nb[40];
        cSetFont12();
        apvTruncPx(nb, sizeof(nb),
                   v.sessName[0] ? v.sessName : i18nText(UI_STR_APPROVAL_NO_SESSION_NAME),
                   APV_TITLE_MAX_PX);
        cSetFont16();
        cDrawCJK12(31, 58, nb, MD_TEXT_MAIN, MD_TITLE_PUR);
    }

    // ── 正文区(15..155, 79..214):工具行 + 连续纯文本,共 11 行 ──
    const int lineH = 12;
    int y = 79;
    bool risk2Hint = (v.riskLevel >= 2 && !v.notifyOnly);
    int reserved = (v.truncated ? 1 : 0) + (risk2Hint ? 1 : 0);

    {
        char tb[72];
        cSetFont12();
        apvTruncPx(tb, sizeof(tb), v.tool[0] ? v.tool : "?", APV_TEXT_MAX_PX);
        cSetFont16();
        cDrawCJK12(APV_TEXT_X, y, tb, MD_TEXT_MAIN, MD_BG);   // 工具名首行高亮
        y += lineH;
    }
    y = drawWrapped12(APV_TEXT_X, y, APV_TEXT_MAX_PX, lineH, 9 - reserved,
                      v.body[0] ? v.body : i18nText(UI_STR_APPROVAL_NO_PARAMETERS), MD_TEXT_BODY, MD_BG);

    // 业务标记行:Mac 侧截断提示(flags.bit0)与 dangerous 提示(D1)
    if (v.truncated) {
        cDrawCJK12(APV_TEXT_X, y, i18nText(UI_STR_APPROVAL_TRUNCATED), MD_TEXT_MUTED, MD_BG);
        y += lineH;
    }
    if (risk2Hint) {
        cDrawCJK12(APV_TEXT_X, y, i18nText(UI_STR_APPROVAL_CONFIRM_ON_MAC), UI_LAMP_RED, MD_BG);
    }

    // ── 底栏三行(217..258):队列/旋钮提示最多两行 + 手势/状态 ──
    const int yRow1 = 217, yRow1b = 231, yRow2 = 245;
    {
        char qb[8];
        snprintf(qb, sizeof(qb), "%u/%u", v.index1, v.total);
        cSetTextFont(1);
        cSetTextSize(1);
        cSetTextColor(MD_TEXT_MAIN, MD_BG);
        cSetCursor(14, yRow1 + 2);
        cPrint(qb);
        const char *closeHint = (v.state == 2)
            ? i18nText(UI_STR_APPROVAL_SWITCH_CLOSE_NOTICE)
            : i18nText(UI_STR_APPROVAL_SWITCH_CLOSE);
        int hintX = 14 + (int)strlen(qb) * 6 + 6;
        char first[49], second[49];
        int hintLines = splitActionLine(closeHint, first, second, APV_SAFE_RIGHT - hintX);
        cDrawCJK12(hintX, yRow1, first, MD_TEXT_MUTED, MD_BG);
        if (hintLines == 2) cDrawCJK12(14, yRow1b, second, MD_TEXT_MUTED, MD_BG);
    }

    if (v.notifyOnly) {
        char status[49];
        apvTruncPx(status, sizeof(status), i18nText(UI_STR_APPROVAL_HANDLE_ON_MAC),
                   APV_SAFE_RIGHT - 14);
        cDrawCJK12(14, yRow2, status, UI_LAMP_YELLOW, MD_BG);
    } else if (v.state == 1) {          // SENT_AWAITING_ACK
        char status[49];
        apvTruncPx(status, sizeof(status), i18nText(UI_STR_APPROVAL_SENT_WAITING),
                   APV_SAFE_RIGHT - 14);
        cDrawCJK12(14, yRow2, status, VC_CYAN, MD_BG);
    } else if (v.state == 2) {          // SEND_FAILED
        char status[49];
        apvTruncPx(status, sizeof(status), i18nText(UI_STR_APPROVAL_SEND_FAILED),
                   APV_SAFE_RIGHT - 14);
        cDrawCJK12(14, yRow2, status, UI_LAMP_RED, MD_BG);
    } else {
        bool allowOk  = (v.riskLevel < 2);
        bool alwaysOk = (v.riskLevel < 2) && !v.alwaysDisabled;
        // B 按下即时按压反馈(200ms 双击迟滞的视觉补偿):反色高亮 "B允许"
        bool bPressed = allowOk && v.pressFeedbackMs != 0 &&
                        (millis() - v.pressFeedbackMs) < 300;
        int x = 14;
        const char *allowLabel = i18nText(UI_STR_APPROVAL_ALLOW);
        const char *alwaysLabel = i18nText(UI_STR_APPROVAL_ALWAYS);
        const char *denyLabel = i18nText(UI_STR_APPROVAL_DENY);
        int wB = cjk12Width(allowLabel);
        if (bPressed) {
            cFillRect(x - 1, yRow2 - 1, wB + 2, 14, TFT_WHITE);
            cDrawCJK12(x, yRow2, allowLabel, TFT_BLACK, TFT_WHITE);
        } else {
            cDrawCJK12(x, yRow2, allowLabel, allowOk ? MD_ALLOW : MD_TEXT_MUTED, MD_BG);
        }
        x += wB + 10;
        cDrawCJK12(x, yRow2, alwaysLabel, alwaysOk ? MD_ALWAYS : MD_TEXT_MUTED, MD_BG);
        x += cjk12Width(alwaysLabel) + 10;
        cDrawCJK12(x, yRow2, denyLabel, MD_DENY, MD_BG);
    }
}

// ──────────────────────────────────────────────────────────
// 三区主界面顶层(REQ-008)
// ──────────────────────────────────────────────────────────
static void drawMainZones(const V5Status &st, const BatteryInfo &bat,
                          uint8_t bleBars, bool bleConnected,
                          const UiListSel &sel, int topMinOfDay) {
    if (st.agentCount == 0) {
        // REQ-030:有效状态帧但无 Agent → 基础语音就绪首页。
        drawBasicReadyPage();
    } else {
        int sessionTop = drawAgentZone(st);   // 返回值已含 2px 横线 + 2px 间隔
        if (st.sessionCount == 0) {
            // 已安装但无会话:用量块照常显示,"无会话"提示放会话列表区(BUG-026/027)
            int hintY = sessionTop + (ZONE_BOTTOM - sessionTop) / 2 - 8;
            cDrawCJK12Centered(85, hintY + 2, i18nText(UI_STR_HOME_NO_SESSIONS_READY),
                               UI_TEXT_SECONDARY, UI_BG);
        } else {
            drawSessionZone(st, sel, sessionTop);
        }
    }
    // 顶栏最后画(REQ-021)
    drawStatusBar(bat, bleConnected, bleBars, topMinOfDay);
}

// ──────────────────────────────────────────────────────────
// Stage 3b: Overlay 浮层
// 屏幕中心:170/2=85, 320/2=160
// 全屏黑底覆盖(简单可靠;不做半透明)
// ──────────────────────────────────────────────────────────
static const int CX = 85;
static const int CY = 160;

// REQ-010: PTT overlay 提示文案(长语音模式 = 单击停止)与附加提示注入
static bool s_pttToggleHintFlag = false;
static const char *s_infoNote = nullptr;
static bool s_systemMicFlag = false;    // T-033
#define g_pttToggleHint s_pttToggleHintFlag

// MM:SS.mmm 计时(录音页/识别页共用;真实 millis,按 10FPS 刷新步进显示)
static void fmtMsTime(char *buf, size_t cap, unsigned long elapsedMs) {
    unsigned long mm = elapsedMs / 60000UL;
    unsigned long ss = (elapsedMs / 1000UL) % 60UL;
    unsigned long ms = elapsedMs % 1000UL;
    snprintf(buf, cap, "%02lu:%02lu.%03lu", mm, ss, ms);
}

// ── 录音页(voice_recording_final,README_VOICE_UI §5)──
//   REC 灯 + 分隔线 + 正在收音 + 21 柱真实波形 + MM:SS.mmm + dBFS 电平条 + 提示胶囊
static void drawOverlayPttPress(unsigned long pttStartMs, const VoiceMeterView &vm) {
    cFillScreen(UI_BG);
    unsigned long now = millis();
    unsigned long elapsed = now - pttStartMs;

    // 顶部:REC 灯芯 (11,12) r4 + 外环 r6 + "REC" + 分隔线 y=23
    cFillCircle(11, 12, 4, VC_RED);
    cDrawCircle(11, 12, 6, VC_RED);
    cSetTextFont(1);
    cSetTextSize(1);
    cSetTextColor(VC_RED, UI_BG);
    cSetCursor(20, 7);
    cPrint("REC");
    cDrawFastHLine(6, 23, 158, VC_DIVIDER);

    // "正在收音"(视觉基线≈47 → y_top=34)
    // T-033:系统麦模式改用 wqy12 + 长文案。常驻 wqy16 下 10 CJK+2 半角括号 = 176px
    // > 画布 170px 会被 cDrawCJKCentered 钳到 x=0 并右侧溢出;wqy12 下 132px 安全。
    // y_top 用 36:cDrawCJK12 的 baseline offset 是 10(wqy16 为 13),36+10=46 ≈ 原基线 47。
    if (s_systemMicFlag) {
        const char *t = i18nText(UI_STR_RECORDING_LISTENING_SYSTEM_MIC);
        cDrawCJK12((170 - cjk12Width(t)) / 2, 36, t, VC_TEXT_SECONDARY, UI_BG);
    } else {
        cDrawCJKCentered(34, i18nText(UI_STR_RECORDING_LISTENING), VC_TEXT_SECONDARY, UI_BG);
    }

    // 波形:21 柱,x=10 起步进 7;中心柱 i=10 宽 5 红色,其余宽 4 青色按幅度调亮;
    // 以 y=120 为中心上下对称,高 8..116(README §5.5)
    // BUG-032:系统麦模式音频在 Mac 侧采集,设备无真实波形数据 —— 播自然波动动画
    // (双正弦拍频:快波给流动感、慢包络给呼吸感),替代恒零的真实数据。
    cDrawFastHLine(10, 120, 145, VC_DIVIDER);
    for (int i = 0; i < 21; i++) {
        int amp;
        if (s_systemMicFlag) {
            float t = (float)now;
            float v = sinf(t / 260.0f + i * 0.55f)
                    * (0.55f + 0.45f * sinf(t / 1700.0f + i * 0.13f));
            amp = 110 + (int)(100.0f * v);
            if (amp < 0) amp = 0;
            if (amp > 255) amp = 255;
        } else {
            amp = (int)vm.waveform[i];
        }
        int h = 8 + amp * 108 / 255;
        int x = 10 + i * 7;
        int w = (i == 10) ? 5 : 4;
        uint16_t c = (i == 10)
            ? VC_RED
            : scale565(VC_CYAN, 0.45f + 0.55f * (float)amp / 255.0f);
        cFillRect(x, 120 - h / 2, w, h, c);
    }

    // 录音计时 MM:SS.mmm(font4 26px 居中,视觉基线≈207)
    char tb[16];
    fmtMsTime(tb, sizeof(tb), elapsed);
    cDrawStringCentered(tb, CX, 187, 4, UI_TEXT_PRIMARY, UI_BG);

    // 输入电平文字(整数 dBFS,基线≈227 → y_top=214)
    // BUG-032:系统麦模式无电平数据,数字与横条均不显示(死值 -60 无意义)
    if (!s_systemMicFlag) {
        char lb[32];
        snprintf(lb, sizeof(lb), i18nText(UI_STR_RECORDING_INPUT_LEVEL), (int)(vm.db10 / 10));
        cDrawCJKCentered(214, lb, VC_TEXT_SECONDARY, UI_BG);
    }

    // 电平横条 x=22 y=239 w=126 h=4:快升慢降 + 400ms 峰值保持后回落(README §5.4)
    if (!s_systemMicFlag) {
        static float s_shown = -60.0f;
        static float s_peak  = -60.0f;
        static unsigned long s_peakMs = 0, s_lastMs = 0;
        if (now - s_lastMs > 400) { s_shown = -60.0f; s_peak = -60.0f; s_peakMs = 0; }
        s_lastMs = now;

        float target = (float)vm.db10 / 10.0f;
        if (target > s_shown) s_shown = target;
        else                  s_shown += (target - s_shown) * 0.28f;
        if (s_shown >= s_peak) { s_peak = s_shown; s_peakMs = now; }
        else if (now - s_peakMs > 400) {
            s_peak -= 3.0f * (60.0f / 126.0f);   // 每帧回落 3px 等效 dB
            if (s_peak < s_shown) s_peak = s_shown;
        }

        float norm = (s_shown + 60.0f) / 60.0f;
        if (norm < 0.0f) norm = 0.0f;
        if (norm > 1.0f) norm = 1.0f;
        int levelW = (int)lroundf(norm * 126.0f);
        uint16_t lc = VC_CYAN;
        if (s_shown > -3.0f)       lc = UI_LAMP_RED;
        else if (s_shown > -12.0f) lc = UI_LAMP_YELLOW;
        cFillRect(22, 239, 126, 4, UI_TRACK);
        if (levelW > 0) cFillRect(22, 239, levelW, 4, lc);

        float pn = (s_peak + 60.0f) / 60.0f;
        if (pn < 0.0f) pn = 0.0f;
        if (pn > 1.0f) pn = 1.0f;
        int px = 22 + (int)lroundf(pn * 126.0f);
        if (px > 22) cFillRect(px - 1, 238, 2, 6, UI_LAMP_RED);
    }

    // 底部提示胶囊 x=31 y=276 w=108 h=25(REQ-010 双模式文案)
    cFillRoundRect(31, 276, 108, 25, 12, VC_PANEL);
    cDrawRoundRect(31, 276, 108, 25, 12, VC_PANEL_BORDER);
    cDrawCJK12Centered(CX, 282,
                       g_pttToggleHint ? i18nText(UI_STR_RECORDING_PRESS_A_STOP)
                                       : i18nText(UI_STR_RECORDING_RELEASE_A_STOP),
                       VC_TEXT_SECONDARY, VC_PANEL);
}

// ── 识别页工作动画(README_VOICE_UI §6.1):高速循环,不暗示完成百分比 ──
static void drawBusyLoop(unsigned long startMs) {
    const int bx = 85, by = 119;
    cFillCircle(bx, by, 48, VC_BUSY_OUTER);
    cFillCircle(bx, by, 32, VC_BUSY_INNER);

    // 外圈 8 胶囊,高亮索引每 100ms 前进一步
    uint8_t phase = (uint8_t)(((millis() - startMs) / 100) % 8);
    for (int i = 0; i < 8; i++) {
        int age = (i - (int)phase + 8) % 8;
        uint16_t c = (age == 0) ? VC_CYAN : (age <= 2) ? VC_CYAN_MID : VC_CYAN_DARK;
        float ang = (float)i * 0.7853982f;   // 45°
        float ca = cosf(ang), sa = sinf(ang);
        cDrawWideLine(bx + 36.0f * ca, by + 36.0f * sa,
                      bx + 45.0f * ca, by + 45.0f * sa, 5.0f, c, VC_BUSY_OUTER);
    }

    // 中央 4 竖条错相位跳动(README 给定高度表,100ms 步进)
    static const uint8_t kH[4][4] = {
        { 20, 36, 26, 42 },
        { 30, 22, 42, 28 },
        { 42, 28, 20, 36 },
        { 26, 42, 32, 20 },
    };
    uint8_t frame = (uint8_t)(((millis() - startMs) / 100) % 4);
    for (int i = 0; i < 4; i++) {
        int h = kH[i][frame];
        cFillRoundRect(bx - 18 + i * 10, by - h / 2, 6, h, 3, VC_CYAN);
    }
}

// ── 识别页(README_VOICE_UI §6):工作动画 + 正在识别 + 耗时 + 输入模式卡片 ──
static void drawOverlayAsrProc(const V5Status &st, unsigned long overlayStartMs) {
    cFillScreen(UI_BG);

    // 顶部 "VOICE" + 分隔线
    cSetTextFont(1);
    cSetTextSize(1);
    cSetTextColor(VC_TEXT_SECONDARY, UI_BG);
    cSetCursor(6, 7);
    cPrint("VOICE");
    cDrawFastHLine(6, 23, 158, VC_DIVIDER);

    drawBusyLoop(overlayStartMs);

    // 标题(基线≈195 → y_top=182)+ 耗时(基线≈214,CYAN)
    cDrawCJKCentered(182, i18nText(UI_STR_RECOGNITION_WORKING), UI_TEXT_PRIMARY, UI_BG);
    char tb[16];
    fmtMsTime(tb, sizeof(tb), millis() - overlayStartMs);
    cDrawStringCentered(tb, CX, 200, 2, VC_CYAN, UI_BG);

    // REQ-010 附加提示(如录音超时);英文较长时折成两行并把模式卡下移。
    int cardY = 232;
    if (s_infoNote && s_infoNote[0]) {
        char first[49], second[49];
        int lines = splitActionLine(s_infoNote, first, second, 160);
        cDrawCJK12Centered(CX, 216, first, UI_LAMP_YELLOW, UI_BG);
        if (lines == 2) {
            cDrawCJK12Centered(CX, 229, second, UI_LAMP_YELLOW, UI_BG);
            cardY = 246;
        }
    }

    // 输入模式卡片 x=17 y=cardY w=136 h=44 r7(直通判定:README §6.3)
    bool direct = st.valid && st.exclusiveIdx >= 0 &&
                  (uint8_t)st.exclusiveIdx < st.sessionCount;
    if (direct) {
        cFillRoundRect(17, cardY, 136, 44, 7, VC_DIRECT_BG);
        cDrawRoundRect(17, cardY, 136, 44, 7, VC_CYAN);
        cFillRect(17, cardY + 8, 3, 28, VC_CYAN);          // 左侧强调条
        cDrawCJK12(26, cardY + 5, i18nText(UI_STR_RECOGNITION_DIRECT_MODE), VC_CYAN, VC_DIRECT_BG);
        char nb[64];
        truncUtf8ByPixels(nb, sizeof(nb), st.sessions[st.exclusiveIdx].name,
                          136 - 9 - 8 - 6, true);
        cDrawCJK12(26, cardY + 24, nb, UI_TEXT_PRIMARY, VC_DIRECT_BG);
    } else {
        cFillRoundRect(17, cardY, 136, 44, 7, VC_PANEL);
        cDrawRoundRect(17, cardY, 136, 44, 7, VC_PANEL_BORDER);
        cDrawCJK12(25, cardY + 5, i18nText(UI_STR_RECOGNITION_INPUT_METHOD), VC_TEXT_SECONDARY, VC_PANEL);
        cDrawCJK12(25, cardY + 24, i18nText(UI_STR_RECOGNITION_FREE_MODE), UI_TEXT_PRIMARY, VC_PANEL);
        // 设计稿右侧"输入到当前光标"为 ~10px 小字;固件 CJK 仅 wqy16,
        // 卡片宽度放不下 7 字 → 精简为"光标处"(语义等价,右对齐)
        const char *atCursor = i18nText(UI_STR_RECOGNITION_AT_CURSOR);
        int w = cjk12Width(atCursor);
        cDrawCJK12(17 + 136 - 8 - w, cardY + 24, atCursor, VC_TEXT_SECONDARY, VC_PANEL);
    }
}

// ── 结果页(README_VOICE_UI §7/§8):外方内圆 + 符号 + 四字文案,无错误详情 ──
//   失败原因不再上屏(保留串口日志),2s 后自动回主界面快速恢复输入
static void drawOverlayResult(bool ok) {
    cFillScreen(UI_BG);
    uint16_t shellFill = ok ? VC_OK_SHELL_FILL : VC_ERR_SHELL_FILL;
    uint16_t shellEdge = ok ? VC_OK_SHELL_EDGE : VC_ERR_SHELL_EDGE;
    uint16_t core      = ok ? VC_GREEN : VC_RED;
    cFillRoundRect(43, 94, 84, 84, 16, shellFill);
    cDrawRoundRect(43, 94, 84, 84, 16, shellEdge);
    cFillCircle(85, 136, 28, core);
    if (ok) {
        // 对勾(背景色圆头粗线,画在灯芯上)
        cDrawWideLine(73.0f, 137.0f, 81.0f, 146.0f, 5.0f, UI_BG, core);
        cDrawWideLine(81.0f, 146.0f, 99.0f, 126.0f, 5.0f, UI_BG, core);
    } else {
        // 叉号
        cDrawWideLine(75.0f, 126.0f, 95.0f, 146.0f, 5.0f, UI_BG, core);
        cDrawWideLine(95.0f, 126.0f, 75.0f, 146.0f, 5.0f, UI_BG, core);
    }
    cDrawCJKCentered(194, ok ? i18nText(UI_STR_RECOGNITION_SUCCESS)
                             : i18nText(UI_STR_RECOGNITION_ERROR), UI_TEXT_PRIMARY, UI_BG);
}

// Mac 只能请求显示本页，不能直接进入运输模式。设备端 B/C 是最终物理确认边界。
static void drawOverlayShipMode(UiShipModeState mode) {
    cFillScreen(UI_BG);

    UiStringId title = UI_STR_SHIP_TITLE;
    UiStringId body = UI_STR_SHIP_BODY;
    UiStringId help = UI_STR_SHIP_WAKE;
    if (mode == UI_SHIP_USB_BLOCKED) {
        title = UI_STR_SHIP_USB_TITLE;
        body = UI_STR_SHIP_USB_BODY;
        help = UI_STR_SHIP_USB_HELP;
    } else if (mode == UI_SHIP_ERROR) {
        title = UI_STR_SHIP_ERROR_TITLE;
        body = UI_STR_SHIP_ERROR_BODY;
        help = UI_STR_SHIP_ERROR_HELP;
    } else if (mode == UI_SHIP_ENTERING) {
        title = UI_STR_SHIP_ENTERING_TITLE;
        body = UI_STR_SHIP_ENTERING_BODY;
        help = UI_STR_SHIP_ENTERING_HELP;
    }

    cSetTextFont(1);
    cSetTextSize(1);
    cSetTextColor(VC_TEXT_SECONDARY, UI_BG);
    cSetCursor(6, 7);
    cPrint("SHIP MODE");
    cDrawFastHLine(6, 23, 158, VC_DIVIDER);

    // 电源符号：外圈 + 中央竖线。红色表示动作不可逆。
    cFillCircle(CX, 75, 36, VC_ERR_SHELL_FILL);
    cDrawCircle(CX, 75, 30, UI_LAMP_RED);
    cDrawWideLine((float)CX, 49.0f, (float)CX, 73.0f,
                  5.0f, UI_LAMP_RED, VC_ERR_SHELL_FILL);

    cDrawCJKCentered(120, i18nText(title), UI_TEXT_PRIMARY, UI_BG);
    cDrawCJK12Centered(CX, 147, i18nText(body),
                       mode == UI_SHIP_USB_BLOCKED ? UI_LAMP_YELLOW : VC_TEXT_SECONDARY,
                       UI_BG);

    cFillRoundRect(12, 170, 146, 82, 8, VC_PANEL);
    cDrawRoundRect(12, 170, 146, 82, 8, VC_PANEL_BORDER);
    cSetFont12();
    drawWrapped12(20, 180, 130, 16, 4, i18nText(help),
                  UI_TEXT_PRIMARY, VC_PANEL);

    if (mode != UI_SHIP_ENTERING) {
        cFillRoundRect(12, 270, 70, 28, 8, VC_OK_SHELL_FILL);
        cDrawRoundRect(12, 270, 70, 28, 8, VC_GREEN);
        cDrawCJK12Centered(47, 277,
                           i18nText(mode == UI_SHIP_READY ? UI_STR_SHIP_CONFIRM
                                                         : UI_STR_SHIP_RETRY),
                           VC_GREEN, VC_OK_SHELL_FILL);

        cFillRoundRect(88, 270, 70, 28, 8, VC_ERR_SHELL_FILL);
        cDrawRoundRect(88, 270, 70, 28, 8, VC_RED);
        cDrawCJK12Centered(123, 277, i18nText(UI_STR_SHIP_CANCEL),
                           VC_RED, VC_ERR_SHELL_FILL);
    }
}

// ──────────────────────────────────────────────────────────
// Stage 3c: Permission Toast 叠加层
//   位置:y=280..319 (40px 高, 170 宽,屏幕底部贴边)
//   背景:橙色实心,1px 白色边框
//   文字第 1 行 (font2): "PERM:" 标签 + tool 名(白色)
//   文字第 2 行 (font1): input 内容(截断 + ".."),白色
//   右下角:倒计时 "Ns" (橙底白字)
//   注意:覆盖 Dashboard 工具栏 proj 行,3s 短暂可接受
// ──────────────────────────────────────────────────────────
static void drawPermissionToast(const PermissionToastState &toast) {
    const int TX = 0;
    const int TY = 280;
    const int TW = 170;
    const int TH = 40;

    // 橙色背景 + 白色边框
    uint16_t bg = TFT_ORANGE;
    cFillRect(TX, TY, TW, TH, bg);
    cDrawRect(TX, TY, TW, TH, TFT_WHITE);

    // 倒计时(秒数,向上取整,1..3)
    unsigned long now = millis();
    unsigned long remainMs = 0;
    if ((long)(toast.expiresAt - now) > 0) {
        remainMs = toast.expiresAt - now;
    }
    unsigned int remainS = (unsigned int)((remainMs + 999) / 1000);
    if (remainS == 0) remainS = 1;
    if (remainS > 9)  remainS = 9;

    // line 1: PERM:<tool>  走 U8g2 wqy16 (CJK 支持)
    // 可用宽度:170 - 4(左 padding) - 22(右侧 "Ns" 倒计时)= 144px
    // "PERM:" 前缀 ~40px → tool 名字 104px
    if (toast.tool[0]) {
        const char *prefix = i18nText(UI_STR_PERMISSION_PREFIX);
        cDrawCJK(TX + 4, TY + 2, prefix, TFT_WHITE, bg);
        int prefixWidth = g_u8g2_ready ? g_u8g2.getUTF8Width(prefix) : 40;
        char toolBuf[72];
        truncUtf8ByPixels(toolBuf, sizeof(toolBuf), toast.tool, 144 - prefixWidth, true);
        cDrawCJK(TX + 4 + prefixWidth, TY + 2, toolBuf, TFT_WHITE, bg);
    } else {
        cDrawCJK(TX + 4, TY + 2, i18nText(UI_STR_PERMISSION_MISSING_TOOL), TFT_WHITE, bg);
    }

    // 倒计时(右上):font2 "Ns"
    char rbuf[8];
    snprintf(rbuf, sizeof(rbuf), "%us", remainS);
    int rw = (int)strlen(rbuf) * 8;  // font2 ~8px/ch
    cSetCursor(TX + TW - rw - 4, TY + 2);
    cPrint(rbuf);

    // line 2: input 内容 (font1 = 6x8, white on orange)
    //   起点 y = TY + 22, 单行最多 (170-8)/6 ≈ 27 chars
    cSetTextFont(1);
    cSetTextSize(1);
    cSetTextColor(TFT_WHITE, bg);
    cSetCursor(TX + 4, TY + 24);

    char line2[32] = {0};
    if (toast.input[0]) {
        size_t ilen = strlen(toast.input);
        const size_t kMax = 27;
        if (ilen > kMax) {
            memcpy(line2, toast.input, kMax - 2);
            line2[kMax - 2] = '.';
            line2[kMax - 1] = '.';
            line2[kMax]     = 0;
        } else {
            memcpy(line2, toast.input, ilen);
            line2[ilen] = 0;
        }
        cPrint(line2);
    } else {
        cDrawCJK12(TX + 4, TY + 22, i18nText(UI_STR_PERMISSION_NO_INPUT), TFT_WHITE, bg);
    }
}

// ──────────────────────────────────────────────────────────
// Stage 3b: 状态切换 + 顶层 dispatch
// ──────────────────────────────────────────────────────────
static const char *overlayName(UiOverlayState s) {
    switch (s) {
        case UI_OV_NONE:        return "NONE";
        case UI_OV_PTT_PRESS:   return "PTT_PRESS";
        case UI_OV_ASR_PROC:    return "ASR_PROC";
        case UI_OV_ASR_SUCCESS: return "ASR_SUCCESS";
        case UI_OV_ASR_FAILURE: return "ASR_FAILURE";
        case UI_OV_SHIP_CONFIRM: return "SHIP_CONFIRM";
        default:                return "?";
    }
}

void ui_set_overlay(UiOverlayCtx &ctx, UiOverlayState newState) {
    if (ctx.state == newState) return;
    ctx.state          = newState;
    ctx.overlayStartMs = millis();
    if (newState == UI_OV_PTT_PRESS) ctx.infoNote[0] = '\0';   // 新一轮录音清旧提示
    Serial.printf("Overlay: %s\n", overlayName(newState));
}

// ──────────────────────────────────────────────────────────
// Stage 4 splash
//   - 未连 Mac App  → SPLASH_DISCONNECTED (红点 + "Disconnected")
//   - 已连但未收到 ClaudeStatus(无 session)→ SPLASH_CONNECTED (绿点 + "Connected")
//
// 布局 (170×320):
//   y=  0..199  vibePanelLogo 130×200 居中 (X=20)
//   y=210..225  设备名 (font 2 居中)
//   y=232..245  固件版本 "v0.4.0" (font 1 居中)
//   y=295..310  圆点 + 状态文字 (font 1 居中)
// ──────────────────────────────────────────────────────────
// ── 黑匣子诊断行(QuickVibeMicPad.ino 开机取证后调用,splash 显示)──
static char s_diag1[28] = "";
static char s_diag2[28] = "";
void ui_set_diag(const char *line1, const char *line2) {
    snprintf(s_diag1, sizeof(s_diag1), "%s", line1 ? line1 : "");
    snprintf(s_diag2, sizeof(s_diag2), "%s", line2 ? line2 : "");
}

// 色键图块绘制:跳过背景色像素(波浪字母放大后相邻图块重叠,防止图块底色抹掉邻字)
static void cDrawImageKeyed(int x, int y, int w, int h, const uint16_t *data) {
    for (int sy = 0; sy < h; sy++)
        for (int sx = 0; sx < w; sx++) {
            uint16_t c = data[sy * w + sx];
            if (c != UI_BG) cDrawPixel(x + sx, y + sy, c);
        }
}

// 波浪字母:三档缩放就近取档,底边中心锚 + 上移(README_SPLASH 6 秒循环)
static void drawWaveLetter(int idx, float p, int yOffset) {
    struct Tile { const uint16_t *img; int w, h; };
    static const Tile kTiles[4][3] = {
        { { splashLetter_v_100, LETTER_V_100_W, LETTER_V_100_H },
          { splashLetter_v_108, LETTER_V_108_W, LETTER_V_108_H },
          { splashLetter_v_116, LETTER_V_116_W, LETTER_V_116_H } },
        { { splashLetter_i_100, LETTER_I_100_W, LETTER_I_100_H },
          { splashLetter_i_108, LETTER_I_108_W, LETTER_I_108_H },
          { splashLetter_i_116, LETTER_I_116_W, LETTER_I_116_H } },
        { { splashLetter_b_100, LETTER_B_100_W, LETTER_B_100_H },
          { splashLetter_b_108, LETTER_B_108_W, LETTER_B_108_H },
          { splashLetter_b_116, LETTER_B_116_W, LETTER_B_116_H } },
        { { splashLetter_e_100, LETTER_E_100_W, LETTER_E_100_H },
          { splashLetter_e_108, LETTER_E_108_W, LETTER_E_108_H },
          { splashLetter_e_116, LETTER_E_116_W, LETTER_E_116_H } },
    };
    static const int kX[4] = { LETTER_V_X, LETTER_I_X, LETTER_B_X, LETTER_E_X };
    static const int kY[4] = { LETTER_V_Y, LETTER_I_Y, LETTER_B_Y, LETTER_E_Y };
    static const int kW[4] = { LETTER_V_W, LETTER_I_W, LETTER_B_W, LETTER_E_W };
    static const int kH[4] = { LETTER_V_H, LETTER_I_H, LETTER_B_H, LETTER_E_H };

    int tier = (p < 0.25f) ? 0 : (p < 0.75f) ? 1 : 2;
    const Tile &t = kTiles[idx][tier];
    int yOff = -(int)lroundf(4.0f * p);
    int x = kX[idx] + kW[idx] / 2 - t.w / 2;
    int y = kY[idx] + yOffset + kH[idx] - t.h + yOff;
    if (tier == 0 && yOff == 0) cDrawImage(x, y, t.w, t.h, t.img);   // 静止档整块推
    else                        cDrawImageKeyed(x, y, t.w, t.h, t.img);
}

// splash 状态机(文件级:ui_splash_restart_cycle 可从 .ino 强制重开循环)
static bool s_splHaveState = false;
static bool s_splLastConn = false;
static unsigned long s_splConnEdgeMs = 0;
static unsigned long s_splCycleBaseMs = 0;

// SPL 演示命令重入 splash 时无连接边沿,循环相位会继承残留;调试截图需从头跑
void ui_splash_restart_cycle() {
    s_splHaveState = false;
}

// ── Splash(REQ-023 二期,README_SPLASH 完整规范)──
//   Logo(33,17,104,160)+ 设备编号 + 版本胶囊 + 状态卡;
//   未连接:红灯呼吸 + 三点追逐 + 7 秒品牌循环(VIBE 波浪 3.5-4.88s / 扫光 4.9-6.3s);
//   连接:绿双闪(480ms)后常亮,静止 Logo,搜索点隐藏;
//   诊断两行仅在 .ino 判定异常复位时注入(正常开机 splash 无调试文字)
static void drawSplash(SplashStatus status,
                       const char *deviceName,
                       const char *fwVersion) {
    unsigned long now = millis();
    bool connected = (status == SPLASH_CONNECTED);

    // 状态边沿:双闪起点 / 7 秒循环基准(断线重入立即回静止 Logo 新循环)
    if (!s_splHaveState || connected != s_splLastConn) {
        s_splHaveState  = true;
        s_splLastConn   = connected;
        s_splConnEdgeMs = now;
        s_splCycleBaseMs = now;
    }

    // ── Logo 区(33,17,104,160)──
    // 7.5 秒品牌循环(2026-07-25 用户四轮修订:节奏减半 → 扫速再慢 1.5× →
    // 扫过 Everything 末字母 g 后淡出,不跑单词与屏幕边缘间的空白段):
    //   3.5–4.88s 字母波浪(单字 720ms,错开 220ms);4.9–7.24s 扫光(cy 145→8,末段淡出)
    uint32_t cyc = connected ? 0 : (uint32_t)((now - s_splCycleBaseMs) % 7500);
    bool wave  = !connected && cyc >= 3500 && cyc < 4880;   // 4 字母 ×220ms 错开 + 720ms
    bool sweep = !connected && cyc >= 4900 && cyc < 7240;
    if (!wave && !sweep) {
        cDrawImage(33, 17, SPLASH_LOGO_W, SPLASH_LOGO_H, splashLogo104);
    } else {
        // 分层重组:背景 → everything → 字母(波浪)→ 扫光 → everything 高亮带
        cFillRect(33, 17, SPLASH_LOGO_W, SPLASH_LOGO_H, UI_BG);
        cDrawImage(EVERYTHING_X, EVERYTHING_Y, EVERYTHING_W, EVERYTHING_H, splashEverything);
        for (int i = 0; i < 4; i++) {
            int32_t local = (int32_t)cyc - 3500 - i * 220;
            float p = (local < 0 || local >= 720) ? 0.0f
                    : sinf((float)local / 720.0f * 3.14159f);
            drawWaveLetter(i, p, 0);
        }
        if (sweep) {
            // 扫速保持 ≈58.6px/s;终点 = 亮线越过 g 顶端(EVERYTHING_Y=22)上方,
            // 末段 15% 行程整体淡出(用户:过 g 即消失,别跑空白段;淡出防闪断)
            float t = (float)(cyc - 4900) / 2340.0f;          // 0..1
            int cy = 145 - (int)lroundf(137.0f * t);          // y=145 → 8
            float fade = (t > 0.85f) ? (1.0f - t) / 0.15f : 1.0f;
            if (fade < 0.0f) fade = 0.0f;
            const int clipTop = 0, clipBot = 146;
            // 半透明聚光罩(v3,用户拍板:光覆盖在 Everything 文字之上)——
            // 对已画好的画布做像素级 lerp(帧缓冲直改),字形透光被提亮,
            // 不再单独重画字形;椭圆衰减:亮度随 |dy| 平方衰减、行宽随椭圆收窄
            if (sprFull) {
                uint16_t *fb = (uint16_t *)spr.getPointer();
                if (fb) {
                    const int   glowHalfH = 26;
                    const float glowHalfW = 23.0f;            // 光罩最大半宽(46/2)
                    for (int dy = -glowHalfH; dy <= glowHalfH; dy++) {
                        int y = cy + dy;
                        if (y < clipTop || y > clipBot) continue;
                        float fr = 1.0f - (float)(dy * dy) / (float)(glowHalfH * glowHalfH);
                        if (fr <= 0.02f) continue;
                        int hw = (int)lroundf(glowHalfW * sqrtf(fr));
                        if (hw < 2) continue;
                        float f = fr * fr * 0.8f;
                        // ±3px 辅助线行:不低于 40%(README 规范要素)
                        if ((dy == -3 || dy == 3) && f < 0.4f) f = 0.4f;
                        f *= fade;
                        uint16_t *row = fb + (uint32_t)y * 170;
                        for (int x = 85 - hw; x < 85 + hw; x++) {
                            uint16_t c = row[x];
                            c = (uint16_t)((c >> 8) | (c << 8));   // 面板字节序 → 逻辑值
                            c = blend565(c, VC_CYAN, f);
                            row[x] = (uint16_t)((c >> 8) | (c << 8));
                        }
                    }
                }
            }
            // 中心亮线(近白,光斑最亮处,画在最上;淡出段与光罩同步变暗)
            if (cy >= -2 && cy <= clipBot) {
                cFillRect(64, cy - 1, 42, 3,
                          (fade >= 1.0f) ? SP_SPOT_CORE
                                         : blend565(UI_BG, SP_SPOT_CORE, fade));
            }
        }
    }

    // ── 分隔线 + 设备编号 + 版本胶囊 ──
    cDrawFastHLine(48, 187, 74, UI_ROW_DIVIDER);
    if (deviceName && deviceName[0]) {
        int w = cjk12Width(deviceName);
        int x = (170 - w) / 2;
        if (x < 0) x = 0;
        cDrawCJK12(x, 200, deviceName, UI_TEXT_PRIMARY, UI_BG);
    }
    cFillRoundRect(62, 220, 46, 16, 8, UI_AGENT_BG);
    cDrawRoundRect(62, 220, 46, 16, 8, UI_TRACK);
    if (fwVersion && fwVersion[0]) {
        char vb[16];
        snprintf(vb, sizeof(vb), "v%s", fwVersion);
        int vw = (int)strlen(vb) * 6;
        cSetTextFont(1);
        cSetTextSize(1);
        cSetTextColor(VC_TEXT_SECONDARY, UI_AGENT_BG);
        cSetCursor(62 + (46 - vw) / 2, 224);
        cPrint(vb);
    }

    // ── 状态卡(24,249,122,40)──
    uint16_t edge = connected ? SP_EDGE_CON : SP_EDGE_DIS;
    cFillRoundRect(24, 249, 122, 40, 8, MD_BG);
    cDrawRoundRect(24, 249, 122, 40, 8, edge);

    // 状态灯 14×14(外方内圆,与主界面交通灯同构)
    cFillRoundRect(33, 262, 14, 14, 2, UI_LAMP_HOUSING);
    cDrawRoundRect(33, 262, 14, 14, 2, UI_LAMP_BORDER);
    cFillCircle(35, 264, 1, UI_LAMP_SCREW);
    cFillCircle(45, 264, 1, UI_LAMP_SCREW);
    cFillCircle(35, 272, 1, UI_LAMP_SCREW);
    cFillCircle(45, 272, 1, UI_LAMP_SCREW);
    float coreBright = 1.0f;
    uint16_t coreColor;
    if (connected) {
        unsigned long dt = now - s_splConnEdgeMs;
        bool on = (dt >= 480) || ((dt / 120) % 2 == 0);   // 双闪:亮/暗/亮/暗→常亮
        coreBright = on ? 1.0f : 0.15f;
        coreColor  = scale565(UI_LAMP_GREEN, coreBright);
    } else {
        float phase = (float)(now % 1600) / 1600.0f;
        coreBright = 0.25f + 0.75f * fabsf(sinf(phase * 3.14159f));
        coreColor  = scale565(VC_RED, coreBright);
    }
    cFillCircle(40, 269, 5, coreColor);
    cFillCircle(39, 268, 1, scale565(UI_TEXT_PRIMARY, coreBright));

    // 状态文字 + 搜索点
    if (connected) {
        cDrawCJK12(55, 263, i18nText(UI_STR_BASIC_CONNECTED), SP_TEXT_CON, MD_BG);
    } else {
        cDrawCJK12(55, 263, i18nText(UI_STR_BASIC_DISCONNECTED), SP_TEXT_DIS, MD_BG);
        int active = (int)((now / 300) % 3);
        static const int kDotX[3] = { 132, 137, 142 };
        for (int i = 0; i < 3; i++) {
            cFillCircle(kDotX[i], 269, 1, (i == active) ? VC_RED : SP_DOT_DIM);
        }
    }

    // 黑匣子诊断两行(仅异常复位时由 .ino 注入;正常开机为空,不违反设计约束)
    if (s_diag1[0]) {
        cSetTextFont(1);
        cSetTextSize(1);
        cSetTextColor(TFT_DARKGREY, UI_BG);
        int w1 = (int)strlen(s_diag1) * 6, x1 = (170 - w1) / 2;
        if (x1 < 0) x1 = 0;
        cSetCursor(x1, 296);
        cPrint(s_diag1);
    }
    if (s_diag2[0]) {
        cSetTextFont(1);
        cSetTextSize(1);
        cSetTextColor(TFT_DARKGREY, UI_BG);
        int w2 = (int)strlen(s_diag2) * 6, x2 = (170 - w2) / 2;
        if (x2 < 0) x2 = 0;
        cSetCursor(x2, 308);
        cPrint(s_diag2);
    }
}

void ui_render_splash(SplashStatus status,
                      const char *deviceName,
                      const char *fwVersion) {
    if (sprFull) {
        spr.fillSprite(UI_BG);
        drawSplash(status, deviceName, fwVersion);
        spr.pushSprite(0, 0);
    } else {
        tft.fillScreen(UI_BG);
        drawSplash(status, deviceName, fwVersion);
    }
}

void ui_render_firmware_update(uint8_t progressPercent, bool finalizing) {
    if (progressPercent > 100) progressPercent = 100;
    cFillScreen(UI_BG);

    cSetTextFont(1);
    cSetTextSize(1);
    cSetTextColor(VC_TEXT_SECONDARY, UI_BG);
    cSetCursor(6, 7);
    cPrint("FIRMWARE UPDATE");
    cDrawFastHLine(6, 23, 158, VC_DIVIDER);

    cFillCircle(CX, 83, 38, VC_BUSY_OUTER);
    cDrawCircle(CX, 83, 31, finalizing ? VC_GREEN : VC_CYAN);
    if (finalizing) {
        cDrawWideLine(72.0f, 84.0f, 81.0f, 94.0f, 5.0f, UI_BG, VC_GREEN);
        cDrawWideLine(81.0f, 94.0f, 100.0f, 72.0f, 5.0f, UI_BG, VC_GREEN);
    } else {
        cDrawWideLine(85.0f, 61.0f, 85.0f, 91.0f, 5.0f, VC_CYAN, VC_BUSY_OUTER);
        cDrawWideLine(85.0f, 91.0f, 74.0f, 80.0f, 5.0f, VC_CYAN, VC_BUSY_OUTER);
        cDrawWideLine(85.0f, 91.0f, 96.0f, 80.0f, 5.0f, VC_CYAN, VC_BUSY_OUTER);
        cDrawFastHLine(70, 101, 31, VC_CYAN);
    }

    cDrawCJKCentered(132, i18nText(UI_STR_OTA_TITLE), UI_TEXT_PRIMARY, UI_BG);
    cDrawCJK12Centered(CX, 157,
                       i18nText(finalizing ? UI_STR_OTA_VERIFYING
                                           : UI_STR_OTA_TRANSFERRING),
                       finalizing ? VC_GREEN : VC_CYAN, UI_BG);

    const int trackX = 17, trackY = 188, trackW = 136, trackH = 10;
    cFillRoundRect(trackX, trackY, trackW, trackH, 5, UI_TRACK);
    int fillW = trackW * progressPercent / 100;
    if (fillW > 0) {
        if (fillW < trackH) fillW = trackH;
        cFillRoundRect(trackX, trackY, fillW, trackH, 5,
                       finalizing ? VC_GREEN : VC_CYAN);
    }
    char percent[8];
    snprintf(percent, sizeof(percent), "%u%%", progressPercent);
    cDrawStringCentered(percent, CX, 207, 4, UI_TEXT_PRIMARY, UI_BG);

    cFillRoundRect(12, 252, 146, 48, 8, VC_PANEL);
    cDrawRoundRect(12, 252, 146, 48, 8, VC_PANEL_BORDER);
    cDrawCJK12Centered(CX, 260, i18nText(UI_STR_OTA_DO_NOT_INTERRUPT),
                       UI_LAMP_YELLOW, VC_PANEL);
    cDrawCJK12Centered(CX, 278, i18nText(UI_STR_OTA_CONTROLS_LOCKED),
                       VC_TEXT_SECONDARY, VC_PANEL);

    if (sprFull) spr.pushSprite(0, 0);
}

void ui_render(const V5Status &st,
               const BatteryInfo &bat,
               const char *fwVersion,
               uint8_t bleBars,
               const UiOverlayCtx &ov,
               const PermissionToastState &perm,
               bool bleConnected,
               const char *deviceName,
               const UiListSel &sel,
               const V5Config &cfg,
               const UiModeCtx &modeCtx,
               int topMinOfDay,
               const VoiceMeterView &voiceMeter) {
    // REQ-010: overlay 上下文注入(PTT 提示文案 / 附加提示)
    s_pttToggleHintFlag = ov.toggleHint;
    s_infoNote          = ov.infoNote;
    s_systemMicFlag     = ov.systemMic;
    // splash dispatch:
    //   overlay != NONE 时 PTT/ASR overlay 优先(PTT 录音中即使 splash 也要看 overlay)
    //   overlay == NONE 时:未连 → splash;已连但无有效数据 → splash;有数据 → 三区主界面
    //   (st.valid 由 v5 帧或 mock 置位;空状态跳舞动画在 drawMainZones 内处理)
    // REQ-022:审批模态优先于 splash——BLE 未连/已连未收数据帧时收到审批
    // (或串口 APV 注入验证)也必须能显示模态,不被 splash 提前 return 盖掉
    bool apvModal = (modeCtx.mode == DEV_MODE_APPROVAL) && s_apvView && s_apvView->active;
    if (ov.state == UI_OV_NONE && !apvModal) {
        if (!bleConnected && !st.valid) {
            ui_render_splash(SPLASH_DISCONNECTED, deviceName, fwVersion);
            return;
        }
        if (!st.valid) {
            ui_render_splash(SPLASH_CONNECTED, deviceName, fwVersion);
            return;
        }
    }
    switch (ov.state) {
        case UI_OV_NONE: {
            // 主界面 + 模式窗口 + 连删浮窗 + Permission Toast 叠加后一次性 push
            if (sprFull) spr.fillSprite(UI_BG);
            else         tft.fillScreen(UI_BG);
            drawMainZones(st, bat, bleBars, bleConnected, sel, topMinOfDay);
            if (modeCtx.mode == DEV_MODE_PROMPT) {
                drawPromptWindow(cfg, modeCtx);
            } else if (modeCtx.mode == DEV_MODE_INPUT_ASSISTANT) {
                drawInputAssistantWindow(cfg, modeCtx);
            } else if (modeCtx.mode == DEV_MODE_EDIT) {
                drawEditWindow(modeCtx.editEcho);
            } else if (modeCtx.mode == DEV_MODE_ACTION && modeCtx.actionMode.valid) {
                drawActionModeWindow(modeCtx.actionMode);
            } else if (modeCtx.mode == DEV_MODE_APP_SWITCHER) {
                drawApplicationSwitcherWindow(modeCtx.applicationSwitcher);
            } else if (modeCtx.mode == DEV_MODE_APPROVAL) {
                // REQ-022 审批模态(视图由 .ino 每渲染周期从 ApprovalQueue 同步)
                if (s_apvView && s_apvView->active) drawApprovalWindow(*s_apvView);
            }
            if (modeCtx.deleting) {
                drawDeleteOverlay(modeCtx.delCount);
            }
            if (perm.active && (long)(perm.expiresAt - millis()) > 0) {
                drawPermissionToast(perm);
            }
            if (sprFull) spr.pushSprite(0, 0);
            return;
        }

        case UI_OV_PTT_PRESS:
            drawOverlayPttPress(ov.pttStartMs, voiceMeter);
            if (sprFull) spr.pushSprite(0, 0);
            return;

        case UI_OV_ASR_PROC:
            drawOverlayAsrProc(st, ov.overlayStartMs);
            if (sprFull) spr.pushSprite(0, 0);
            return;

        case UI_OV_ASR_SUCCESS:
            drawOverlayResult(true);
            if (sprFull) spr.pushSprite(0, 0);
            return;

        case UI_OV_ASR_FAILURE:
            // asrFailMsg 不再上屏(README_VOICE_UI §8),原因保留在串口日志
            drawOverlayResult(false);
            if (sprFull) spr.pushSprite(0, 0);
            return;

        case UI_OV_SHIP_CONFIRM:
            drawOverlayShipMode(ov.shipModeState);
            if (sprFull) spr.pushSprite(0, 0);
            return;
    }
}
