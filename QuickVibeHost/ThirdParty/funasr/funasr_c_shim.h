// FunASR SeACo C shim — Swift-bridgeable plain-C API(封装 C++ funasrruntime.h)
#ifndef FUNASR_C_SHIM_H
#define FUNASR_C_SHIM_H
#ifdef __cplusplus
extern "C" {
#endif
typedef void* FunasrCtx;
/// 加载 SeACo 模型(model_dir 含 model_quant.onnx + model_eb.onnx + am.mvn + config.yaml + tokens.json + seg_dict)。
/// punc_dir:可选 ct-punc 标点模型目录(含 model_quant.onnx + config.yaml + tokens.json),传 NULL/"" 则不加标点。失败返回 NULL。
FunasrCtx funasr_seaco_init(const char* model_dir, const char* punc_dir, int use_quant);
/// 设置热词(每行 "词 权重",如 "Claude\\ngit commit";空串清空)。重算 model_eb embedding。
int funasr_seaco_set_hotwords(FunasrCtx ctx, const char* hotwords);
/// 识别 16k mono int16 PCM → 文本(返回内部缓冲,有效到下次调用;调用方应即拷贝)。
const char* funasr_seaco_infer_pcm(FunasrCtx ctx, const short* pcm, int n_samples);
void funasr_seaco_free(FunasrCtx ctx);

// ── FunTpass 2-pass 流式(T-018)──────────────────────────────────────────
// online 出实时 partial + offline 断点定稿;hw_emb 走 CompileHotwordEmbedding(SeACo bias)。
typedef void* FunasrTpassCtx;
/// 加载 2-pass:model_dir=offline(可 SeACo)、online_dir=流式模型、vad_dir、punc_dir(均可 NULL 走默认/跳过)。
/// use_quant:是否用 *_quant.onnx。失败返回 NULL。
FunasrTpassCtx funasr_tpass_init(const char* model_dir, const char* online_dir,
                                 const char* vad_dir, const char* punc_dir, int use_quant);
/// 设热词(每行 "词 [权重]";空串清空)→ 重编 hw_emb。成功返回 0。
int funasr_tpass_set_hotwords(FunasrTpassCtx ctx, const char* hotwords);
/// 喂一段 16k mono int16 PCM;返回**在线增量片段**(供实时草稿,较快但较糙)。
/// offline 段级定稿在 VAD 段结束时内部累积,用 funasr_tpass_definitive 取(准,近离线质量)。
const char* funasr_tpass_feed(FunasrTpassCtx ctx, const short* pcm, int n_samples, int is_final);
/// 取累积的 offline 段级定稿(2pass 精确结果,带标点)。整段喂完后调,作为最终注入文本。
const char* funasr_tpass_definitive(FunasrTpassCtx ctx);
/// 每句之间清流式状态(online + punc_cache),避免跨句串词。
void funasr_tpass_reset(FunasrTpassCtx ctx);
void funasr_tpass_free(FunasrTpassCtx ctx);

// ── Sherpa-ONNX English Streaming Zipformer ───────────────────────────
// Kept in the shared bridging header so Swift sees one small, stable C ABI.
#include "sherpa_english_shim.h"

#ifdef __cplusplus
}
#endif
#endif
