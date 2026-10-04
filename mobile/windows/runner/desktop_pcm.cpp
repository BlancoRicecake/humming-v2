#include "desktop_pcm.h"
#include <flutter/standard_method_codec.h>
#include <mmdeviceapi.h>
#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

using flutter::EncodableValue;
using flutter::EncodableMap;
using Microsoft::WRL::ComPtr;
namespace {
int IntArg(const EncodableMap& args, const char* name) {
  auto it = args.find(EncodableValue(name));
  if (it == args.end()) return 0;
  const auto* value = std::get_if<int32_t>(&it->second);
  return value ? *value : 0;
}
}
DesktopPcm::DesktopPcm(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "humtrack/desktop_pcm", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto& method = call.method_name();
    HRESULT hr = S_OK;
    if (method == "setup") {
      const auto* args = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
      if (!args) { result->Error("arguments", "Missing output format"); return; }
      hr = Setup(IntArg(*args, "sampleRate"), IntArg(*args, "channels"));
    } else if (method == "release") {
      Release();
    } else if (method == "remainingFrames") {
      if (!client_) { result->Error("not_ready", "Audio output is not initialized"); return; }
      UINT32 padding = 0;
      hr = client_->GetCurrentPadding(&padding);
      if (SUCCEEDED(hr)) { result->Success(EncodableValue(static_cast<int32_t>(padding))); return; }
    } else if (method == "stats") {
      result->Success(EncodableValue(EncodableMap{
        {EncodableValue("framesWritten"), EncodableValue(frames_written_)},
        {EncodableValue("peak"), EncodableValue(peak_)},
        {EncodableValue("started"), EncodableValue(started_)},
        {EncodableValue("capacityFrames"), EncodableValue(static_cast<int32_t>(capacity_))}}));
      return;
    } else if (method == "feed") {
      const auto* bytes = call.arguments() ? std::get_if<std::vector<uint8_t>>(call.arguments()) : nullptr;
      if (!client_ || !render_) { result->Error("not_ready", "Audio output is not initialized"); return; }
      if (!bytes || bytes->empty() || bytes->size() % (2 * channels_) != 0 || bytes->size() > 192000) {
        result->Error("arguments", "Invalid PCM block"); return;
      }
      UINT32 frames = static_cast<UINT32>(bytes->size() / (2 * channels_));
      UINT32 padding = 0;
      hr = client_->GetCurrentPadding(&padding);
      if (SUCCEEDED(hr) && frames > capacity_ - padding) { result->Error("buffer_full", "Output buffer is full"); return; }
      BYTE* destination = nullptr;
      if (SUCCEEDED(hr)) hr = render_->GetBuffer(frames, &destination);
      if (SUCCEEDED(hr)) {
        std::memcpy(destination, bytes->data(), bytes->size());
        hr = render_->ReleaseBuffer(frames, 0);
      }
      if (SUCCEEDED(hr)) {
        frames_written_ += frames;
        for (size_t i = 0; i < bytes->size(); i += 2) {
          int16_t sample;
          std::memcpy(&sample, bytes->data() + i, sizeof(sample));
          peak_ = std::max(peak_, std::abs(static_cast<int>(sample)));
        }
        if (!started_) { hr = client_->Start(); started_ = SUCCEEDED(hr); }
      }
    } else { result->NotImplemented(); return; }
    if (FAILED(hr)) result->Error("wasapi", "Windows audio error " + std::to_string(static_cast<unsigned long>(hr)));
    else result->Success();
  });
}
DesktopPcm::~DesktopPcm() { channel_->SetMethodCallHandler(nullptr); Release(); }
void DesktopPcm::Release() {
  if (client_) { client_->Stop(); client_->Reset(); }
  render_.Reset(); client_.Reset(); capacity_ = 0; started_ = false;
}
HRESULT DesktopPcm::Setup(int rate, int channels) {
  if (rate != 44100 || channels != 1) return E_INVALIDARG;
  Release();
  ComPtr<IMMDeviceEnumerator> enumerator;
  ComPtr<IMMDevice> device;
  ComPtr<IAudioClient> client;
  ComPtr<IAudioRenderClient> render;
  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
  if (SUCCEEDED(hr)) hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  if (SUCCEEDED(hr)) hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(client.GetAddressOf()));
  WAVEFORMATEX format{};
  format.wFormatTag = WAVE_FORMAT_PCM;
  format.nChannels = static_cast<WORD>(channels);
  format.nSamplesPerSec = rate;
  format.wBitsPerSample = 16;
  format.nBlockAlign = static_cast<WORD>(channels * 2);
  format.nAvgBytesPerSec = rate * format.nBlockAlign;
  if (SUCCEEDED(hr)) hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
      AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
      2500000, 0, &format, nullptr);
  UINT32 capacity = 0;
  if (SUCCEEDED(hr)) hr = client->GetBufferSize(&capacity);
  if (SUCCEEDED(hr)) hr = client->GetService(IID_PPV_ARGS(&render));
  if (FAILED(hr)) return hr;
  client_ = client; render_ = render; capacity_ = capacity; channels_ = channels;
  frames_written_ = 0; peak_ = 0;
  return S_OK;
}
