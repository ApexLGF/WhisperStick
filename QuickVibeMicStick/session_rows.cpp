// session_rows.cpp — 见 session_rows.h
#include "session_rows.h"

int ui_inactive_shown(const V5Status &st) {
    if (st.inactiveStart < 0 || (uint8_t)st.inactiveStart >= st.sessionCount) return 0;
    int n = (int)st.sessionCount - (int)st.inactiveStart;
    return n > V5_DEV_INACTIVE_CAP ? V5_DEV_INACTIVE_CAP : n;
}

int ui_active_count(const V5Status &st) {
    return (st.inactiveStart < 0) ? (int)st.sessionCount : (int)st.inactiveStart;
}

int ui_row_count(const V5Status &st, bool expanded) {
    int a = ui_active_count(st), n = ui_inactive_shown(st);
    if (n == 0) return a;
    return a + 1 + (expanded ? n : 0);
}

int ui_row_to_session(const V5Status &st, bool expanded, int row) {
    int a = ui_active_count(st), n = ui_inactive_shown(st);
    if (row < 0) return -2;
    if (row < a)  return row;
    if (n == 0)   return -2;
    if (row == a) return -1;                       // 非活跃标签行
    if (!expanded) return -2;
    int k = row - a - 1;
    return (k < n) ? (int)st.inactiveStart + k : -2;
}

int ui_session_to_row(const V5Status &st, bool expanded, int sess) {
    int a = ui_active_count(st), n = ui_inactive_shown(st);
    if (sess < 0 || sess >= (int)st.sessionCount) return -1;
    if (sess < a) return sess;
    if (n == 0 || !expanded) return -1;
    int k = sess - a;
    return (k < n) ? a + 1 + k : -1;
}
