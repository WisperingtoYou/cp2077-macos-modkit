// IesRaceFix: the game (2.3.1 build 5314028, macOS) sometimes crashes ~4 s after start in a render job that uploads
// light-profile (IES) data: 0x100EBC0A8 reads renderer+0x7650 before the renderer has created that object and locks
// through the null pointer (crash frames 0x209c / 0x113a35c / 0xebc0dc). The more mods load resources at startup, the
// more often the job wins the race (about half of launches with the full mod list). The detour waits for the object.
#include <RED4ext/RED4ext.hpp>

#include <mach-o/dyld.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <thread>

// The macOS SDK fork only has the v1 API names (same mapping as Input Loader's stdafx.hpp).
namespace RED4ext
{
using namespace RED4ext::v1;
}
#define RED4EXT_SEMVER RED4EXT_V1_SEMVER
#define RED4EXT_RUNTIME_INDEPENDENT RED4EXT_V1_RUNTIME_VERSION_INDEPENDENT
#define RED4EXT_SDK_LATEST RED4EXT_V1_SDK_VERSION_1_0_0_COMPAT_0_5_0
#define RED4EXT_API_VERSION_LATEST RED4EXT_API_VERSION_1_COMPAT_0

namespace
{
constexpr uintptr_t kTarget = 0x100EBC0A8; // unslid address of the upload function
constexpr uint32_t kLoadInsn = 0xF97B2800; // ldr x0, [x0, #0x7650] at kTarget + 0x28: confirms the game build

// The function returns its result through x8; a large by-value struct makes clang pass x8 through unchanged.
struct Result { uint8_t bytes[64]; };
using Fn = Result (*)(void*, void*, void*, void*);
Fn g_original = nullptr;

Result Detour(void* aRenderer, void* a1, void* a2, void* a3)
{
    auto slot = reinterpret_cast<std::atomic<void*>*>(static_cast<char*>(aRenderer) + 0x7650);
    if (a1 && a2 && !slot->load(std::memory_order_acquire))
    {
        int ms = 0;
        while (!slot->load(std::memory_order_acquire) && ms < 30000)
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            ms++;
        }
        std::fprintf(stderr, "[IesRaceFix] waited %d ms for the renderer (%s)\n", ms,
                     slot->load() ? "ready" : "still null, continuing");
    }
    return g_original(aRenderer, a1, a2, a3);
}

uintptr_t GameSlide()
{
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
    {
        const char* name = _dyld_get_image_name(i);
        if (name && std::strstr(name, "/Contents/MacOS/Cyberpunk2077"))
            return _dyld_get_image_vmaddr_slide(i);
    }
    return 0;
}
} // namespace

RED4EXT_C_EXPORT bool RED4EXT_CALL Main(RED4ext::PluginHandle aHandle, RED4ext::EMainReason aReason,
                                        const RED4ext::Sdk* aSdk)
{
    if (aReason != RED4ext::EMainReason::Load)
        return true;
    auto target = reinterpret_cast<void*>(kTarget + GameSlide());
    uint32_t insn;
    std::memcpy(&insn, static_cast<char*>(target) + 0x28, sizeof(insn));
    if (insn != kLoadInsn)
    {
        std::fprintf(stderr, "[IesRaceFix] different game build, not hooking\n");
        return true;
    }
    bool ok = aSdk->hooking->Attach(aHandle, target, reinterpret_cast<void*>(&Detour),
                                    reinterpret_cast<void**>(&g_original));
    std::fprintf(stderr, "[IesRaceFix] hook %s\n", ok ? "attached" : "FAILED");
    return true;
}

RED4EXT_C_EXPORT void RED4EXT_CALL Query(RED4ext::PluginInfo* aInfo)
{
    aInfo->name = L"IesRaceFix";
    aInfo->author = L"local";
    aInfo->version = RED4EXT_SEMVER(1, 0, 0);
    aInfo->runtime = RED4EXT_RUNTIME_INDEPENDENT;
    aInfo->sdk = RED4EXT_SDK_LATEST;
}

RED4EXT_C_EXPORT uint32_t RED4EXT_CALL Supports()
{
    return RED4EXT_API_VERSION_LATEST;
}
