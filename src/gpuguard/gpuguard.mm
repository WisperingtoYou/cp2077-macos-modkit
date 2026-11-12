// gpuguard: injectable GPU-error logger + shared-event recovery for the stock game (no game addresses).
//
// Why: the 10-22 13:36 freeze is a CPU thread spinning forever on `[MTLSharedEvent signaledValue] >= v` for a frame
// fence. If the command buffer that carried `encodeSignalEvent:v` fails on the GPU (page fault, timeout, ...), the
// signal never executes and the engine waits forever. gpuguard logs every failed command buffer and (by default)
// performs the missing signals from the CPU so the engine can continue.
//
// Hooks (ObjC, on the concrete AGX classes found at runtime from probe objects, same scheme as metal_census/fgpace):
//   command buffer: encodeSignalEvent:value:, encodeWaitForEvent:value:  -> per-CB list (associated object)
//                   commit                                              -> addCompletedHandler + in-flight table
//   command queue: commandBuffer, commandBufferWithUnretainedReferences, commandBufferWithDescriptor:
//                   -> redirected to a replacement queue once macOS has blocked this queue (see "queue swap" below);
//                      with GPUGUARD_ENCINFO=1 also errorOptions |= MTLCommandBufferErrorOptionEncoderExecutionStatus
// Nothing reads or writes any resource.
//
// Env:
//   GPUGUARD_RECOVER=0    (default) 1 = on CB error, raise each event it should have signaled to its value from the CPU
//   GPUGUARD_QSWAP=0      (default) 1 = after a GPU timeout, move a blocked queue's new command buffers to a fresh queue
//                         Both are off because they keep the game alive on a wedged GPU; its own crash handler frees the GPU.
//   GPUGUARD_MEM_S=15     log one memory line every N seconds (game, GPU, swap, pressure, thermal); 0 = off
//   GPUGUARD_ENCINFO=0    (default) 1 = per-encoder execution status in errors (see README for the measured cost)
//   GPUGUARD_HANG_S=10    log (only) committed CBs not completed after this many seconds; 0 = off
//   GPUGUARD_STALL_S=10   log (only) when no CB has been committed for this many seconds (CPU-side freeze marker); 0 = off
//   GPUGUARD_HEARTBEAT_S=300  periodic one-line summary; 0 = only at exit
//   GPUGUARD_LOG=path     default: <game folder>/gpuguard.log (folder containing Cyberpunk2077.app), else cwd
//   GPUGUARD_PROCESS=name process to activate in (default Cyberpunk2077); inert in every other process
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#include <objc/runtime.h>
#include <os/lock.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <IOKit/IOKitLib.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <unordered_map>
#include <vector>
#include <unistd.h>

// ---------------------------------------------------------------- config / log
static int g_recover = 0, g_encinfo = 0, g_qswap = 0;
static double g_hangS = 10, g_stallS = 10, g_heartbeatS = 300, g_memS = 15;
static id<MTLDevice> g_dev;
static FILE* g_log; static os_unfair_lock g_logLk = OS_UNFAIR_LOCK_INIT;
static double Now() { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
  return (double)mach_absolute_time() * tb.numer / tb.denom * 1e-9; }
static double g_t0;
static char g_capturePath[4096];  // plain char: Init() runs before C++ globals are constructed

__attribute__((format(printf, 1, 2))) static void Log(const char* fmt, ...) {
  char msg[4096]; va_list ap; va_start(ap, fmt); vsnprintf(msg, sizeof msg, fmt, ap); va_end(ap);
  struct timeval tv; gettimeofday(&tv, nullptr); struct tm lt; localtime_r(&tv.tv_sec, &lt);
  char ts[64]; strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &lt);
  os_unfair_lock_lock(&g_logLk);
  if (g_log) { fprintf(g_log, "%s.%03d gpuguard[%d] %s\n", ts, (int)(tv.tv_usec / 1000), getpid(), msg); fflush(g_log); }
  fprintf(stderr, "%s.%03d gpuguard[%d] %s\n", ts, (int)(tv.tv_usec / 1000), getpid(), msg);
  os_unfair_lock_unlock(&g_logLk);
}

// ---------------------------------------------------------------- hook table (same scheme as metal_census / fgpace)
struct HookEnt { Class c; SEL s; IMP orig; IMP hook; };
static HookEnt g_hooks[128]; static std::atomic<int> g_nhooks{0};
static IMP Orig(id self, SEL s) {
  int n = g_nhooks.load(std::memory_order_acquire);
  for (Class c = object_getClass(self); c; c = class_getSuperclass(c))
    for (int i = 0; i < n; i++) if (g_hooks[i].c == c && g_hooks[i].s == s) return g_hooks[i].orig;
  Method m = class_getInstanceMethod(object_getClass(self), s);
  return m ? method_getImplementation(m) : nullptr;
}
static bool IsHook(IMP p) { int n = g_nhooks.load(); for (int i = 0; i < n; i++) if (g_hooks[i].hook == p) return true; return false; }
static void Hook(Class c, SEL s, IMP h) {
  Method m = class_getInstanceMethod(c, s);
  if (!m) { Log("  no %s on %s", sel_getName(s), class_getName(c)); return; }
  IMP cur = method_getImplementation(m);
  if (IsHook(cur)) return;
  int i = g_nhooks.load(); if (i >= 128) { Log("  hook table full, %s not hooked", sel_getName(s)); return; }
  g_hooks[i] = {c, s, cur, h};
  g_nhooks.store(i + 1, std::memory_order_release);
  if (!class_addMethod(c, s, h, method_getTypeEncoding(m))) method_setImplementation(m, h);
}

// ---------------------------------------------------------------- per command buffer state
struct EvOp { __strong id<MTLEvent> ev; uint64_t v; bool wait; };
@interface GGInfo : NSObject {
@public
  std::vector<EvOp> ops;
  double tCommit; uint64_t seq; void* cb; void* queue; bool hangLogged; bool inflight; bool rescue;
  uint16_t enc[4];  // encoders by kind, see NoteEnc
}
@end
@implementation GGInfo
@end
static char kInfoKey;
static os_unfair_lock g_flightLk = OS_UNFAIR_LOCK_INIT;
static std::unordered_map<void*, GGInfo*>* g_inflight;  // committed, not yet completed (ARC: strong refs)
static std::atomic<uint64_t> g_committed{0}, g_completed{0}, g_errors{0}, g_recovered{0}, g_hangs{0}, g_withSignals{0};
static std::atomic<double> g_lastCommit{0}, g_maxLat{0};

static GGInfo* InfoFor(id cb, bool create) {
  GGInfo* i = objc_getAssociatedObject(cb, &kInfoKey);
  if (!i && create) { i = [GGInfo new]; objc_setAssociatedObject(cb, &kInfoKey, i, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
  return i;
}

// events seen (strong refs, capped): used for stall dumps
static os_unfair_lock g_evLk = OS_UNFAIR_LOCK_INIT;
struct EvSeen { __strong id<MTLEvent> ev; uint64_t maxSig; };
static std::vector<EvSeen>* g_events;
static void NoteEvent(id<MTLEvent> ev, uint64_t v, bool sig) {
  os_unfair_lock_lock(&g_evLk);
  bool found = false;
  for (auto& e : *g_events) if (e.ev == ev) { if (sig && v > e.maxSig) e.maxSig = v; found = true; break; }
  if (!found && g_events->size() < 64) g_events->push_back({ev, sig ? v : 0});
  os_unfair_lock_unlock(&g_evLk);
}

static std::string EvName(id<MTLEvent> ev) {
  char b[160]; NSString* lb = ev.label;
  snprintf(b, sizeof b, "%p%s%s%s", (__bridge void*)ev, lb ? "(" : "", lb ? (lb.UTF8String ?: "?") : "", lb ? ")" : "");
  return b;
}
static bool IsShared(id<MTLEvent> ev) { return [ev respondsToSelector:@selector(signaledValue)] && [ev respondsToSelector:@selector(setSignaledValue:)]; }
static std::string OpsStr(GGInfo* info, bool withCurrent) {
  std::string s;
  for (auto& o : info->ops) {
    char b[256];
    if (withCurrent && IsShared(o.ev))
      snprintf(b, sizeof b, " %s:%s=%llu(now %llu)", o.wait ? "wait" : "signal", EvName(o.ev).c_str(), (unsigned long long)o.v,
               (unsigned long long)((id<MTLSharedEvent>)o.ev).signaledValue);
    else snprintf(b, sizeof b, " %s:%s=%llu", o.wait ? "wait" : "signal", EvName(o.ev).c_str(), (unsigned long long)o.v);
    if (s.size() < 1500) s += b;
  }
  return s.empty() ? " (no event ops)" : s;
}

// Recent completed command buffers, so the first error can show what else was on the GPU.
struct RecentCB { uint64_t seq; void* queue; double start, end; uint16_t enc[4]; };
static const int kRecent = 256;
static RecentCB g_recent[kRecent]; static uint64_t g_recentN;
static os_unfair_lock g_recentLk = OS_UNFAIR_LOCK_INIT;
static std::string EncStr(const uint16_t* e) {
  char b[80]; snprintf(b, sizeof b, "render=%u compute=%u blit=%u accel=%u", e[0], e[1], e[2], e[3]);
  return b;
}
static void DumpRecent(double failedStart) {
  std::vector<RecentCB> done;
  os_unfair_lock_lock(&g_recentLk);
  for (uint64_t i = g_recentN > kRecent ? g_recentN - kRecent : 0; i < g_recentN; i++) done.push_back(g_recent[i % kRecent]);
  os_unfair_lock_unlock(&g_recentLk);
  Log("  recent completed command buffers (%zu, failed one started at gpu %.3f):", done.size(), failedStart);
  for (auto& r : done) Log("    seq=%llu queue=%p gpu %.4f..%.4f %s", (unsigned long long)r.seq, r.queue, r.start, r.end, EncStr(r.enc).c_str());
  os_unfair_lock_lock(&g_flightLk);
  std::vector<GGInfo*> flying; for (auto& kv : *g_inflight) flying.push_back(kv.second);
  os_unfair_lock_unlock(&g_flightLk);
  Log("  still in flight (%zu):", flying.size());
  for (GGInfo* i : flying) Log("    seq=%llu %s", (unsigned long long)i->seq, EncStr(i->enc).c_str());
}

// ---------------------------------------------------------------- error handling
static const char* ErrName(NSInteger c) {
  switch (c) {
    case 0: return "None"; case 1: return "Internal"; case 2: return "Timeout"; case 3: return "PageFault";
    case 4: return "AccessRevoked(Blacklisted)"; case 7: return "NotPermitted"; case 8: return "OutOfMemory";
    case 9: return "InvalidResource"; case 10: return "Memoryless"; case 11: return "DeviceRemoved"; case 12: return "StackOverflow";
    default: return "?";
  }
}
static const char* EncState(NSInteger s) {
  switch (s) { case 0: return "Unknown"; case 1: return "Completed"; case 2: return "Affected"; case 3: return "Pending"; case 4: return "Faulted"; default: return "?"; }
}
static const int kDetailedErrors = 40;      // full lines for the first N errors, then one summary line per 10 s
static std::atomic<double> g_lastErrSummary{0}; static std::atomic<uint64_t> g_errSinceSummary{0};

// Non-shared MTLEvents cannot be signaled from the CPU. They are signaled from the GPU instead: a command buffer on
// gpuguard's own queue that contains only encodeSignalEvent (events are monotonic, so this can never lower a value).
// Its info is marked `rescue` so that, should it fail too, it is logged but never re-rescued.
static id<MTLCommandQueue> g_rescueQ; static os_unfair_lock g_rescueLk = OS_UNFAIR_LOCK_INIT;
static void GpuSignal(id<MTLEvent> ev, uint64_t v) {
  os_unfair_lock_lock(&g_rescueLk);
  if (!g_rescueQ) { g_rescueQ = [ev.device newCommandQueue]; g_rescueQ.label = @"gpuguard.rescue"; }
  id<MTLCommandQueue> q = g_rescueQ;
  os_unfair_lock_unlock(&g_rescueLk);
  id<MTLCommandBuffer> cb = [q commandBuffer]; cb.label = @"gpuguard.rescue";
  GGInfo* ri = [GGInfo new]; ri->rescue = true; objc_setAssociatedObject(cb, &kInfoKey, ri, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [cb encodeSignalEvent:ev value:v];
  [cb commit];
}
// Queue swap. A GPU timeout makes macOS ignore everything later submitted to that one queue, for the life of the process
// (kIOGPUCommandBufferCallbackErrorSubmissionsIgnored); other and new queues keep working (gg_harness block). So new
// command buffers asked of a blocked queue are created on a replacement. Keys stay strongly held so a freed queue's
// address can never be mistaken for a blocked one.
static const int kMaxSwaps = 256;  // one slow spell used 27; the cap only stops a game that hangs without end
static os_unfair_lock g_swapLk = OS_UNFAIR_LOCK_INIT;
struct SwapEnt { __strong id<MTLCommandQueue> blocked, repl; };
static std::vector<SwapEnt>* g_swaps;
static std::atomic<int> g_nswaps{0};
static std::atomic<double> g_swapT{0};
static __weak id<MTLCommandQueue> g_watchQ;  // latest replacement, until its first command buffer completes
static id Live(id q) {
  if (g_nswaps.load(std::memory_order_relaxed) == 0) return q;
  os_unfair_lock_lock(&g_swapLk);
  for (bool moved = true; moved;) { moved = false; for (auto& s : *g_swaps) if (s.blocked == q) { q = s.repl; moved = true; break; } }
  os_unfair_lock_unlock(&g_swapLk);
  return q;
}
static void SwapQueue(id<MTLCommandQueue> q, NSInteger code) {
  if (!g_qswap || !q) return;
  os_unfair_lock_lock(&g_swapLk);
  bool known = false; for (auto& s : *g_swaps) if (s.blocked == q) known = true;
  size_t n = g_swaps->size();
  os_unfair_lock_unlock(&g_swapLk);
  if (known) return;
  if (n >= kMaxSwaps) { static std::atomic<bool> said{false}; if (!said.exchange(true)) Log("QUEUE SWAP: limit of %d reached, not swapping any more", kMaxSwaps); return; }
  id<MTLCommandQueue> r = [q.device newCommandQueueWithMaxCommandBufferCount:1024];  // the default 64 is below what the engine keeps in flight
  if (!r) { Log("QUEUE SWAP: could not create a replacement for %p", (__bridge void*)q); return; }
  r.label = q.label;
  os_unfair_lock_lock(&g_swapLk);
  known = false; for (auto& s : *g_swaps) if (s.blocked == q) known = true;  // two completion handlers can race here
  if (!known) { g_swaps->push_back({q, r}); g_nswaps.store((int)g_swaps->size()); g_watchQ = r; }
  os_unfair_lock_unlock(&g_swapLk);
  if (known) return;
  g_swapT.store(Now());
  Log("QUEUE SWAP #%d: queue %p('%s') blocked (%s), new command buffers go to %p", g_nswaps.load(), (__bridge void*)q, q.label.UTF8String ?: "", ErrName(code), (__bridge void*)r);
}
static void Recover(GGInfo* info, const char* why) {
  for (auto& o : info->ops) {
    if (o.wait) continue;
    if (!IsShared(o.ev)) {
      if (o.ev.device) { GpuSignal(o.ev, o.v); g_recovered++; Log("  RECOVER (%s): non-shared %s -> %llu signaled from a gpuguard GPU command buffer", why, EvName(o.ev).c_str(), (unsigned long long)o.v); }
      continue;
    }
    id<MTLSharedEvent> se = (id<MTLSharedEvent>)o.ev;
    uint64_t cur = se.signaledValue;
    if (cur >= o.v) { Log("  recover: %s already at %llu >= %llu, left alone", EvName(o.ev).c_str(), (unsigned long long)cur, (unsigned long long)o.v); continue; }
    se.signaledValue = o.v;  // monotonic: only ever raised, never lowered (cur < v checked just above)
    uint64_t after = se.signaledValue;
    g_recovered++;
    Log("  RECOVER (%s): %s %llu -> %llu (now reads %llu)", why, EvName(o.ev).c_str(), (unsigned long long)cur, (unsigned long long)o.v, (unsigned long long)after);
  }
}

static void OnError(id<MTLCommandBuffer> b, GGInfo* info, double lat) {
  uint64_t n = ++g_errors;
  NSError* e = b.error;
  if ([e.domain isEqualToString:MTLCommandBufferErrorDomain] && (e.code == MTLCommandBufferErrorTimeout || e.code == MTLCommandBufferErrorAccessRevoked)) {
    if (info->rescue) { os_unfair_lock_lock(&g_rescueLk); if (g_rescueQ == b.commandQueue) g_rescueQ = nil; os_unfair_lock_unlock(&g_rescueLk); }
    else SwapQueue(b.commandQueue, e.code);
  }
  if (n > kDetailedErrors) {
    g_errSinceSummary++;
    double now = Now();
    if (now - g_lastErrSummary.load() > 10) {
      g_lastErrSummary.store(now);
      Log("ERROR x%llu more command-buffer errors (total %llu, last: %s code %ld %s)", (unsigned long long)g_errSinceSummary.exchange(0),
          (unsigned long long)n, e.domain.UTF8String ?: "?", (long)e.code, ErrName(e.code));
    }
    if (g_recover && !info->rescue) {  // keep recovering, without per-signal lines
      for (auto& o : info->ops) if (!o.wait) {
        if (IsShared(o.ev)) { id<MTLSharedEvent> se = (id<MTLSharedEvent>)o.ev; if (se.signaledValue < o.v) { se.signaledValue = o.v; g_recovered++; } }
        else if (o.ev.device) { GpuSignal(o.ev, o.v); g_recovered++; }
      }
    }
    return;
  }
  NSString* lb = b.label; id<MTLCommandQueue> q = b.commandQueue; NSString* ql = q.label;
  Log("ERROR #%llu cb=%p seq=%llu label='%s' queue=%p('%s') status=%ld commit->complete %.1f ms gpu %.3f..%.3f",
      (unsigned long long)n, (__bridge void*)b, (unsigned long long)info->seq, lb ? lb.UTF8String : "", (__bridge void*)q, ql ? ql.UTF8String : "",
      (long)b.status, lat * 1e3, b.GPUStartTime, b.GPUEndTime);
  if (e) {
    Log("  error domain=%s code=%ld (%s) desc='%s'", e.domain.UTF8String ?: "?", (long)e.code,
        [e.domain isEqualToString:MTLCommandBufferErrorDomain] ? ErrName(e.code) : "-", e.localizedDescription.UTF8String ?: "");
    for (NSString* k in e.userInfo) {
      id v = e.userInfo[k];
      if ([k isEqualToString:MTLCommandBufferEncoderInfoErrorKey] && [v isKindOfClass:[NSArray class]]) {
        NSArray* a = v; int cnt[5] = {0};
        std::string bad;
        for (NSUInteger i = 0; i < a.count; i++) {
          id<MTLCommandBufferEncoderInfo> ei = a[i]; NSInteger st = ei.errorState; if (st >= 0 && st < 5) cnt[st]++;
          if (st == MTLCommandEncoderErrorStateFaulted || st == MTLCommandEncoderErrorStateAffected) {
            char t[200]; snprintf(t, sizeof t, " #%lu:%s'%s'%s", (unsigned long)i, EncState(st), ei.label.UTF8String ?: "",
                                 ei.debugSignposts.count ? [[ei.debugSignposts componentsJoinedByString:@"/"] UTF8String] : "");
            if (bad.size() < 1500) bad += t;
          }
        }
        Log("  encoders=%lu completed=%d affected=%d pending=%d faulted=%d unknown=%d%s", (unsigned long)a.count, cnt[1], cnt[2], cnt[3], cnt[4], cnt[0], bad.c_str());
      } else {
        NSString* d = [[v description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        if (d.length > 600) d = [d substringToIndex:600];
        Log("  userInfo %s = %s", k.UTF8String, d.UTF8String);
      }
    }
  } else Log("  status Error but error == nil");
  Log("  event ops:%s", OpsStr(info, true).c_str());
  Log("  encoders: %s", EncStr(info->enc).c_str());
  if (n == 1) DumpRecent(b.GPUStartTime);
  if (info->rescue) Log("  (gpuguard's own rescue command buffer: not retried)");
  else if (g_recover) Recover(info, e ? ErrName(e.code) : "error");
  else Log("  recovery disabled (GPUGUARD_RECOVER=0): signals above stay missing");
}

// ---------------------------------------------------------------- hooks
typedef void (*FnEv)(id, SEL, id, uint64_t);
typedef void (*FnV)(id, SEL);
typedef id (*FnId)(id, SEL);
typedef id (*FnIdD)(id, SEL, id);
static void Hk_signal(id self, SEL s, id ev, uint64_t v) {
  if (ev) { GGInfo* i = InfoFor(self, true); i->ops.push_back({ev, v, false}); NoteEvent(ev, v, true); }
  ((FnEv)Orig(self, s))(self, s, ev, v);
}
static void Hk_wait(id self, SEL s, id ev, uint64_t v) {
  if (ev) { GGInfo* i = InfoFor(self, true); i->ops.push_back({ev, v, true}); }
  ((FnEv)Orig(self, s))(self, s, ev, v);
}
// Encoder creation, counted per command buffer. Log only: the original always runs, with the same arguments.
enum { kRender, kCompute, kBlit, kAccel };
typedef id (*FnIdU)(id, SEL, NSUInteger);
static void NoteEnc(id cb, int kind) { GGInfo* i = InfoFor(cb, true); if (i->enc[kind] < 0xffff) i->enc[kind]++; }
template <int K> static id Hk_enc(id self, SEL s) { NoteEnc(self, K); return ((FnId)Orig(self, s))(self, s); }
template <int K> static id Hk_encD(id self, SEL s, id d) { NoteEnc(self, K); return ((FnIdD)Orig(self, s))(self, s, d); }
static id Hk_encU(id self, SEL s, NSUInteger u) { NoteEnc(self, kCompute); return ((FnIdU)Orig(self, s))(self, s, u); }

// ---------------------------------------------------------------- impossible mip counts
// Some mod textures claim more mip levels than their size allows (a 200x200 Virtual Atelier icon with 11). Windows runs
// them; Metal's descriptor check aborts the game. Clamp the count before that check, and drop copies and views that
// reach the levels that were cut. Until the first clamp the copy hooks only pass through.
static std::atomic<int> g_mipClamps{0}, g_mipDrops{0};
static NSUInteger MaxLevels(MTLTextureDescriptor* d) {
  NSUInteger m = MAX(d.width, d.height), n = 1;
  if (d.textureType == MTLTextureType3D) m = MAX(m, d.depth);
  while (m > 1) { m >>= 1; n++; }
  return n;
}
typedef uintptr_t (*FnValidate)(id, SEL, id);
static uintptr_t Hk_validate(id self, SEL s, id dev) {
  MTLTextureDescriptor* d = self;
  NSUInteger want = d.mipmapLevelCount, max = MaxLevels(d);
  if (want > max) {
    d.mipmapLevelCount = max;
    int n = ++g_mipClamps;
    if (n <= 20) Log("texture %lux%lu format %lu asks for %lu mip levels, most possible %lu: clamped (#%d)", (unsigned long)d.width,
                     (unsigned long)d.height, (unsigned long)d.pixelFormat, (unsigned long)want, (unsigned long)max, n);
  }
  return ((FnValidate)Orig(self, s))(self, s, dev);
}
static bool LevelOK(id<MTLTexture> t, NSUInteger level, const char* what) {
  if (g_mipClamps.load(std::memory_order_relaxed) == 0 || !t || level < t.mipmapLevelCount) return true;
  if (++g_mipDrops <= 20)
    Log("dropped %s into level %lu of a %lu-level %lux%lu texture (label %s)", what, (unsigned long)level, (unsigned long)t.mipmapLevelCount,
        (unsigned long)t.width, (unsigned long)t.height, t.label ? t.label.UTF8String : "-");
  return false;
}
typedef void (*FnCopyB)(id, SEL, id, NSUInteger, NSUInteger, NSUInteger, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin);
static void Hk_copyB(id self, SEL s, id b, NSUInteger off, NSUInteger bpr, NSUInteger bpi, MTLSize sz, id<MTLTexture> t, NSUInteger sl, NSUInteger lv, MTLOrigin o) {
  if (LevelOK(t, lv, "buffer copy")) ((FnCopyB)Orig(self, s))(self, s, b, off, bpr, bpi, sz, t, sl, lv, o);
}
typedef void (*FnCopyBO)(id, SEL, id, NSUInteger, NSUInteger, NSUInteger, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin, MTLBlitOption);
static void Hk_copyBO(id self, SEL s, id b, NSUInteger off, NSUInteger bpr, NSUInteger bpi, MTLSize sz, id<MTLTexture> t, NSUInteger sl, NSUInteger lv, MTLOrigin o,
                      MTLBlitOption opt) {
  if (LevelOK(t, lv, "buffer copy")) ((FnCopyBO)Orig(self, s))(self, s, b, off, bpr, bpi, sz, t, sl, lv, o, opt);
}
typedef void (*FnCopyT)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin);
static void Hk_copyT(id self, SEL s, id<MTLTexture> a, NSUInteger as, NSUInteger al, MTLOrigin ao, MTLSize sz, id<MTLTexture> b, NSUInteger bs, NSUInteger bl, MTLOrigin bo) {
  if (LevelOK(a, al, "texture copy") && LevelOK(b, bl, "texture copy")) ((FnCopyT)Orig(self, s))(self, s, a, as, al, ao, sz, b, bs, bl, bo);
}
typedef void (*FnCopyTL)(id, SEL, id, NSUInteger, NSUInteger, id, NSUInteger, NSUInteger, NSUInteger, NSUInteger);
static void Hk_copyTL(id self, SEL s, id<MTLTexture> a, NSUInteger as, NSUInteger al, id<MTLTexture> b, NSUInteger bs, NSUInteger bl, NSUInteger n, NSUInteger lc) {
  if (g_mipClamps.load(std::memory_order_relaxed)) {
    NSUInteger fit = MIN(a.mipmapLevelCount > al ? a.mipmapLevelCount - al : 0, b.mipmapLevelCount > bl ? b.mipmapLevelCount - bl : 0);
    if (lc > fit) {
      if (++g_mipDrops <= 20) Log("level copy of %lu levels cut to %lu", (unsigned long)lc, (unsigned long)fit);
      lc = fit;
    }
    if (lc == 0) return;
  }
  ((FnCopyTL)Orig(self, s))(self, s, a, as, al, b, bs, bl, n, lc);
}
typedef void (*FnReplace)(id, SEL, MTLRegion, NSUInteger, const void*, NSUInteger);
static void Hk_replace(id self, SEL s, MTLRegion r, NSUInteger lv, const void* p, NSUInteger bpr) {
  if (LevelOK(self, lv, "upload")) ((FnReplace)Orig(self, s))(self, s, r, lv, p, bpr);
}
typedef void (*FnReplaceS)(id, SEL, MTLRegion, NSUInteger, NSUInteger, const void*, NSUInteger, NSUInteger);
static void Hk_replaceS(id self, SEL s, MTLRegion r, NSUInteger lv, NSUInteger sl, const void* p, NSUInteger bpr, NSUInteger bpi) {
  if (LevelOK(self, lv, "upload")) ((FnReplaceS)Orig(self, s))(self, s, r, lv, sl, p, bpr, bpi);
}
static NSRange FitLevels(id<MTLTexture> t, NSRange lv) {
  NSUInteger c = t.mipmapLevelCount;
  if (g_mipClamps.load(std::memory_order_relaxed) == 0 || lv.location + lv.length <= c) return lv;
  if (++g_mipDrops <= 20) Log("view of levels %lu+%lu clamped to a %lu-level texture", (unsigned long)lv.location, (unsigned long)lv.length, (unsigned long)c);
  if (lv.location >= c) lv.location = c - 1;
  lv.length = MAX((NSUInteger)1, MIN(lv.length, c - lv.location));
  return lv;
}
typedef id (*FnView)(id, SEL, MTLPixelFormat, MTLTextureType, NSRange, NSRange);
static id Hk_view(id self, SEL s, MTLPixelFormat f, MTLTextureType ty, NSRange lv, NSRange sl) {
  return ((FnView)Orig(self, s))(self, s, f, ty, FitLevels(self, lv), sl);
}
typedef id (*FnViewSw)(id, SEL, MTLPixelFormat, MTLTextureType, NSRange, NSRange, MTLTextureSwizzleChannels);
static id Hk_viewSw(id self, SEL s, MTLPixelFormat f, MTLTextureType ty, NSRange lv, NSRange sl, MTLTextureSwizzleChannels sw) {
  return ((FnViewSw)Orig(self, s))(self, s, f, ty, FitLevels(self, lv), sl, sw);
}
static void InstallMipGuard(id<MTLDevice> dev, id<MTLCommandQueue> q) {
  MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:YES];
  Method vm = class_getInstanceMethod(object_getClass(td), @selector(validateWithDevice:));
  const char* enc = vm ? method_getTypeEncoding(vm) : nullptr;
  // Only hook a check shaped as expected: one object argument (encoding like "B24@0:8@16").
  if (!enc || !strstr(enc, "@0:8@16") || strlen(enc) > 12) { Log("mip guard off: validateWithDevice: is %s", enc ? enc : "missing"); return; }
  Hook(object_getClass(td), @selector(validateWithDevice:), (IMP)Hk_validate);
  td.storageMode = MTLStorageModePrivate;
  MTLHeapDescriptor* hd = [MTLHeapDescriptor new]; hd.size = 1 << 20; hd.storageMode = MTLStorageModePrivate;
  id<MTLHeap> heap = [dev newHeapWithDescriptor:hd];
  id<MTLTexture> texs[2] = {[dev newTextureWithDescriptor:td], heap ? [heap newTextureWithDescriptor:td] : nil};
  for (id<MTLTexture> t : texs) {
    if (!t) continue;
    Class c = object_getClass(t);
    Hook(c, @selector(replaceRegion:mipmapLevel:withBytes:bytesPerRow:), (IMP)Hk_replace);
    Hook(c, @selector(replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:), (IMP)Hk_replaceS);
    Hook(c, @selector(newTextureViewWithPixelFormat:textureType:levels:slices:), (IMP)Hk_view);
    Hook(c, @selector(newTextureViewWithPixelFormat:textureType:levels:slices:swizzle:), (IMP)Hk_viewSw);
  }
  id<MTLBlitCommandEncoder> be = [[q commandBuffer] blitCommandEncoder];
  Class bc = object_getClass(be);
  [be endEncoding];
  Hook(bc, @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:),
       (IMP)Hk_copyB);
  Hook(bc, @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:options:),
       (IMP)Hk_copyBO);
  Hook(bc, @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:),
       (IMP)Hk_copyT);
  Hook(bc, @selector(copyFromTexture:sourceSlice:sourceLevel:toTexture:destinationSlice:destinationLevel:sliceCount:levelCount:), (IMP)Hk_copyTL);
  Log("mip guard on (%s, blit %s)", enc, class_getName(bc));
}
static void Hk_commit(id self, SEL s) {
  GGInfo* info = InfoFor(self, false);
  if (!info) info = [GGInfo new];  // CBs that encoded nothing: still watched for errors
  if (!info->ops.empty()) g_withSignals++;
  info->tCommit = Now(); info->seq = g_committed.fetch_add(1); info->cb = (__bridge void*)self;
  g_lastCommit.store(info->tCommit, std::memory_order_relaxed);
  if (g_hangS > 0) { info->inflight = true; os_unfair_lock_lock(&g_flightLk); (*g_inflight)[(__bridge void*)info] = info; os_unfair_lock_unlock(&g_flightLk); }
  [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> b) {
    double lat = Now() - info->tCommit;
    g_completed++;
    if (info->inflight) { os_unfair_lock_lock(&g_flightLk); g_inflight->erase((__bridge void*)info); bool hl = info->hangLogged; os_unfair_lock_unlock(&g_flightLk);
      if (hl) Log("hang resolved: cb=%p seq=%llu completed after %.1f s, status=%ld", (__bridge void*)b, (unsigned long long)info->seq, lat, (long)b.status); }
    double m = g_maxLat.load(std::memory_order_relaxed); if (lat > m) g_maxLat.store(lat, std::memory_order_relaxed);
    if (b.status == MTLCommandBufferStatusError || b.error) OnError(b, info, lat);
    else {
      RecentCB r{info->seq, (__bridge void*)b.commandQueue, b.GPUStartTime, b.GPUEndTime, {info->enc[0], info->enc[1], info->enc[2], info->enc[3]}};
      os_unfair_lock_lock(&g_recentLk); g_recent[g_recentN++ % kRecent] = r; os_unfair_lock_unlock(&g_recentLk);
    }
    if (g_nswaps.load(std::memory_order_relaxed)) {
      os_unfair_lock_lock(&g_swapLk); id<MTLCommandQueue> w = g_watchQ; bool hit = w && b.commandQueue == w; if (hit) g_watchQ = nil; os_unfair_lock_unlock(&g_swapLk);
      if (hit) Log("QUEUE SWAP: replacement %p working, first command buffer completed %.2f s after the swap", (__bridge void*)w, Now() - g_swapT.load());
    }
  }];
  ((FnV)Orig(self, s))(self, s);
}
static MTLCommandBufferDescriptor* EncDesc(MTLCommandBufferDescriptor* d, BOOL retained) {
  MTLCommandBufferDescriptor* n = d ? [d copy] : [MTLCommandBufferDescriptor new];
  if (!d) n.retainedReferences = retained;
  n.errorOptions = n.errorOptions | MTLCommandBufferErrorOptionEncoderExecutionStatus;
  return n;
}
static id Hk_qCB(id self, SEL s) {
  id q = Live(self);
  if (!g_encinfo) return ((FnId)Orig(q, s))(q, s);
  SEL sd = @selector(commandBufferWithDescriptor:);
  return ((FnIdD)Orig(q, sd))(q, sd, EncDesc(nil, YES));
}
static id Hk_qCBUnret(id self, SEL s) {
  id q = Live(self);
  if (!g_encinfo) return ((FnId)Orig(q, s))(q, s);
  SEL sd = @selector(commandBufferWithDescriptor:);
  return ((FnIdD)Orig(q, sd))(q, sd, EncDesc(nil, NO));
}
static id Hk_qCBDesc(id self, SEL s, id d) { id q = Live(self); return ((FnIdD)Orig(q, s))(q, s, g_encinfo ? EncDesc(d, YES) : d); }

// ---------------------------------------------------------------- watchdog / stall / heartbeat
static void DumpEvents(const char* why) {
  std::string s;
  os_unfair_lock_lock(&g_evLk);
  std::vector<EvSeen> evs = *g_events;
  os_unfair_lock_unlock(&g_evLk);
  for (auto& e : evs) {
    char b[256];
    if (IsShared(e.ev)) snprintf(b, sizeof b, " %s=%llu/maxEncoded %llu", EvName(e.ev).c_str(), (unsigned long long)((id<MTLSharedEvent>)e.ev).signaledValue, (unsigned long long)e.maxSig);
    else snprintf(b, sizeof b, " %s(non-shared)/maxEncoded %llu", EvName(e.ev).c_str(), (unsigned long long)e.maxSig);
    if (s.size() < 2500) s += b;
  }
  Log("  events (%s):%s", why, s.empty() ? " none seen" : s.c_str());
}
static void Heartbeat(const char* why) {
  size_t inflight = 0; double oldest = 0, now = Now();
  os_unfair_lock_lock(&g_flightLk);
  if (g_inflight) { inflight = g_inflight->size(); for (auto& kv : *g_inflight) oldest = std::max(oldest, now - kv.second->tCommit); }
  os_unfair_lock_unlock(&g_flightLk);
  Log("%s: up %.0f s, committed %llu (with event ops %llu), completed %llu, errors %llu, recovered signals %llu, hangs %llu, in flight %zu (oldest %.0f ms), max commit->complete %.1f ms",
      why, now - g_t0, (unsigned long long)g_committed.load(), (unsigned long long)g_withSignals.load(), (unsigned long long)g_completed.load(),
      (unsigned long long)g_errors.load(), (unsigned long long)g_recovered.load(), (unsigned long long)g_hangs.load(), inflight, oldest * 1e3, g_maxLat.load() * 1e3);
  g_maxLat.store(0);
}
static std::atomic<double> g_mainLate{0};  // worst main-thread ping delay since the last mem line
static void MemLine() {
  task_vm_info_data_t vi; mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
  bool ok = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &c) == KERN_SUCCESS;
  uint64_t fp = ok ? vi.phys_footprint : 0, rss = ok ? vi.resident_size : 0;
  xsw_usage sw = {}; size_t n = sizeof sw; sysctlbyname("vm.swapusage", &sw, &n, nullptr, 0);
  int freePct = -1, level = -1; n = sizeof freePct; sysctlbyname("kern.memorystatus_level", &freePct, &n, nullptr, 0);
  n = sizeof level; sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &n, nullptr, 0);
  const double GB = 1024.0 * 1024 * 1024;
  static uint64_t lastC = 0; static double lastT = 0; uint64_t c2 = g_committed.load(); double t2 = Now();
  double cps = lastT > 0 ? (c2 - lastC) / (t2 - lastT) : 0; lastC = c2; lastT = t2;
  Log("mem: game %.1f GB (in RAM %.1f), gpu %.1f of %.1f GB, swap %.1f GB, free %d%%, pressure %d, thermal %ld, commits/s %.0f, main late %.0f ms", fp / GB, rss / GB,
      g_dev.currentAllocatedSize / GB, g_dev.recommendedMaxWorkingSetSize / GB, sw.xsu_used / GB, freePct, level, (long)NSProcessInfo.processInfo.thermalState, cps, g_mainLate.exchange(0) * 1e3);
}
// One line at start: how long the Mac has been up and what the GPU driver and kernel already hold, to see whether
// sessions get worse with uptime because something builds up between game runs.
static void SystemLine() {
  timeval boot = {}; size_t n = sizeof boot; sysctlbyname("kern.boottime", &boot, &n, nullptr, 0);
  vm_statistics64_data_t vs = {}; mach_msg_type_number_t c = HOST_VM_INFO64_COUNT;
  host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vs, &c);
  vm_size_t page = 0; host_page_size(mach_host_self(), &page);
  long long inUse = -1, alloc = -1, recoveries = -1;
  io_iterator_t it = 0;
  if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS) {
    for (io_object_t o; (o = IOIteratorNext(it));) {
      CFTypeRef st = IORegistryEntryCreateCFProperty(o, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
      if (st && CFGetTypeID(st) == CFDictionaryGetTypeID()) {
        NSDictionary* d = (__bridge NSDictionary*)st;
        if (d[@"In use system memory"]) inUse = [d[@"In use system memory"] longLongValue];
        if (d[@"Alloc system memory"]) alloc = [d[@"Alloc system memory"] longLongValue];
        if (d[@"recoveryCount"]) recoveries = [d[@"recoveryCount"] longLongValue];
      }
      if (st) CFRelease(st);
      IOObjectRelease(o);
    }
    IOObjectRelease(it);
  }
  const double GB = 1024.0 * 1024 * 1024;
  Log("system: up %.1f h, GPU driver in use %.2f GB (allocated %.2f GB), GPU recoveries since boot %lld, wired %.1f GB, compressed %.1f GB",
      (time(nullptr) - boot.tv_sec) / 3600.0, inUse / GB, alloc / GB, recoveries, (double)vs.wire_count * page / GB,
      (double)vs.compressor_page_count * page / GB);
}

// ---------------------------------------------------------------- freeze capture
// `sample` cannot attach to this hardened game, so read our own threads. Each is suspended only while its registers and
// frame chain are copied: a suspended thread may hold the malloc or dyld lock, so all logging and dladdr come after.
static const int kMaxThreads = 256, kMaxFrames = 18, kMaxCaptures = 24;
struct ThreadSnap { char name[64]; int cpuPermille, runState, frames; uint64_t pc[kMaxFrames]; };
static std::atomic<double> g_mainPong{0};
static std::string Symbol(uint64_t a) {
  Dl_info di; char b[96];
  if (dladdr((const void*)a, &di) && di.dli_fname) {
    const char* base = strrchr(di.dli_fname, '/'); base = base ? base + 1 : di.dli_fname;
    snprintf(b, sizeof b, "%s+0x%llx", base, (unsigned long long)(a - (uint64_t)di.dli_fbase));
  } else snprintf(b, sizeof b, "0x%llx", (unsigned long long)a);
  return b;
}
static void CaptureThreads(const char* why) {
  static ThreadSnap snaps[kMaxThreads];  // only the serial tick queue gets here
  static int captures = 0;
  if (captures >= kMaxCaptures) return;
  captures++;
  thread_act_array_t th; mach_msg_type_number_t n = 0;
  if (task_threads(mach_task_self(), &th, &n) != KERN_SUCCESS) return;
  thread_act_t self = mach_thread_self();
  int count = 0;
  for (mach_msg_type_number_t i = 0; i < n; i++) {
    if (th[i] != self && count < kMaxThreads) {
      ThreadSnap& t = snaps[count]; memset(&t, 0, sizeof t);
      thread_extended_info_data_t xi; mach_msg_type_number_t xc = THREAD_EXTENDED_INFO_COUNT;
      if (thread_info(th[i], THREAD_EXTENDED_INFO, (thread_info_t)&xi, &xc) == KERN_SUCCESS) {
        snprintf(t.name, sizeof t.name, "%s", xi.pth_name); t.cpuPermille = xi.pth_cpu_usage; t.runState = xi.pth_run_state;
      }
      if (thread_suspend(th[i]) == KERN_SUCCESS) {
        arm_thread_state64_t st; mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(th[i], ARM_THREAD_STATE64, (thread_state_t)&st, &sc) == KERN_SUCCESS) {
          const uint64_t kAddr = 0x7fffffffffULL;  // drops pointer-authentication bits
          t.pc[t.frames++] = arm_thread_state64_get_pc(st) & kAddr;
          uint64_t lr = arm_thread_state64_get_lr(st) & kAddr, fp = arm_thread_state64_get_fp(st);
          if (lr) t.pc[t.frames++] = lr;
          while (t.frames < kMaxFrames && fp && !(fp & 7)) {
            uint64_t rec[2]; vm_size_t got = 0;
            if (vm_read_overwrite(mach_task_self(), fp, sizeof rec, (vm_address_t)rec, &got) != KERN_SUCCESS) break;
            if (!rec[1]) break;
            t.pc[t.frames++] = rec[1] & kAddr;
            if (rec[0] <= fp) break;
            fp = rec[0];
          }
        }
        thread_resume(th[i]);
      }
      count++;
    }
    mach_port_deallocate(mach_task_self(), th[i]);
  }
  mach_port_deallocate(mach_task_self(), self);
  vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof(thread_act_t));
  Log("CAPTURE %d (%s): %d threads", captures, why, count);
  for (int i = 0; i < count; i++) {
    const ThreadSnap& t = snaps[i];
    std::string s;
    for (int f = 0; f < t.frames; f++) { s += ' '; s += Symbol(t.pc[f]); }
    Log("  [%s] cpu %.1f%% state %d:%s", t.name[0] ? t.name : "?", t.cpuPermille / 10.0, t.runState, s.c_str());
  }
}
// Rates: 640/s in menus, 3000/s in play, about 10/s in the slow spell of 10-30. Three samples per freeze, 2 s apart.
static void FreezeWatch(double now) {
  static uint64_t last = 0; static double lastPlaying = 0, nextAllowed = 0, nextSample = 0; static int slow = 0, left = 0;
  uint64_t c = g_committed.load(), rate = c - last; last = c;
  if (rate >= 500) lastPlaying = now;
  bool front = NSRunningApplication.currentApplication.active;
  slow = (front && rate < 120 && lastPlaying > 0 && now - lastPlaying < 60) ? slow + 1 : 0;
  double pong = g_mainPong.load();
  bool mainLate = front && pong > 0 && lastPlaying > 0 && now - pong > 3;
  double posted = Now();
  dispatch_async(dispatch_get_main_queue(), ^{
    double t = Now(), late = t - posted;
    if (g_mainPong.exchange(t) == 0) Log("main thread answers pings");
    if (late > g_mainLate.load()) g_mainLate.store(late);
  });
  struct stat st;
  bool asked = g_capturePath[0] && stat(g_capturePath, &st) == 0;
  if (asked) unlink(g_capturePath);
  if (left == 0 && (asked || (now >= nextAllowed && g_errors.load() == 0 && (slow >= 3 || mainLate)))) {  // never suspend threads during a GPU failure
    Log("FREEZE? %s: %llu commits/s, main thread silent %.1f s", asked ? "asked for" : slow >= 3 ? "frames collapsed" : "main thread late",
        (unsigned long long)rate, pong > 0 ? now - pong : 0.0);
    MemLine();
    left = 3; nextSample = now; nextAllowed = now + 120;
  }
  if (left > 0 && now >= nextSample) { left--; nextSample = now + 2; CaptureThreads(asked ? "asked" : "auto"); }
}
static void Tick() {
  double now = Now();
  static double lastMem = 0;
  FreezeWatch(now);
  if (g_memS > 0 && now - lastMem >= g_memS) { lastMem = now; MemLine(); }
  if (g_hangS > 0) {
    std::vector<GGInfo*> hung;  // ARC: __strong elements, so each info stays alive while we log it
    os_unfair_lock_lock(&g_flightLk);
    for (auto& kv : *g_inflight) if (GGInfo* i = kv.second; !i->hangLogged && now - i->tCommit > g_hangS) { i->hangLogged = true; hung.push_back(i); }
    os_unfair_lock_unlock(&g_flightLk);
    for (GGInfo* i : hung) {  // ops are not mutated after commit
      g_hangs++;
      Log("HANG? cb=%p seq=%llu committed %.1f s ago and not completed (log only, nothing is signaled):%s",
          i->cb, (unsigned long long)i->seq, now - i->tCommit, OpsStr(i, true).c_str());
    }
    if (!hung.empty()) DumpEvents("at hang");
  }
  static bool stalled = false;
  double lc = g_lastCommit.load(std::memory_order_relaxed);
  if (g_stallS > 0 && lc > 0) {
    if (!stalled && now - lc > g_stallS) {
      stalled = true;
      size_t inflight; os_unfair_lock_lock(&g_flightLk); inflight = g_inflight ? g_inflight->size() : 0; os_unfair_lock_unlock(&g_flightLk);
      Log("STALL: no command buffer committed for %.1f s (in flight %zu). Normal if the game is paused/backgrounded; "
          "during a freeze this marks a CPU-side wait.", now - lc, inflight);
      DumpEvents("at stall");
    } else if (stalled && now - lc < 1) { stalled = false; Log("stall ended: commits resumed"); }
  }
  static double lastHb = now;
  if (g_heartbeatS > 0 && now - lastHb >= g_heartbeatS) { lastHb = now; Heartbeat("heartbeat"); }
}

// ---------------------------------------------------------------- install
static void OpenLog() {
  std::string path;
  if (const char* p = getenv("GPUGUARD_LOG")) path = p;
  else {
    char exe[4096]; uint32_t sz = sizeof exe;
    if (_NSGetExecutablePath(exe, &sz) == 0) {
      std::string e = exe; size_t k = e.find(".app/Contents/MacOS/");
      if (k != std::string::npos) { size_t sl = e.rfind('/', k); if (sl != std::string::npos) path = e.substr(0, sl) + "/gpuguard.log"; }
    }
    if (path.empty()) { char cwd[4096]; if (getcwd(cwd, sizeof cwd)) path = std::string(cwd) + "/gpuguard.log"; }
  }
  struct stat st;
  if (!path.empty() && stat(path.c_str(), &st) == 0 && st.st_size > 8 * 1024 * 1024) rename(path.c_str(), (path + ".1").c_str());
  if (!path.empty()) g_log = fopen(path.c_str(), "a");
  if (!path.empty()) snprintf(g_capturePath, sizeof g_capturePath, "%s.capture", path.c_str());
  Log("loaded (log %s): recover=%d qswap=%d encinfo=%d hang=%.0fs stall=%.0fs heartbeat=%.0fs", g_log ? path.c_str() : "(stderr only)",
      g_recover, g_qswap, g_encinfo, g_hangS, g_stallS, g_heartbeatS);
}

static void Install() {
  @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { Log("no Metal device, inactive"); return; }
    g_dev = dev;
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandQueue> q2 = [dev newCommandQueueWithMaxCommandBufferCount:4];
    Class qc = object_getClass(q), qc2 = object_getClass(q2);
    Class cbc = object_getClass([q commandBuffer]);
    MTLCommandBufferDescriptor* d = [MTLCommandBufferDescriptor new];
    Class cbc2 = object_getClass([q commandBufferWithDescriptor:d]);
    d.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus;
    Class cbc3 = object_getClass([q commandBufferWithDescriptor:d]);
    Class cbc4 = object_getClass([q commandBufferWithUnretainedReferences]);
    Log("device %s queue %s/%s cmdbuf %s/%s/%s/%s", dev.name.UTF8String, class_getName(qc), class_getName(qc2),
        class_getName(cbc), class_getName(cbc2), class_getName(cbc3), class_getName(cbc4));
    InstallMipGuard(dev, q);  // before the command buffer hooks: its probe blit encoder is not counted
    Class cbs[4] = {cbc, cbc2, cbc3, cbc4};
    for (Class c : cbs) {
      Hook(c, @selector(encodeSignalEvent:value:), (IMP)Hk_signal);
      Hook(c, @selector(encodeWaitForEvent:value:), (IMP)Hk_wait);
      Hook(c, @selector(commit), (IMP)Hk_commit);
      Hook(c, @selector(renderCommandEncoderWithDescriptor:), (IMP)Hk_encD<kRender>);
      Hook(c, @selector(parallelRenderCommandEncoderWithDescriptor:), (IMP)Hk_encD<kRender>);
      Hook(c, @selector(computeCommandEncoder), (IMP)Hk_enc<kCompute>);
      Hook(c, @selector(computeCommandEncoderWithDispatchType:), (IMP)Hk_encU);
      Hook(c, @selector(computeCommandEncoderWithDescriptor:), (IMP)Hk_encD<kCompute>);
      Hook(c, @selector(blitCommandEncoder), (IMP)Hk_enc<kBlit>);
      Hook(c, @selector(blitCommandEncoderWithDescriptor:), (IMP)Hk_encD<kBlit>);
      Hook(c, @selector(accelerationStructureCommandEncoder), (IMP)Hk_enc<kAccel>);
      Hook(c, @selector(accelerationStructureCommandEncoderWithDescriptor:), (IMP)Hk_encD<kAccel>);
    }
    if (g_encinfo || g_qswap) {
      Class qcs[2] = {qc, qc2};
      for (Class c : qcs) {
        Hook(c, @selector(commandBuffer), (IMP)Hk_qCB);
        Hook(c, @selector(commandBufferWithUnretainedReferences), (IMP)Hk_qCBUnret);
        Hook(c, @selector(commandBufferWithDescriptor:), (IMP)Hk_qCBDesc);
      }
    }
    Log("installed %d hooks", g_nhooks.load());
    SystemLine();
  }
  dispatch_queue_t tq = dispatch_queue_create("gpuguard.tick", DISPATCH_QUEUE_SERIAL);
  dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, tq);
  dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
  dispatch_source_set_event_handler(t, ^{ @autoreleasepool { Tick(); } });
  dispatch_resume(t);
  static dispatch_source_t keep; keep = t; (void)keep;
  atexit([] { Heartbeat("exit summary"); });
}

__attribute__((constructor)) static void Init() {
  const char* prog = getprogname();
  const char* want = getenv("GPUGUARD_PROCESS"); if (!want) want = "Cyberpunk2077";
  if (!prog || strcmp(prog, want) != 0) return;
  // Children (the game runs `sh -c system_profiler ...`) must not inherit it: dyld aborts arm64e system binaries whose
  // inserted dylib is plain arm64. All inserted libraries are already loaded at this point.
  unsetenv("DYLD_INSERT_LIBRARIES");
  if (const char* v = getenv("GPUGUARD_RECOVER")) g_recover = atoi(v);
  if (const char* v = getenv("GPUGUARD_ENCINFO")) g_encinfo = atoi(v);
  if (const char* v = getenv("GPUGUARD_QSWAP")) g_qswap = atoi(v);
  if (const char* v = getenv("GPUGUARD_HANG_S")) g_hangS = atof(v);
  if (const char* v = getenv("GPUGUARD_STALL_S")) g_stallS = atof(v);
  if (const char* v = getenv("GPUGUARD_HEARTBEAT_S")) g_heartbeatS = atof(v);
  if (const char* v = getenv("GPUGUARD_MEM_S")) g_memS = atof(v);
  g_t0 = Now();
  g_inflight = new std::unordered_map<void*, GGInfo*>();
  g_events = new std::vector<EvSeen>();
  g_swaps = new std::vector<SwapEnt>();
  OpenLog();
  Install();
}
