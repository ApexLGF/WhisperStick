// 0x52 Agent 卡片协议：新固件接收 4 个 Agent、动态名称和积分语义，
// 同时保持旧核心帧兼容。纯 assert，不依赖 Arduino 或 gtest。
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <string>
#include <vector>

#include "../v5_protocol.h"

struct AgentFixture {
    uint8_t id;
    uint8_t active;
    uint8_t total;
    uint8_t billing;
    uint32_t value;
    uint8_t metric;
    std::string name;
};

static std::vector<uint8_t> buildFrame(const std::vector<AgentFixture> &agents,
                                       bool extensions = true,
                                       bool metadata = true) {
    std::vector<uint8_t> out = {V5_FRAME_AGENT_INFO, (uint8_t)agents.size()};
    for (const auto &a : agents) {
        out.insert(out.end(), {a.id, 0xFF, 0xFF, 0xFF, a.active, a.total});
    }
    if (!extensions) return out;
    for (const auto &a : agents) {
        out.push_back(a.billing);
        out.push_back((uint8_t)(a.value & 0xFF));
        out.push_back((uint8_t)((a.value >> 8) & 0xFF));
        out.push_back((uint8_t)((a.value >> 16) & 0xFF));
        out.push_back((uint8_t)((a.value >> 24) & 0xFF));
    }
    if (!metadata) return out;
    for (const auto &a : agents) {
        out.push_back(a.metric);
        out.push_back((uint8_t)a.name.size());
        out.insert(out.end(), a.name.begin(), a.name.end());
    }
    return out;
}

int main() {
    const std::vector<AgentFixture> agents = {
        {0, 1, 3, V5_BILLING_SUBSCRIPTION, 0, V5_AGENT_METRIC_QUOTA, "Claude"},
        {1, 2, 5, V5_BILLING_API, 12345, V5_AGENT_METRIC_DAILY_TOKENS, "Codex"},
        {2, 1, 7, 2, 5272, V5_AGENT_METRIC_CUMULATIVE_CREDITS, "WorkBuddy"},
        {9, 0, 1, 0, 0, V5_AGENT_METRIC_COUNTS_ONLY, "FutureAgent"},
    };

    {
        auto frame = buildFrame(agents);
        V5Status status = {};
        assert(v5ParseAgentInfo(frame.data(), frame.size(), status));
        assert(status.agentCount == 4);
        assert(status.agents[2].agentId == AGENT_WORKBUDDY);
        assert(status.agents[2].billingMode == V5_BILLING_CREDITS);
        assert(status.agents[2].metricKind == V5_AGENT_METRIC_CUMULATIVE_CREDITS);
        assert(status.agents[2].dailyTokens == 5272);
        assert(strcmp(status.agents[2].displayName, "WorkBuddy") == 0);
        assert(status.agents[3].metricKind == V5_AGENT_METRIC_COUNTS_ONLY);
        assert(strcmp(status.agents[3].displayName, "FutureAgent") == 0);
    }

    {
        auto legacy = buildFrame({agents[0], agents[1]}, false, false);
        V5Status status = {};
        assert(v5ParseAgentInfo(legacy.data(), legacy.size(), status));
        assert(status.agentCount == 2);
        assert(status.agents[0].billingMode == V5_BILLING_SUBSCRIPTION);
        assert(status.agents[0].dailyTokens == V5_DAILY_TOKENS_UNKNOWN);
        assert(status.agents[0].metricKind == V5_AGENT_METRIC_QUOTA);
        assert(status.agents[0].displayName[0] == '\0');
    }

    {
        auto oversized = agents;
        oversized.push_back({10, 0, 0, 0, 0, V5_AGENT_METRIC_COUNTS_ONLY, "Ignored"});
        auto frame = buildFrame(oversized);
        V5Status status = {};
        assert(v5ParseAgentInfo(frame.data(), frame.size(), status));
        assert(status.agentCount == V5_MAX_AGENTS);
        assert(strcmp(status.agents[3].displayName, "FutureAgent") == 0);
    }

    {
        auto truncated = buildFrame({agents[0], agents[1]}, false, false);
        truncated.pop_back();
        V5Status status = {};
        status.valid = true;
        assert(!v5ParseAgentInfo(truncated.data(), truncated.size(), status));
        assert(status.valid);
    }

    printf("PASS: v5 Agent info compatibility and extensions\n");
    return 0;
}
