// test_claude_status_parser.cpp
// Stage 2 native unit tests for claude_status_parser (host-side).
//
// Build (when gtest is installed):
//   g++ -std=c++17 -I.. \
//     test_claude_status_parser.cpp ../claude_status_parser.cpp \
//     -lgtest -lgtest_main -lpthread -o /tmp/test_parser \
//   && /tmp/test_parser
//
// Status: gtest NOT installed in current env (Stage 2). Tests are scaffolded
// so we can wire them up in Stage 5 without rewriting cases.

#include <gtest/gtest.h>
#include <cstring>
#include "claude_status_parser.h"

// ── Helpers ──────────────────────────────────────────────
static void appendU8(std::vector<uint8_t>& v, uint8_t x) { v.push_back(x); }
static void appendU16LE(std::vector<uint8_t>& v, uint16_t x) {
    v.push_back((uint8_t)(x & 0xFF));
    v.push_back((uint8_t)((x >> 8) & 0xFF));
}
static void appendStr(std::vector<uint8_t>& v, const char* s) {
    size_t n = std::strlen(s);
    v.push_back((uint8_t)n);
    for (size_t i = 0; i < n; i++) v.push_back((uint8_t)s[i]);
}

#include <vector>

// ── ClaudeStatus tests ───────────────────────────────────
TEST(ClaudeStatus, ValidV4Payload) {
    std::vector<uint8_t> p;
    appendU8(p, 1);            // phase
    appendU8(p, 3);            // sessionCount
    appendU8(p, 7);            // colorIndex
    appendStr(p, "VibeEvery"); // projName
    appendStr(p, "Bash");      // toolName
    appendU8(p, 42);           // usagePct
    appendU8(p, 80);           // ctxPct
    appendU16LE(p, 1234);      // tokenInK
    appendU16LE(p, 567);       // tokenOutK
    appendU16LE(p, 100);       // linesAdded
    appendU16LE(p, 50);        // linesRemoved
    appendU8(p, 2);            // dashCount
    appendStr(p, "alpha"); appendU8(p, 4); appendU8(p, 1);
    appendStr(p, "beta");  appendU8(p, 5); appendU8(p, 2);
    appendU8(p, 1);            // exclusiveIdx (V4)

    ClaudeStatusState s;
    ASSERT_TRUE(parseClaudeStatus(p.data(), p.size(), s));
    EXPECT_EQ(s.phase, 1);
    EXPECT_STREQ(s.projName, "VibeEvery");
    EXPECT_STREQ(s.toolName, "Bash");
    EXPECT_EQ(s.tokenInK, 1234);
    EXPECT_EQ(s.tokenOutK, 567);
    EXPECT_EQ(s.linesAdded, 100);
    EXPECT_EQ(s.linesRemoved, 50);
    EXPECT_EQ(s.dashCount, 2);
    EXPECT_STREQ(s.dashes[0].name, "alpha");
    EXPECT_STREQ(s.dashes[1].name, "beta");
    EXPECT_EQ(s.exclusiveIdx, 1);
    EXPECT_TRUE(s.valid);
}

TEST(ClaudeStatus, DashCountZero) {
    std::vector<uint8_t> p;
    appendU8(p, 0); appendU8(p, 0); appendU8(p, 0);
    appendU8(p, 0);                   // projLen=0
    appendU8(p, 0);                   // toolLen=0
    appendU8(p, 0); appendU8(p, 0);   // usage / ctx
    appendU16LE(p, 0); appendU16LE(p, 0); appendU16LE(p, 0); appendU16LE(p, 0);
    appendU8(p, 0);                   // dashCount=0

    ClaudeStatusState s;
    ASSERT_TRUE(parseClaudeStatus(p.data(), p.size(), s));
    EXPECT_EQ(s.dashCount, 0);
    EXPECT_EQ(s.exclusiveIdx, -1);
}

TEST(ClaudeStatus, DashCountAtMax) {
    std::vector<uint8_t> p;
    appendU8(p, 1); appendU8(p, 5); appendU8(p, 0);
    appendStr(p, "x");
    appendStr(p, "y");
    appendU8(p, 0); appendU8(p, 0);
    appendU16LE(p, 0); appendU16LE(p, 0); appendU16LE(p, 0); appendU16LE(p, 0);
    appendU8(p, DASH_MAX_SESSIONS);
    for (int i = 0; i < DASH_MAX_SESSIONS; i++) {
        char nm[8]; snprintf(nm, sizeof(nm), "s%d", i);
        appendStr(p, nm); appendU8(p, i); appendU8(p, 0);
    }
    appendU8(p, 2);  // exclusiveIdx

    ClaudeStatusState s;
    ASSERT_TRUE(parseClaudeStatus(p.data(), p.size(), s));
    EXPECT_EQ(s.dashCount, DASH_MAX_SESSIONS);
    EXPECT_EQ(s.exclusiveIdx, 2);
}

TEST(ClaudeStatus, DashCountOverMaxRejected) {
    std::vector<uint8_t> p;
    appendU8(p, 0); appendU8(p, 0); appendU8(p, 0);
    appendU8(p, 0); appendU8(p, 0); appendU8(p, 0); appendU8(p, 0);
    appendU16LE(p, 0); appendU16LE(p, 0); appendU16LE(p, 0); appendU16LE(p, 0);
    appendU8(p, DASH_MAX_SESSIONS + 3);  // declared > 上限

    ClaudeStatusState s;
    ASSERT_TRUE(parseClaudeStatus(p.data(), p.size(), s));
    EXPECT_EQ(s.dashCount, 0);  // 整体丢弃
}

TEST(ClaudeStatus, TruncatedShortPacketReturnsFalse) {
    uint8_t buf[3] = {1, 2, 3};
    ClaudeStatusState s;
    EXPECT_FALSE(parseClaudeStatus(buf, sizeof(buf), s));
}

TEST(ClaudeStatus, ProjNameEmpty) {
    std::vector<uint8_t> p;
    appendU8(p, 0); appendU8(p, 0); appendU8(p, 0);
    appendU8(p, 0);  // projLen=0
    appendU8(p, 4); for (char c : std::string("Edit")) p.push_back(c);
    appendU8(p, 0); appendU8(p, 0);
    ClaudeStatusState s;
    ASSERT_TRUE(parseClaudeStatus(p.data(), p.size(), s));
    EXPECT_STREQ(s.projName, "");
    EXPECT_STREQ(s.toolName, "Edit");
}

// ── PermissionRequest tests ──────────────────────────────
TEST(Permission, BasicJson) {
    const char json[] = "{\"tool\":\"Bash\",\"input\":\"ls -la\",\"id\":\"abc\"}";
    PermissionToastState t;
    ASSERT_TRUE(parsePermissionRequest((const uint8_t*)json, std::strlen(json), t));
    EXPECT_STREQ(t.tool, "Bash");
    EXPECT_STREQ(t.input, "ls -la");
    EXPECT_TRUE(t.active);
}

TEST(Permission, EscapedQuote) {
    const char json[] = "{\"tool\":\"Edit\",\"input\":\"say \\\"hi\\\"\"}";
    PermissionToastState t;
    ASSERT_TRUE(parsePermissionRequest((const uint8_t*)json, std::strlen(json), t));
    EXPECT_STREQ(t.input, "say \"hi\"");
}

TEST(Permission, MissingToolReturnsFalse) {
    const char json[] = "{\"input\":\"x\"}";
    PermissionToastState t;
    EXPECT_FALSE(parsePermissionRequest((const uint8_t*)json, std::strlen(json), t));
}

TEST(Permission, EmptyInputReturnsTrue) {
    // 工具名给了就够,input 可空(老 Mac App 也这样)
    const char json[] = "{\"tool\":\"Read\"}";
    PermissionToastState t;
    ASSERT_TRUE(parsePermissionRequest((const uint8_t*)json, std::strlen(json), t));
    EXPECT_STREQ(t.tool, "Read");
    EXPECT_STREQ(t.input, "");
}

// ── VOICE_NOTIFY tests ───────────────────────────────────
TEST(VoiceNotify, SuccessOnly) {
    uint8_t buf[2] = {0x06, 0x01};
    AsrFeedbackState f;
    ASSERT_TRUE(parseVoiceNotify(0x06, buf, sizeof(buf), f));
    EXPECT_FALSE(f.isFailure);
    EXPECT_EQ(f.buttonId, 0x01);
}

TEST(VoiceNotify, FailureWithMessage) {
    const char errMsg[] = "API key invalid";
    std::vector<uint8_t> p = {0x07, 0x02};
    for (char c : std::string(errMsg)) p.push_back(c);
    AsrFeedbackState f;
    ASSERT_TRUE(parseVoiceNotify(0x07, p.data(), p.size(), f));
    EXPECT_TRUE(f.isFailure);
    EXPECT_EQ(f.buttonId, 0x02);
    EXPECT_STREQ(f.message, "API key invalid");
}

TEST(VoiceNotify, FailureNoMessageFallback) {
    uint8_t buf[2] = {0x07, 0x01};
    AsrFeedbackState f;
    ASSERT_TRUE(parseVoiceNotify(0x07, buf, sizeof(buf), f));
    EXPECT_TRUE(f.isFailure);
    EXPECT_STREQ(f.message, "Failed");
}

TEST(VoiceNotify, UnsupportedCmdReturnsFalse) {
    uint8_t buf[1] = {0x05};
    AsrFeedbackState f;
    EXPECT_FALSE(parseVoiceNotify(0x05, buf, sizeof(buf), f));
}
