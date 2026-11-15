#include "sherpa_english_shim.h"

#include <sherpa-onnx/c-api/c-api.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct EnglishContext {
  const SherpaOnnxOnlineRecognizer *recognizer = nullptr;
  const SherpaOnnxOnlinePunctuation *punctuation = nullptr;
};

struct EnglishSession {
  EnglishContext *context = nullptr;
  const SherpaOnnxOnlineStream *stream = nullptr;
  std::string text;
};

std::string CurrentText(EnglishSession *session) {
  const SherpaOnnxOnlineRecognizerResult *result =
      SherpaOnnxGetOnlineStreamResult(session->context->recognizer,
                                     session->stream);
  if (result != nullptr) {
    session->text = result->text != nullptr ? result->text : "";
    SherpaOnnxDestroyOnlineRecognizerResult(result);
  }
  return session->text;
}

void DecodeReady(EnglishSession *session) {
  while (SherpaOnnxIsOnlineStreamReady(session->context->recognizer,
                                       session->stream)) {
    SherpaOnnxDecodeOnlineStream(session->context->recognizer, session->stream);
  }
}

std::string NormalizeEnglishCase(std::string text) {
  bool capitalize_next = true;
  for (char &value : text) {
    const auto byte = static_cast<unsigned char>(value);
    if (std::isalpha(byte)) {
      value = capitalize_next ? static_cast<char>(std::toupper(byte))
                              : static_cast<char>(std::tolower(byte));
      capitalize_next = false;
    } else if (value == '.' || value == '!' || value == '?') {
      capitalize_next = true;
    }
  }
  // The pronoun "I" is emitted as a standalone lowercase token after the
  // punctuation model. Restore it without attempting risky proper-noun rules.
  for (size_t index = 0; index < text.size(); ++index) {
    if (text[index] != 'i') continue;
    const bool left_boundary = index == 0 || !std::isalpha(
        static_cast<unsigned char>(text[index - 1]));
    const bool right_boundary = index + 1 == text.size() || !std::isalpha(
        static_cast<unsigned char>(text[index + 1]));
    if (left_boundary && right_boundary) text[index] = 'I';
  }
  return text;
}

}  // namespace

QVHSherpaEnglishContext qvh_sherpa_english_create(
    const char *encoder_path, const char *decoder_path,
    const char *joiner_path, const char *tokens_path,
    const char *bpe_vocab_path, const char *punctuation_model_path,
    const char *punctuation_vocab_path, const char *hotwords_utf8) {
  if (encoder_path == nullptr || decoder_path == nullptr ||
      joiner_path == nullptr || tokens_path == nullptr ||
      bpe_vocab_path == nullptr) {
    return nullptr;
  }

  auto *context = new EnglishContext();
  SherpaOnnxOnlineRecognizerConfig config{};
  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 80;
  config.model_config.transducer.encoder = encoder_path;
  config.model_config.transducer.decoder = decoder_path;
  config.model_config.transducer.joiner = joiner_path;
  config.model_config.tokens = tokens_path;
  config.model_config.num_threads = 2;
  config.model_config.provider = "cpu";
  config.model_config.modeling_unit = "bpe";
  config.model_config.bpe_vocab = bpe_vocab_path;

  const bool has_hotwords =
      hotwords_utf8 != nullptr && std::strlen(hotwords_utf8) != 0;
  config.decoding_method = has_hotwords ? "modified_beam_search" : "greedy_search";
  config.max_active_paths = 4;
  config.enable_endpoint = 0;
  config.hotwords_score = 1.5f;
  config.hotwords_buf = has_hotwords ? hotwords_utf8 : nullptr;
  config.hotwords_buf_size =
      has_hotwords ? static_cast<int32_t>(std::strlen(hotwords_utf8)) : 0;

  context->recognizer = SherpaOnnxCreateOnlineRecognizer(&config);
  if (context->recognizer == nullptr) {
    delete context;
    return nullptr;
  }

  if (punctuation_model_path != nullptr && punctuation_vocab_path != nullptr &&
      std::strlen(punctuation_model_path) != 0 &&
      std::strlen(punctuation_vocab_path) != 0) {
    SherpaOnnxOnlinePunctuationConfig punctuation_config{};
    punctuation_config.model.cnn_bilstm = punctuation_model_path;
    punctuation_config.model.bpe_vocab = punctuation_vocab_path;
    punctuation_config.model.num_threads = 1;
    punctuation_config.model.provider = "cpu";
    context->punctuation =
        SherpaOnnxCreateOnlinePunctuation(&punctuation_config);
  }
  return context;
}

void qvh_sherpa_english_destroy(QVHSherpaEnglishContext opaque_context) {
  auto *context = static_cast<EnglishContext *>(opaque_context);
  if (context == nullptr) return;
  if (context->punctuation != nullptr) {
    SherpaOnnxDestroyOnlinePunctuation(context->punctuation);
  }
  if (context->recognizer != nullptr) {
    SherpaOnnxDestroyOnlineRecognizer(context->recognizer);
  }
  delete context;
}

QVHSherpaEnglishSession qvh_sherpa_english_session_create(
    QVHSherpaEnglishContext opaque_context) {
  auto *context = static_cast<EnglishContext *>(opaque_context);
  if (context == nullptr || context->recognizer == nullptr) return nullptr;
  auto *session = new EnglishSession();
  session->context = context;
  session->stream = SherpaOnnxCreateOnlineStream(context->recognizer);
  if (session->stream == nullptr) {
    delete session;
    return nullptr;
  }
  return session;
}

const char *qvh_sherpa_english_session_feed(
    QVHSherpaEnglishSession opaque_session, const short *samples,
    int sample_count) {
  auto *session = static_cast<EnglishSession *>(opaque_session);
  if (session == nullptr || session->stream == nullptr || samples == nullptr ||
      sample_count <= 0) {
    return "";
  }
  std::vector<float> normalized(static_cast<size_t>(sample_count));
  std::transform(samples, samples + sample_count, normalized.begin(),
                 [](short sample) {
                   return static_cast<float>(sample) / 32768.0f;
                 });
  SherpaOnnxOnlineStreamAcceptWaveform(session->stream, 16000,
                                      normalized.data(), sample_count);
  DecodeReady(session);
  session->text = CurrentText(session);
  return session->text.c_str();
}

const char *qvh_sherpa_english_session_finish(
    QVHSherpaEnglishSession opaque_session) {
  auto *session = static_cast<EnglishSession *>(opaque_session);
  if (session == nullptr || session->stream == nullptr) return "";

  // A short tail lets the transducer emit tokens held at the utterance edge.
  std::vector<float> silence(4800, 0.0f);
  SherpaOnnxOnlineStreamAcceptWaveform(session->stream, 16000,
                                      silence.data(), silence.size());
  SherpaOnnxOnlineStreamInputFinished(session->stream);
  DecodeReady(session);
  session->text = CurrentText(session);

  if (!session->text.empty() && session->context->punctuation != nullptr) {
    std::transform(session->text.begin(), session->text.end(),
                   session->text.begin(), [](unsigned char value) {
                     return static_cast<char>(std::tolower(value));
                   });
    const char *punctuated = SherpaOnnxOnlinePunctuationAddPunct(
        session->context->punctuation, session->text.c_str());
    if (punctuated != nullptr) {
      session->text = punctuated;
      SherpaOnnxOnlinePunctuationFreeText(punctuated);
    }
    session->text = NormalizeEnglishCase(session->text);
  }
  return session->text.c_str();
}

void qvh_sherpa_english_session_destroy(
    QVHSherpaEnglishSession opaque_session) {
  auto *session = static_cast<EnglishSession *>(opaque_session);
  if (session == nullptr) return;
  if (session->stream != nullptr) {
    SherpaOnnxDestroyOnlineStream(session->stream);
  }
  delete session;
}
