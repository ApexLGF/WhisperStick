#ifndef QVH_SHERPA_ENGLISH_SHIM_H
#define QVH_SHERPA_ENGLISH_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

typedef void *QVHSherpaEnglishContext;
typedef void *QVHSherpaEnglishSession;

/// Creates one English streaming recognizer. All paths must remain valid only
/// for the duration of this call; sherpa-onnx owns its loaded model state.
QVHSherpaEnglishContext qvh_sherpa_english_create(
    const char *encoder_path,
    const char *decoder_path,
    const char *joiner_path,
    const char *tokens_path,
    const char *bpe_vocab_path,
    const char *punctuation_model_path,
    const char *punctuation_vocab_path,
    const char *hotwords_utf8);

void qvh_sherpa_english_destroy(QVHSherpaEnglishContext context);

QVHSherpaEnglishSession qvh_sherpa_english_session_create(
    QVHSherpaEnglishContext context);

/// Feeds 16-kHz mono PCM16 and returns an internal UTF-8 snapshot valid until
/// the next feed/finish call on the same session.
const char *qvh_sherpa_english_session_feed(
    QVHSherpaEnglishSession session,
    const short *samples,
    int sample_count);

/// Finalizes the stream and restores English punctuation/casing.
const char *qvh_sherpa_english_session_finish(
    QVHSherpaEnglishSession session);

void qvh_sherpa_english_session_destroy(QVHSherpaEnglishSession session);

#ifdef __cplusplus
}
#endif
#endif
