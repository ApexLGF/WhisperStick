// FunTpass 2-pass 流式 C shim 实现(T-018)
// 直接调用 libfunasr-merged.a 导出的 C++ 符号(FunTpassInit / FunTpassOnlineInit /
// FunTpassInferBuffer / CompileHotwordEmbedding …),链接期解析。
// 说明:offline SeACo 的 shim 编在预编译 .a 里(无源码);本文件是**新增**在工程内编译的源,
//       与 .a 共用同一 funasrruntime.h 声明与 C++ ABI。
#import "funasr_c_shim.h"
#include "funasrruntime.h"

#include <string>
#include <vector>
#include <map>

namespace {
struct TpassCtx {
    FUNASR_HANDLE tpass  = nullptr;   // FunTpassInit 句柄(含 offline+vad+punc)
    FUNASR_HANDLE online = nullptr;   // FunTpassOnlineInit 句柄(流式解码状态)
    FUNASR_DEC_HANDLE decoder = nullptr;   // ★ WFST 解码器:2pass InferBuffer 必需,传 null 会恒返 null
    std::vector<std::vector<float>> hw_emb;               // 热词嵌入(SeACo bias)
    // ★ 必须 size 2:FunASR 2pass demo 用 punc_cache(2),内部索引 [0]/[1],空 vector 会 UB → 返 null。
    std::vector<std::vector<std::string>> punc_cache = std::vector<std::vector<std::string>>(2);
    std::string result;                                    // 在线增量返回缓冲
    std::string definitive;                                // offline 段级定稿累积(2pass 精确结果)
    std::string online_dir;                                // reset 时重建 online 用
    std::vector<int> chunk_size = {5, 10, 5};
};

// map 里只放非空目录,空/NULL 跳过(缺 vad/punc 时 runtime 会 "skip load")。
static void put(std::map<std::string, std::string>& m, const char* key, const char* val) {
    if (val && val[0] != '\0') m[key] = std::string(val);
}
} // namespace

extern "C" {

FunasrTpassCtx funasr_tpass_init(const char* model_dir, const char* online_dir,
                                 const char* vad_dir, const char* punc_dir, int use_quant) {
    if (!model_dir || model_dir[0] == '\0') return nullptr;
    std::map<std::string, std::string> model_path;
    put(model_path, "model-dir",        model_dir);
    put(model_path, "online-model-dir", online_dir);
    put(model_path, "vad-dir",          vad_dir);
    put(model_path, "punc-dir",         punc_dir);
    const char* q = use_quant ? "true" : "false";
    model_path["quantize"]   = q;
    model_path["vad-quant"]  = q;   // 跟随 use_quant:量化集只有 model_quant.onnx,写 false 会找 model.onnx → "not exist" → vad_handle null 崩
    model_path["punc-quant"] = q;

    FUNASR_HANDLE tpass = FunTpassInit(model_path, QM_DEFAULT_THREAD_NUM);
    if (!tpass) return nullptr;

    auto* c = new TpassCtx();
    c->tpass = tpass;
    if (online_dir) c->online_dir = online_dir;
    c->online = FunTpassOnlineInit(tpass, c->chunk_size);
    if (!c->online) { FunTpassUninit(tpass); delete c; return nullptr; }
    // ★ WFST 解码器(2pass 必需)。beam/am_scale 用 demo 默认值。
    c->decoder = FunASRWfstDecoderInit(tpass, ASR_TWO_PASS, 3.0f, 3.0f, 10.0f);   // 可空(无 lm 时 null,InferBuffer 内有守卫)
    return static_cast<FunasrTpassCtx>(c);
}

int funasr_tpass_set_hotwords(FunasrTpassCtx ctx, const char* hotwords) {
    auto* c = static_cast<TpassCtx*>(ctx);
    if (!c) return -1;
    std::string hw = hotwords ? hotwords : "";
    // ASR_TWO_PASS:让 offline 主干编译 SeACo 热词嵌入。
    c->hw_emb = CompileHotwordEmbedding(c->tpass, hw, ASR_TWO_PASS);
    return 0;
}

const char* funasr_tpass_feed(FunasrTpassCtx ctx, const short* pcm, int n_samples, int is_final) {
    auto* c = static_cast<TpassCtx*>(ctx);
    if (!c) return "";
    c->result.clear();
    const char* buf = reinterpret_cast<const char*>(pcm);
    const int n_bytes = n_samples * (int)sizeof(short);
    // 空热词时用默认 {{0.0}}(空 vector 传进去可能致 infer 异常/返 null)。
    const std::vector<std::vector<float>> hw =
        c->hw_emb.empty() ? std::vector<std::vector<float>>{{0.0f}} : c->hw_emb;
    FUNASR_RESULT r = FunTpassInferBuffer(
        c->tpass, c->online, buf, n_bytes, c->punc_cache,
        /*input_finished*/ is_final != 0,
        /*sampling_rate*/ 16000, /*wav_format*/ "pcm", ASR_TWO_PASS,
        hw, /*itn*/ true, /*dec_handle*/ c->decoder, /*svs_lang*/ "auto", /*svs_itn*/ true);
    if (r) {
        // 在线增量(供实时草稿)。
        const char* online = FunASRGetResult(r, 0);
        c->result = online ? online : "";
        // offline 段级定稿:VAD 段结束时非空 → 累积(2pass 精确结果,近离线质量)。
        const char* tp = FunASRGetTpassResult(r, 0);
        if (tp && tp[0] != '\0') c->definitive += tp;
        FunASRFreeResult(r);
    } else {
        c->result.clear();
    }
    return c->result.c_str();
}

const char* funasr_tpass_definitive(FunasrTpassCtx ctx) {
    auto* c = static_cast<TpassCtx*>(ctx);
    return c ? c->definitive.c_str() : "";
}

void funasr_tpass_reset(FunasrTpassCtx ctx) {
    auto* c = static_cast<TpassCtx*>(ctx);
    if (!c) return;
    c->definitive.clear();
    c->punc_cache = std::vector<std::vector<std::string>>(2);   // 复位为 size 2(非清空)
    // 重建 online 解码状态(清跨句残留)。
    if (c->online) { FunTpassOnlineUninit(c->online); c->online = nullptr; }
    c->online = FunTpassOnlineInit(c->tpass, c->chunk_size);
}

void funasr_tpass_free(FunasrTpassCtx ctx) {
    auto* c = static_cast<TpassCtx*>(ctx);
    if (!c) return;
    if (c->decoder) FunASRWfstDecoderUninit(c->decoder);
    if (c->online) FunTpassOnlineUninit(c->online);
    if (c->tpass)  FunTpassUninit(c->tpass);
    delete c;
}

} // extern "C"
