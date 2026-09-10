// Reusable cursor lock for script menus.
// Same path as the REFramework overlay: stop SetCursorPos warps and
// PostMessage WM_APP+1 so the engine shows its cursor. Does not open Insert.
//
// REF only swallows WM_* when Insert is open (m_draw_ui). Script windows
// still set WantCaptureMouse, but that swallow never runs — capture() is
// the same block, gated on hover. Keyboard lock is parked (via.hid).
//
// Lua (after the plugin loads):
//   refcursor.request(true)
//   refcursor.request(false)
//   refcursor.capture(true)   -- pointer is over our menu this frame
//   refcursor.is_requested()
//   refcursor.is_capturing()

#include <atomic>
#include <cstdint>
#include <mutex>

#include <Windows.h>
#include <dxgi.h>

#include <reframework/API.hpp>
#include <sol/sol.hpp>

#pragma comment(lib, "dxgi.lib")

using namespace reframework;

#define RE_TOGGLE_CURSOR (WM_APP + 1)

static std::atomic<int> g_refs{0};
static std::atomic<bool> g_capture{false};
static std::mutex g_patch_mtx;
static void* g_set_cursor_pos{nullptr};
static uint8_t g_orig_byte{0};
static bool g_we_patched{false};
static HWND g_wnd{nullptr};
static bool g_was_requested{false};

static HWND resolve_hwnd() {
    if (g_wnd && IsWindow(g_wnd)) {
        return g_wnd;
    }

    const auto* rd = API::get()->param()->renderer_data;
    if (rd && rd->swapchain) {
        DXGI_SWAP_CHAIN_DESC desc{};
        if (SUCCEEDED(((IDXGISwapChain*)rd->swapchain)->GetDesc(&desc))) {
            g_wnd = desc.OutputWindow;
        }
    }

    return g_wnd;
}

static void toggle_engine_cursor(bool show) {
    const HWND wnd = resolve_hwnd();
    if (!wnd) {
        return;
    }
    PostMessage(wnd, RE_TOGGLE_CURSOR, show ? TRUE : FALSE, 1);
}

static void apply_set_cursor_pos_patch() {
    std::scoped_lock _{g_patch_mtx};

    if (g_we_patched) {
        return;
    }

    if (!g_set_cursor_pos) {
        g_set_cursor_pos = (void*)GetProcAddress(GetModuleHandleA("user32.dll"), "SetCursorPos");
    }
    if (!g_set_cursor_pos) {
        return;
    }

    auto* byte = (uint8_t*)g_set_cursor_pos;
    if (*byte == 0xC3) {
        // Overlay (or someone else) already owns the ret patch.
        return;
    }

    DWORD old_protect = 0;
    if (!VirtualProtect(g_set_cursor_pos, 1, PAGE_EXECUTE_READWRITE, &old_protect)) {
        return;
    }
    g_orig_byte = *byte;
    *byte = 0xC3;
    VirtualProtect(g_set_cursor_pos, 1, old_protect, &old_protect);
    FlushInstructionCache(GetCurrentProcess(), g_set_cursor_pos, 1);
    g_we_patched = true;
}

static void remove_set_cursor_pos_patch() {
    std::scoped_lock _{g_patch_mtx};

    if (!g_we_patched || !g_set_cursor_pos) {
        return;
    }

    DWORD old_protect = 0;
    if (VirtualProtect(g_set_cursor_pos, 1, PAGE_EXECUTE_READWRITE, &old_protect)) {
        *(uint8_t*)g_set_cursor_pos = g_orig_byte;
        VirtualProtect(g_set_cursor_pos, 1, old_protect, &old_protect);
        FlushInstructionCache(GetCurrentProcess(), g_set_cursor_pos, 1);
    }
    g_we_patched = false;
}

static void request(bool want) {
    if (want) {
        g_refs.fetch_add(1, std::memory_order_relaxed);
        return;
    }

    int cur = g_refs.load(std::memory_order_relaxed);
    while (cur > 0 && !g_refs.compare_exchange_weak(cur, cur - 1, std::memory_order_relaxed)) {
    }
    if (g_refs.load(std::memory_order_relaxed) <= 0) {
        g_capture.store(false, std::memory_order_relaxed);
    }
}

static void set_capture(bool want) {
    g_capture.store(want && g_refs.load(std::memory_order_relaxed) > 0, std::memory_order_relaxed);
}

// Same messages REF keeps from the game when Insert is focused and
// WantCaptureMouse is set. Return false = do not call the game wndproc.
static bool on_message(void*, unsigned int message, unsigned long long, long long) {
    if (g_refs.load(std::memory_order_relaxed) <= 0 || !g_capture.load(std::memory_order_relaxed)) {
        return true;
    }
    switch (message) {
    case WM_MOUSEMOVE:
    case WM_LBUTTONDOWN:
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
    case WM_RBUTTONDOWN:
    case WM_RBUTTONUP:
    case WM_RBUTTONDBLCLK:
    case WM_MBUTTONDOWN:
    case WM_MBUTTONUP:
    case WM_MBUTTONDBLCLK:
    case WM_XBUTTONDOWN:
    case WM_XBUTTONUP:
    case WM_MOUSEWHEEL:
    case WM_MOUSEHWHEEL:
    case WM_INPUT:
        return false;
    default:
        return true;
    }
}

static void on_present() {
    const bool want = g_refs.load(std::memory_order_relaxed) > 0;

    if (want) {
        apply_set_cursor_pos_patch();
        if (!g_was_requested) {
            toggle_engine_cursor(true);
        }
    } else if (g_was_requested) {
        remove_set_cursor_pos_patch();
        toggle_engine_cursor(false);
    }

    g_was_requested = want;
}

static void on_lua_state_created(lua_State* l) {
    API::LuaLock _{};
    sol::state_view lua{l};
    sol::table t = lua.create_named_table("refcursor");
    t["request"] = [](sol::object value) {
        request(value.valid() && value != sol::lua_nil && value.as<bool>());
    };
    t["capture"] = [](sol::object value) {
        set_capture(value.valid() && value != sol::lua_nil && value.as<bool>());
    };
    t["is_requested"] = []() {
        return g_refs.load(std::memory_order_relaxed) > 0;
    };
    t["is_capturing"] = []() {
        return g_capture.load(std::memory_order_relaxed);
    };
}

static void on_lua_state_destroyed(lua_State*) {
    g_refs.store(0, std::memory_order_relaxed);
    g_capture.store(false, std::memory_order_relaxed);
}

extern "C" __declspec(dllexport) void reframework_plugin_required_version(REFrameworkPluginVersion* version) {
    version->major = REFRAMEWORK_PLUGIN_VERSION_MAJOR;
    version->minor = REFRAMEWORK_PLUGIN_VERSION_MINOR;
    version->patch = REFRAMEWORK_PLUGIN_VERSION_PATCH;
}

extern "C" __declspec(dllexport) bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam* param) {
    API::initialize(param);

    const auto* fn = param->functions;
    fn->on_lua_state_created(on_lua_state_created);
    fn->on_lua_state_destroyed(on_lua_state_destroyed);
    fn->on_present(on_present);
    fn->on_message((REFOnMessageCb)on_message);
    fn->log_info("[refcursor] loaded — request() for cursor, capture() to swallow hover input");

    return true;
}
