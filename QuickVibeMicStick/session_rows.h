#pragma once
// session_rows.h — T-034 非活跃分组:显示行 ↔ 会话下标 的映射(纯算术,零图形依赖)
//
// 拆成独立 TU 而非留在 ui_renderer.cpp:后者依赖 M5 图形栈,宿主机 g++ 编不了;
// 本文件只吃 V5Status 的整型字段,tests/test_v5_sessions_group.cpp 可直接链接。
// 输入侧(EC11 框选/单击)与渲染侧共用同一套几何,避免两处各算一遍走偏。
//
// 显示行序列 = [活跃 0..activeN-1] [非活跃标签行] [(展开时)非活跃 ≤V5_DEV_INACTIVE_CAP 条]
#include "ui_model.h"

// 非活跃组实际渲染条数(REQ-028 §4 设备端 5 条;Mac 已截,固件再兜一次)
int ui_inactive_shown(const V5Status &st);
// 活跃组条数(= inactiveStart;无分组时 = sessionCount)
int ui_active_count(const V5Status &st);

int ui_row_count(const V5Status &st, bool expanded);                 // 显示行总数
int ui_row_to_session(const V5Status &st, bool expanded, int row);   // -1=标签行 -2=越界
int ui_session_to_row(const V5Status &st, bool expanded, int sess);  // -1=当前不可见
