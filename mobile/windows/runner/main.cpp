#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "app_links/app_links_plugin_c_api.h"

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // app_links 6.x delivers cold-start links from argv, but an OAuth callback
  // must reach the existing process which owns the PKCE verifier/session.
  // Forward callbacks only; normal launches retain their existing behavior.
  const auto arguments = GetCommandLineArguments();
  for (const auto& argument : arguments) {
    constexpr char callback[] = "humtrack://auth/callback";
    const size_t length = sizeof(callback) - 1;
    if (argument.compare(0, length, callback) == 0 &&
        (argument.size() == length || argument[length] == '?' ||
         argument[length] == '#')) {
      HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"HumTrack");
      if (existing != nullptr) {
        SendAppLink(existing);
        if (::IsIconic(existing)) ::ShowWindow(existing, SW_RESTORE);
        ::SetForegroundWindow(existing);
        return EXIT_SUCCESS;
      }
    }
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  const wchar_t* title = wcsstr(GetCommandLineW(), L"--vocal-compare")
                            ? L"HumTrack - Vocal A/B"
                             : wcsstr(GetCommandLineW(), L"--grid-edit")
                                 ? L"HumTrack - Grid Edit"
                                 : L"HumTrack";
  if (!window.Create(title, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
