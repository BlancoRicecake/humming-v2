#ifndef HUMTRACK_DESKTOP_PCM_H_
#define HUMTRACK_DESKTOP_PCM_H_
#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <audioclient.h>
#include <wrl/client.h>
#include <memory>

// Shared-mode WASAPI; all calls run on Flutter's platform thread.
class DesktopPcm {
 public:
  explicit DesktopPcm(flutter::BinaryMessenger* messenger);
  ~DesktopPcm();
 private:
  HRESULT Setup(int rate, int channels);
  void Release();
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  Microsoft::WRL::ComPtr<IAudioClient> client_;
  Microsoft::WRL::ComPtr<IAudioRenderClient> render_;
  UINT32 capacity_ = 0;
  int channels_ = 1;
  bool started_ = false;
  int64_t frames_written_ = 0;
  int peak_ = 0;
};
#endif
