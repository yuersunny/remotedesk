#include "input_injector.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <cmath>
#include <cstdint>
#include <memory>
#include <string>

namespace remotedesk {
namespace {

// One mouse/keyboard event at a time; batching would let a fast drag coalesce
// into a single jump.
void SendOne(INPUT* input) {
  if (::SendInput(1, input, sizeof(INPUT)) == 0) {
    // Usually UIPI: we are not allowed to talk to a higher-integrity window
    // (an elevated app, or the secure desktop). Nothing to recover from here;
    // the Dart side treats injection as best-effort.
    ::OutputDebugStringA("[remotedesk] SendInput rejected\n");
  }
}

void VirtualDesktop(RECT* rect) {
  rect->left = ::GetSystemMetrics(SM_XVIRTUALSCREEN);
  rect->top = ::GetSystemMetrics(SM_YVIRTUALSCREEN);
  rect->right = rect->left + ::GetSystemMetrics(SM_CXVIRTUALSCREEN);
  rect->bottom = rect->top + ::GetSystemMetrics(SM_CYVIRTUALSCREEN);
}

// Normalised [0,1] -> Windows absolute coordinate (0..65535 across the virtual
// desktop). MOUSEEVENTF_ABSOLUTE maps 65535 to the far edge of the *virtual*
// desktop only when MOUSEEVENTF_VIRTUALDESK is also set, which every caller
// here does.
LONG ToAbsolute(double normalised, LONG origin, LONG extent) {
  if (extent <= 1) return 0;
  const double clamped = normalised < 0.0 ? 0.0 : (normalised > 1.0 ? 1.0 : normalised);
  const double pixel = static_cast<double>(origin) + clamped * (extent - 1);
  return static_cast<LONG>(std::lround(pixel * 65535.0 / (extent - 1)));
}

void MoveCursor(double x, double y) {
  RECT desktop;
  VirtualDesktop(&desktop);
  INPUT input = {};
  input.type = INPUT_MOUSE;
  input.mi.dx = ToAbsolute(x, desktop.left, desktop.right - desktop.left);
  input.mi.dy = ToAbsolute(y, desktop.top, desktop.bottom - desktop.top);
  input.mi.dwFlags =
      MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
  SendOne(&input);
}

void SendButton(int button, bool down) {
  DWORD flag = 0;
  switch (button) {
    case 0:  // left
      flag = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
      break;
    case 2:  // right
      flag = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
      break;
    case 1:  // middle
      flag = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
      break;
    default:
      return;
  }
  INPUT input = {};
  input.type = INPUT_MOUSE;
  input.mi.dwFlags = flag;
  SendOne(&input);
}

void SendWheel(double dx, double dy) {
  // 120 per notch is the Windows WHEEL_DELTA convention the wire format uses.
  if (dy != 0.0) {
    INPUT input = {};
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = MOUSEEVENTF_WHEEL;
    input.mi.mouseData = static_cast<DWORD>(static_cast<LONG>(std::lround(dy)));
    SendOne(&input);
  }
  if (dx != 0.0) {
    INPUT input = {};
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = MOUSEEVENTF_HWHEEL;
    input.mi.mouseData = static_cast<DWORD>(static_cast<LONG>(std::lround(dx)));
    SendOne(&input);
  }
}

// Keys that Windows considers part of the "extended" set. Without
// KEYEVENTF_EXTENDEDKEY the right-hand modifiers and the navigation cluster
// would report as their left-hand / numpad twins.
bool IsExtendedKey(WORD vk) {
  switch (vk) {
    case VK_RCONTROL:
    case VK_RMENU:
    case VK_INSERT:
    case VK_DELETE:
    case VK_HOME:
    case VK_END:
    case VK_PRIOR:
    case VK_NEXT:
    case VK_LEFT:
    case VK_RIGHT:
    case VK_UP:
    case VK_DOWN:
    case VK_LWIN:
    case VK_RWIN:
    case VK_APPS:
    case VK_DIVIDE:
      return true;
    default:
      return false;
  }
}

// Maps the wire key ids from app/lib/src/input_event.dart (enum InputKey).
// Keep the two tables in step: an id here that does not exist there is
// unreachable, and an id there missing here silently does nothing.
WORD VkForId(int id) {
  if (id >= 1 && id <= 26) return static_cast<WORD>('A' + (id - 1));   // KeyA..KeyZ
  if (id >= 40 && id <= 49) {                                          // Digit1..0
    return id == 49 ? static_cast<WORD>('0')
                    : static_cast<WORD>('1' + (id - 40));
  }
  if (id >= 80 && id <= 91) return static_cast<WORD>(VK_F1 + (id - 80));  // F1..F12
  switch (id) {
    case 60: return VK_RETURN;
    case 61: return VK_ESCAPE;
    case 62: return VK_BACK;
    case 63: return VK_TAB;
    case 64: return VK_SPACE;
    case 65: return VK_OEM_MINUS;
    case 66: return VK_OEM_PLUS;
    case 67: return VK_OEM_4;
    case 68: return VK_OEM_6;
    case 69: return VK_OEM_5;
    case 70: return VK_OEM_1;
    case 71: return VK_OEM_7;
    case 72: return VK_OEM_3;
    case 73: return VK_OEM_COMMA;
    case 74: return VK_OEM_PERIOD;
    case 75: return VK_OEM_2;
    case 76: return VK_CAPITAL;
    case 92: return VK_INSERT;
    case 93: return VK_HOME;
    case 94: return VK_PRIOR;
    case 95: return VK_DELETE;
    case 96: return VK_END;
    case 97: return VK_NEXT;
    case 98: return VK_RIGHT;
    case 99: return VK_LEFT;
    case 100: return VK_DOWN;
    case 101: return VK_UP;
    case 110: return VK_LSHIFT;
    case 111: return VK_RSHIFT;
    case 112: return VK_LCONTROL;
    case 113: return VK_RCONTROL;
    case 114: return VK_LMENU;
    case 115: return VK_RMENU;
    case 116: return VK_LWIN;
    case 117: return VK_RWIN;
    default: return 0;
  }
}

void SendKey(int id, bool down) {
  const WORD vk = VkForId(id);
  if (vk == 0) return;
  INPUT input = {};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = vk;
  DWORD flags = down ? 0 : KEYEVENTF_KEYUP;
  if (IsExtendedKey(vk)) flags |= KEYEVENTF_EXTENDEDKEY;
  input.ki.dwFlags = flags;
  SendOne(&input);
}

// Move the real cursor 3 px through SendInput, read it back, restore it.
//
// Deliberately not SetCursorPos: that bypasses the injection path, so it would
// pass even while SendInput is being dropped (UIPI, secure desktop) - exactly
// the failure this check exists to catch.
//
// ASCII only on purpose: MSVC compiles narrow string literals in the system
// code page, so Chinese here would arrive as mojibake. The Dart side owns the
// user-facing wording and only needs `moved`.
flutter::EncodableMap PointerSelfTest() {
  flutter::EncodableMap info;
  RECT desktop;
  VirtualDesktop(&desktop);
  const LONG wide = desktop.right - desktop.left;
  const LONG tall = desktop.bottom - desktop.top;
  POINT origin = {};
  if (wide <= 1 || tall <= 1 || ::GetCursorPos(&origin) == 0) {
    info[flutter::EncodableValue("trusted")] = flutter::EncodableValue(false);
    info[flutter::EncodableValue("moved")] = flutter::EncodableValue(false);
    info[flutter::EncodableValue("detail")] =
        flutter::EncodableValue(std::string("cursor position unavailable"));
    return info;
  }
  // Probe inward: past the right edge the system clamps the cursor and the
  // read-back would look like "did not move".
  const LONG probe_x =
      (origin.x + 3 < desktop.right) ? origin.x + 3 : origin.x - 3;
  MoveCursor(static_cast<double>(probe_x - desktop.left) / (wide - 1),
             static_cast<double>(origin.y - desktop.top) / (tall - 1));
  ::Sleep(60);
  POINT after = {};
  ::GetCursorPos(&after);
  // Undo through the same path, so the restore is itself a live injection.
  MoveCursor(static_cast<double>(origin.x - desktop.left) / (wide - 1),
             static_cast<double>(origin.y - desktop.top) / (tall - 1));
  const LONG dx = after.x - origin.x;
  const LONG dy = after.y - origin.y;
  // 1 px of slack: normalised -> 0..65535 -> pixel rounds.
  const bool moved = dx > 1 || dx < -1 || dy > 1 || dy < -1;
  info[flutter::EncodableValue("trusted")] = flutter::EncodableValue(true);
  info[flutter::EncodableValue("moved")] = flutter::EncodableValue(moved);
  info[flutter::EncodableValue("origin")] = flutter::EncodableValue(
      std::to_string(static_cast<long long>(origin.x)) + "," +
      std::to_string(static_cast<long long>(origin.y)));
  info[flutter::EncodableValue("after")] = flutter::EncodableValue(
      std::to_string(static_cast<long long>(after.x)) + "," +
      std::to_string(static_cast<long long>(after.y)));
  return info;
}

// ---- EncodableValue helpers ------------------------------------------------

double GetDouble(const flutter::EncodableMap& map, const char* key,
                 double fallback = 0.0) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* value = std::get_if<double>(&it->second)) return *value;
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return static_cast<double>(*value);
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*value);
  }
  return fallback;
}

int GetInt(const flutter::EncodableMap& map, const char* key, int fallback = 0) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return static_cast<int>(*value);
  }
  if (const auto* value = std::get_if<double>(&it->second)) {
    return static_cast<int>(std::lround(*value));
  }
  return fallback;
}

bool GetBool(const flutter::EncodableMap& map, const char* key,
             bool fallback = false) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* value = std::get_if<bool>(&it->second)) return *value;
  return fallback;
}

// ---- Channel handler -------------------------------------------------------

class InjectorChannel {
 public:
  explicit InjectorChannel(flutter::BinaryMessenger* messenger) {
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        messenger, "remotedesk/input",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [](const flutter::MethodCall<flutter::EncodableValue>& call,
           std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
               result) {
          const std::string& method = call.method_name();
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());

          if (method == "screenInfo") {
            RECT desktop;
            VirtualDesktop(&desktop);
            const int width = desktop.right - desktop.left;
            const int height = desktop.bottom - desktop.top;
            flutter::EncodableMap info;
            info[flutter::EncodableValue("available")] =
                flutter::EncodableValue(width > 0 && height > 0);
            info[flutter::EncodableValue("width")] =
                flutter::EncodableValue(width);
            info[flutter::EncodableValue("height")] =
                flutter::EncodableValue(height);
            // Monitors are per-monitor DPI aware (see runner.exe.manifest), so
            // GetSystemMetrics already reports physical pixels.
            info[flutter::EncodableValue("scale")] =
                flutter::EncodableValue(1.0);
            result->Success(flutter::EncodableValue(info));
            return;
          }

          // No arguments, so this has to sit above the args check below.
          if (method == "pointerSelfTest") {
            result->Success(flutter::EncodableValue(PointerSelfTest()));
            return;
          }

          if (args == nullptr) {
            result->Error("bad_args", "expected a map argument");
            return;
          }

          if (method == "pointer") {
            const int action = GetInt(*args, "action");
            const double x = GetDouble(*args, "x");
            const double y = GetDouble(*args, "y");
            // Button events carry a position: the cursor must be there before
            // the press, or the click lands wherever it was last.
            if (action == 0) {
              MoveCursor(x, y);
            } else {
              if (GetBool(*args, "moved")) MoveCursor(x, y);
              SendButton(GetInt(*args, "button"), action == 1);
            }
            result->Success(flutter::EncodableValue());
            return;
          }

          if (method == "wheel") {
            SendWheel(GetDouble(*args, "dx"), GetDouble(*args, "dy"));
            result->Success(flutter::EncodableValue());
            return;
          }

          if (method == "key") {
            SendKey(GetInt(*args, "id"), GetBool(*args, "down"));
            result->Success(flutter::EncodableValue());
            return;
          }

          result->NotImplemented();
        });
  }

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace

void RegisterInputInjector(flutter::BinaryMessenger* messenger) {
  // Intentionally leaked: the engine may outlive the window during shutdown,
  // and the handler must stay valid for as long as the messenger does.
  static InjectorChannel* channel = nullptr;
  if (channel != nullptr) return;
  channel = new InjectorChannel(messenger);
}

}  // namespace remotedesk
