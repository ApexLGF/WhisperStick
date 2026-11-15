// buzzer_fx.h — AI 状态提示音(REQ-022 音效批次)非阻塞蜂鸣器驱动
//
// 音色权威来源:Resources/SoundsEffect/LYMCompose_v1_low_octave/*.qvbuzzer
// (用户在 V14/HYG-5030A 实机逐条试听定稿)。本文件只做格式转换:
// NOTE{freq,soundMs,gapMs,dutyPercent} → BuzNote{freq,ms,duty 绝对值}。
//
// 硬件:V14 HYG-5030A 无源蜂鸣器(GPIO39 经 Q1);旧 v10/v11 为 MLT-5020;
// 面包板 PIN_BUZZER=-1 全空操作。
// 驱动方式:LEDC PWM(通道 2,避开背光通道 0)。bringup 用阻塞 delay() 试听,
// 主固件不可阻塞 loop,这里是音符序列 + millis() 推进的非阻塞状态机(buzzer_tick 每帧调)。
//
// 9 个状态音 + 1 个音量试听音:
//   BZ_TASK_STARTED       任务开始执行(纯五度二音上行)
//   BZ_TASK_ERROR         任务出错需关注(四级下行;SEND_FAILED 复用)
//   BZ_APPROVAL_REQUIRED  新审批等待处理(两音快速交替三组)
//   BZ_APPROVAL_TAKEN     审批被他处处理(四音下行)
//   BZ_APPROVAL_EXPIRED   审批超时窗口关闭(三音下行)
//   BZ_APPROVAL_ACCEPTED  审批通过(二音上行)
//   BZ_APPROVAL_REJECTED  审批被拒(单次下降二音)
//   BZ_INPUT_REQUIRED     等待用户输入(两呼一问重复两轮;仅 notifyOnly 触发)
//   BZ_TASK_COMPLETED     任务完成(五音上行琶音)
//
// 优先级(REQ-022 音效批次):
//   审批类(REQUIRED/TAKEN/EXPIRED/ACCEPTED/REJECTED/INPUT_REQUIRED)可打断任务类;
//   任务类(STARTED/ERROR/COMPLETED)不打断正在播的审批类(直接丢弃,不排队)。
//
// 全局音量:0..100%,20% 步进(未知值钳制到最近 20% 档),
//   播放时 duty = base*pct*60%/100;静音态 buzzer_play 直接丢弃(打 muted drop 日志);
//   NVS 持久化(Preferences ns "buzzer" key "vol",默认 60),buzzer_init 读回。
#pragma once
#include <stdint.h>

enum BuzzerFx : uint8_t {
    BZ_NONE = 0,
    BZ_TASK_STARTED,
    BZ_TASK_ERROR,
    BZ_APPROVAL_REQUIRED,
    BZ_APPROVAL_TAKEN,
    BZ_APPROVAL_EXPIRED,
    BZ_APPROVAL_ACCEPTED,
    BZ_APPROVAL_REJECTED,
    BZ_INPUT_REQUIRED,
    BZ_TASK_COMPLETED,
};

void buzzer_init();               // setup 调一次(读回 NVS 音量;PIN_BUZZER<0 时空操作)
void buzzer_play(BuzzerFx fx);    // 触发播放(优先级规则见文件头)
void buzzer_tick();               // loop 每帧调,非阻塞推进音符序列
bool buzzer_is_busy();            // 生命周期事件队列等待当前提示音播放完成
// 音量 0..100,20% 步进;其他值钳制到最近档;变更即写 NVS(值未变不写)
void buzzer_set_volume(uint8_t pct);
uint8_t buzzer_get_volume();      // 静音态返回 0
void buzzer_preview_volume();     // 播放 2s 单音试听;静音态自动丢弃
// 息屏唤醒后 LEDC 通道完整重建(ledcSetup+ledcAttachPin,并复位播放状态)。
// 依据:power_manager.cpp:116-120 背光 ch0 同款实机教训——长睡多次循环后裸
// ledcAttachPin 概率性挂空;由 power_manager 在唤醒重建段与背光同批调用。
void buzzer_reinit();
