// Test harness for gpuguard.dylib (no game). Run with
//   DYLD_INSERT_LIBRARIES=./gpuguard.dylib GPUGUARD_PROCESS=gg_harness GPUGUARD_LOG=<file> ./gg_harness <mode>
// Modes:
//   lower            CPU-side MTLSharedEvent semantics: can setSignaledValue: lower the value?
//   fault [uaf|addr] a command buffer that fails on the GPU and carries encodeSignalEvent:E=2. Default "uaf": an
//                    unretained-references CB whose buffer is freed before commit -> MTLCommandBufferErrorInvalidResource.
//                    (A bogus device address, absolute or "+off" past a buffer, does not fault on M5/macOS 26.) Plus a second
//                    queue's command buffer that waits on E=2. A CPU thread spins on E.signaledValue like the game's
//                    fence wait, but bounded (6 s). Then checks whether the device and queue still work.
//   faultne          same with a non-shared MTLEvent (cannot be signaled from the CPU; gpuguard signals it from the GPU)
//   block            Gets one queue blocked (several CBs waiting on an event nobody signals -> GPU Timeout), then checks the
//                    same queue object, a queue that already existed, and a brand-new queue, with several real CBs each.
//   chain            Two queues handing frames to each other with several frames in flight, like the engine and FSR. One
//                    command buffer hangs. Reports how long frames stop for and how many queues were replaced.
//   bench N          overhead microbenchmark: N frames of 54 command buffers on 3 queues, each waiting on the previous
//                    one's shared-event value, 3 tiny compute encoders, one signal; CPU spins on frame N-2 like the game.
// Every wait is bounded; the whole process self-terminates after 90 s (alarm).
#import <Metal/Metal.h>
#include <sys/resource.h>
#include <mach/mach_time.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <unistd.h>

static const char* kSrc = R"(
#include <metal_stdlib>
using namespace metal;
kernel void ok(device uint* out [[buffer(0)]], constant uint& salt [[buffer(1)]], uint i [[thread_position_in_grid]]) { out[i] = i * 3 + salt; }
struct Args { device uint* p; };
kernel void bad(constant Args& a [[buffer(0)]], device uint* out [[buffer(1)]], uint i [[thread_position_in_grid]]) {
  out[i] = a.p[i * 1024] + 1; }
kernel void badw(constant Args& a [[buffer(0)]], device uint* out [[buffer(1)]], uint i [[thread_position_in_grid]]) {
  a.p[i * 1024] = i; out[i] = 0; }
)";
static double Now() { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
  return (double)mach_absolute_time() * tb.numer / tb.denom * 1e-9; }
static double CpuS() { struct rusage r; getrusage(RUSAGE_SELF, &r);
  return r.ru_utime.tv_sec + r.ru_utime.tv_usec * 1e-6 + r.ru_stime.tv_sec + r.ru_stime.tv_usec * 1e-6; }

static id<MTLDevice> dev; static id<MTLComputePipelineState> psOk, psBad, psBadW;

static void EncOk(id<MTLCommandBuffer> cb, id<MTLBuffer> out, uint32_t salt, int n = 64) {
  id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
  [e setComputePipelineState:psOk]; [e setBuffer:out offset:0 atIndex:0]; [e setBytes:&salt length:4 atIndex:1];
  [e dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)]; [e endEncoding];
}
static bool CheckOk(id<MTLBuffer> out, uint32_t salt, int n = 64) {
  const uint32_t* p = (const uint32_t*)out.contents; for (int i = 0; i < n; i++) if (p[i] != (uint32_t)i * 3 + salt) return false; return true;
}
// poll a command buffer's status with a timeout (never blocks unbounded)
static long WaitCB(id<MTLCommandBuffer> cb, double timeout) {
  double t0 = Now();
  while (cb.status != MTLCommandBufferStatusCompleted && cb.status != MTLCommandBufferStatusError) { if (Now() - t0 > timeout) return -1; usleep(1000); }
  return (long)cb.status;
}
static const char* St(long s) { return s == -1 ? "TIMEOUT(still running)" : s == MTLCommandBufferStatusCompleted ? "Completed" : s == MTLCommandBufferStatusError ? "Error" : "?"; }
static void PrintErr(const char* what, id<MTLCommandBuffer> cb) {
  NSError* e = cb.error;
  printf("  %s: status=%s", what, St((long)cb.status));
  if (e) printf(" error %s code=%ld '%s'", e.domain.UTF8String, (long)e.code, e.localizedDescription.UTF8String);
  printf("\n");
}
// spin like the game's fence wait (bounded): returns seconds until value reached, or -1
static double Spin(id<MTLSharedEvent> ev, uint64_t v, double timeout) {
  double t0 = Now(); while (ev.signaledValue < v) { if (Now() - t0 > timeout) return -1; } return Now() - t0;
}

static int Lower() {
  id<MTLSharedEvent> e = [dev newSharedEvent];
  e.signaledValue = 10; uint64_t a = e.signaledValue;
  e.signaledValue = 5; uint64_t b = e.signaledValue;
  e.signaledValue = 12; uint64_t c = e.signaledValue;
  printf("lower: set 10 -> reads %llu; set 5 -> reads %llu; set 12 -> reads %llu  => CPU writes %s lower the value\n",
         a, b, c, b == 5 ? "CAN" : "can NOT");
  // GPU signal of a lower value
  id<MTLCommandQueue> q = [dev newCommandQueue];
  id<MTLCommandBuffer> cb = [q commandBuffer]; [cb encodeSignalEvent:e value:7]; [cb commit];
  long s = WaitCB(cb, 5);
  printf("lower: GPU signal 7 while at 12 -> cb %s, reads %llu => GPU signals %s lower the value\n", St(s), e.signaledValue, e.signaledValue == 7 ? "CAN" : "can NOT");
  return 0;
}

// nonShared: E is a plain MTLEvent (GPU-only). The CPU waiter then watches G, which only the dependent cb signals.
static bool g_nonShared = false;
static int Fault(const char* spec, bool write) {
  id<MTLSharedEvent> E = [dev newSharedEvent]; E.label = @"E-frame"; E.signaledValue = 0;
  id<MTLEvent> En = g_nonShared ? [dev newEvent] : E; if (g_nonShared) En.label = @"E-nonshared";
  id<MTLSharedEvent> G = [dev newSharedEvent]; G.label = @"G-downstream"; G.signaledValue = 0;
  id<MTLCommandQueue> Q = [dev newCommandQueue]; Q.label = @"Q-main";
  id<MTLCommandQueue> Q2 = [dev newCommandQueue]; Q2.label = @"Q-second";
  id<MTLBuffer> out = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
  id<MTLBuffer> outD = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
  // spec: absolute address, or "+off" = relative to the gpuAddress of `out` (far past its end)
  uint64_t addr = !strcmp(spec, "uaf") ? 0 : spec[0] == '+' ? out.gpuAddress + strtoull(spec + 1, nullptr, 0) : strtoull(spec, nullptr, 0);
  const char* rec = getenv("GPUGUARD_RECOVER");
  printf("== fault test, kind=%s %s addr=0x%llx, GPUGUARD_RECOVER=%s ENCINFO=%s\n", spec, write ? "write" : "read", addr, rec ? rec : "(unset = 1)", getenv("GPUGUARD_ENCINFO") ?: "-");

  // 1. healthy frame
  id<MTLCommandBuffer> a = [Q commandBuffer]; a.label = @"healthy"; EncOk(a, out, 1); [a encodeSignalEvent:E value:1]; [a commit];
  double w1 = Spin(E, 1, 5);
  printf("1 healthy cb: %s, waiter reached E>=1 after %.3f ms, output %s\n", St(WaitCB(a, 5)), w1 * 1e3, CheckOk(out, 1) ? "correct" : "WRONG");

  // 2. faulting cb carrying signal E=2, and a dependent cb on another queue (waits E=2, signals G=1)
  id<MTLCommandBuffer> f;
  if (!strcmp(spec, "uaf")) {
    // InvalidResource: an unretained-references command buffer whose buffer is freed before commit. The kernel rejects
    // it at submission (the GPU never touches the freed memory); only this process is affected.
    // Nothing may be allocated between the free and the commit: a new allocation can recycle the freed resource slot and
    // the command buffer then runs normally. So: valid encoder first, freeing encoder last, then signal + commit at once.
    f = [Q commandBufferWithUnretainedReferences];
    EncOk(f, out, 2);
    id<MTLComputeCommandEncoder> e = [f computeCommandEncoder];
    @autoreleasepool { id<MTLBuffer> tmp = [dev newBufferWithLength:1 << 24 options:MTLResourceStorageModePrivate];  // 16 MB: own allocation, not sub-allocated
      [e setComputePipelineState:psOk]; uint32_t salt = 3; [e setBuffer:tmp offset:0 atIndex:0]; [e setBytes:&salt length:4 atIndex:1];
      [e dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)]; [e endEncoding]; tmp = nil; }
  } else {
    // bogus device address (does NOT fault on M5 / macOS 26: reads return 0, writes are dropped; kept for reference)
    f = [Q commandBuffer];
    id<MTLComputeCommandEncoder> e = [f computeCommandEncoder]; [e setComputePipelineState:write ? psBadW : psBad];
    [e setBytes:&addr length:8 atIndex:0]; [e setBuffer:out offset:0 atIndex:1];
    [e dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)]; [e endEncoding];
    EncOk(f, out, 2);  // a second, valid encoder after the faulting one
  }
  f.label = @"faulting";
  [f encodeSignalEvent:En value:2];
  double tc = Now();
  [f commit];
  id<MTLCommandBuffer> d = [Q2 commandBuffer]; d.label = @"dependent"; [d encodeWaitForEvent:En value:2]; EncOk(d, outD, 5); [d encodeSignalEvent:G value:1];
  [d commit];
  std::atomic<double> spun{-2};
  std::thread waiter([&] { spun = g_nonShared ? Spin(G, 1, 6) : Spin(E, 2, 6); });  // the game's `while(!wait(fence,-1));`, bounded
  long fs = WaitCB(f, 10);
  printf("2 faulting cb (errorOptions=%lu, retainedReferences=%d) finished after %.1f ms: ", (unsigned long)f.errorOptions, (int)f.retainedReferences, (Now() - tc) * 1e3); PrintErr("faulting", f);
  if (f.error) for (NSString* k in f.error.userInfo) printf("     userInfo key %s\n", k.UTF8String);
  waiter.join();
  double sp = spun.load();
  if (g_nonShared) printf("  (non-shared E: the CPU waiter watches G>=1, signaled by the dependent cb after its GPU wait on E=2)\n");
  const char* wn = g_nonShared ? "G>=1" : "E>=2";
  if (sp < 0) printf("  CPU waiter on %s: STUCK (gave up after 6 s bounded timeout; the game would spin forever). E=%llu\n", wn, E.signaledValue);
  else printf("  CPU waiter on %s: proceeded after %.1f ms. E=%llu\n", wn, sp * 1e3, E.signaledValue);
  double gs = Spin(G, 1, 3);
  printf("  dependent cb (Q-second, waits E=2): %s; G>=1 %s\n", St(WaitCB(d, 0.01)), gs < 0 ? "NOT reached in 3 s" : "reached");
  (void)fs;

  // 3. device / queue state after the fault
  id<MTLSharedEvent> H = [dev newSharedEvent]; H.label = @"H-after";
  id<MTLBuffer> o3 = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
  id<MTLCommandBuffer> c3 = [Q commandBuffer]; c3.label = @"after-same-queue"; EncOk(c3, o3, 7); [c3 encodeSignalEvent:H value:1]; [c3 commit];
  long s3 = WaitCB(c3, 5);
  printf("3 same queue after fault: "); PrintErr("after-same-queue", c3); printf("     output %s, H=%llu\n", CheckOk(o3, 7) ? "correct" : "WRONG", H.signaledValue);
  id<MTLCommandQueue> Q3 = [dev newCommandQueue];
  id<MTLBuffer> o4 = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
  id<MTLCommandBuffer> c4 = [Q3 commandBuffer]; c4.label = @"after-new-queue"; EncOk(c4, o4, 9); [c4 commit];
  WaitCB(c4, 5); printf("  new queue after fault: "); PrintErr("after-new-queue", c4); printf("     output %s\n", CheckOk(o4, 9) ? "correct" : "WRONG");
  NSError* err = nil; id<MTLLibrary> lib2 = [dev newLibraryWithSource:@(kSrc) options:nil error:&err];
  id<MTLComputePipelineState> ps2 = lib2 ? [dev newComputePipelineStateWithFunction:[lib2 newFunctionWithName:@"ok"] error:&err] : nil;
  printf("  new library + pipeline after fault: %s\n", ps2 ? "ok" : err.localizedDescription.UTF8String);
  (void)s3;

  // 4. cleanup: release anything still waiting on E so nothing is left blocked on the GPU
  if (g_nonShared) { if (d.status != MTLCommandBufferStatusCompleted && d.status != MTLCommandBufferStatusError) {
      printf("4 cleanup: harness signals non-shared E=2 from a GPU command buffer to release the dependent cb\n");
      id<MTLCommandBuffer> r = [Q commandBuffer]; [r encodeSignalEvent:En value:2]; [r commit]; } }
  else if (E.signaledValue < 2) { printf("4 cleanup: harness sets E=2 from the CPU to release the dependent cb\n"); E.signaledValue = 2; }
  long sd = WaitCB(d, 5);
  printf("  dependent cb final: %s, output %s, G=%llu\n", St(sd), CheckOk(outD, 5) ? "correct" : "WRONG", G.signaledValue);
  sleep(1);  // let gpuguard's completion handlers / watchdog lines flush
  return 0;
}

// probe: run only the bad kernel (read or write) at `spec`, report status and what the read returned
static int Probe(const char* spec, bool write) {
  id<MTLCommandQueue> Q = [dev newCommandQueue];
  id<MTLBuffer> out = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
  id<MTLBuffer> tgt = [dev newBufferWithLength:1 << 20 options:MTLResourceStorageModeShared];
  memset(out.contents, 0xAB, 4096); memset(tgt.contents, 0x11, 1 << 20);
  uint64_t addr = !strcmp(spec, "tgt") ? tgt.gpuAddress : spec[0] == '+' ? out.gpuAddress + strtoull(spec + 1, nullptr, 0) : strtoull(spec, nullptr, 0);
  id<MTLCommandBuffer> f = [Q commandBuffer];
  id<MTLComputeCommandEncoder> e = [f computeCommandEncoder]; [e setComputePipelineState:write ? psBadW : psBad];
  [e setBytes:&addr length:8 atIndex:0]; [e setBuffer:out offset:0 atIndex:1];
  if (!strcmp(spec, "tgt")) [e useResource:tgt usage:MTLResourceUsageRead | MTLResourceUsageWrite];
  [e dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)]; [e endEncoding];
  [f commit]; long s = WaitCB(f, 5);
  const uint32_t* o = (const uint32_t*)out.contents; const uint32_t* t = (const uint32_t*)tgt.contents;
  printf("probe %s %s addr=0x%llx: %s err=%ld  out[0..1]=%08x %08x  tgt[0]=%08x tgt[1024]=%08x\n", write ? "write" : "read", spec, addr, St(s),
         f.error ? (long)f.error.code : 0L, o[0], o[1], t[0], t[1024]);
  return 0;
}

// block: does macOS block the queue, or the whole process? Every wait is bounded.
static int TryQ(const char* what, id<MTLCommandQueue> q, id<MTLBuffer> out, uint32_t salt) {
  int good = 0;
  for (int i = 0; i < 3; i++) {
    id<MTLCommandBuffer> cb = [q commandBuffer]; EncOk(cb, out, salt + i); [cb commit];
    long s = WaitCB(cb, 8);
    bool ok = s == MTLCommandBufferStatusCompleted && CheckOk(out, salt + i); good += ok;
    printf("  %s #%d: %s, output %s", what, i, St(s), ok ? "correct" : "WRONG");
    if (cb.error) printf(" (code %ld '%s')", (long)cb.error.code, cb.error.localizedDescription.UTF8String);
    printf("\n");
  }
  return good;
}
static int Block() {
  id<MTLCommandQueue> Q = [dev newCommandQueue]; Q.label = @"Q-blocked";
  id<MTLCommandQueue> Other = [dev newCommandQueue]; Other.label = @"Q-other";
  id<MTLSharedEvent> E = [dev newSharedEvent]; E.signaledValue = 0;
  id<MTLBuffer> out = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
  printf("== block test\n");
  // like the engine: another thread keeps asking the same queue object for command buffers while it gets blocked
  std::atomic<bool> stop{false}; std::atomic<int> bgOk{0}, bgErr{0};
  id<MTLBuffer> outBg = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
  std::thread bg([&] { while (!stop) { @autoreleasepool {
    id<MTLCommandBuffer> cb = [Q commandBuffer]; EncOk(cb, outBg, 7); [cb commit]; long s = WaitCB(cb, 8);
    (s == MTLCommandBufferStatusCompleted ? bgOk : bgErr)++; } } });
  bool blocked = false;
  for (int round = 1; round <= 4 && !blocked; round++) {
    id<MTLCommandBuffer> w[3];
    for (int i = 0; i < 3; i++) { w[i] = [Q commandBuffer]; [w[i] encodeWaitForEvent:E value:1000]; EncOk(w[i], out, 1); [w[i] commit]; }
    for (int i = 0; i < 3; i++) { WaitCB(w[i], 8); }
    PrintErr("waiting cb", w[0]);
    id<MTLCommandBuffer> p = [Q commandBuffer]; EncOk(p, out, 2); [p commit]; long s = WaitCB(p, 8);
    printf("round %d: next cb on the same queue: %s", round, St(s));
    if (p.error) printf(" (code %ld '%s')", (long)p.error.code, p.error.localizedDescription.UTF8String);
    printf("\n");
    blocked = p.error != nil;
    if (!blocked) E.signaledValue = 0;
  }
  printf("queue blocked: %s\n", blocked ? "yes" : "NO");
  int same = TryQ("same queue object", Q, out, 10);
  int other = TryQ("queue created earlier", Other, out, 20);
  id<MTLCommandQueue> N = [dev newCommandQueue]; N.label = @"Q-new";
  int fresh = TryQ("brand-new queue", N, out, 30);
  int before = bgOk.load(); usleep(300000); int after = bgOk.load();
  stop = true; bg.join();
  printf("background thread on the same queue object: %d ok, %d errors, %d ok in the last 0.3 s\n", bgOk.load(), bgErr.load(), after - before);
  printf("RESULT blocked=%d same=%d/3 other=%d/3 new=%d/3\n", (int)blocked, same, other, fresh);
  return 0;
}

static int Chain() {
  id<MTLCommandQueue> A = [dev newCommandQueueWithMaxCommandBufferCount:512]; A.label = @"Q-A";
  id<MTLCommandQueue> B = [dev newCommandQueueWithMaxCommandBufferCount:512]; B.label = @"Q-B";
  id<MTLSharedEvent> E = [dev newSharedEvent], F = [dev newSharedEvent], X = [dev newSharedEvent];
  E.label = @"E-B-done"; F.label = @"F-A-done"; X.label = @"X-never";
  id<MTLBuffer> out = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
  const int kFrames = 1500, kInFlight = 6, kHangAt = 100; const double kLimit = 45;
  double t0 = Now(), last = t0, worst = 0, tHang = 0, tFirstAfter = 0; int resumed = 0, hangFrames = 0;
  int n = 1;
  for (; n <= kFrames && Now() - t0 < kLimit; n++) {
    if (n == kHangAt) {  // lands on A with kInFlight frames behind it
      id<MTLCommandBuffer> h = [A commandBuffer]; h.label = @"hang"; [h encodeWaitForEvent:X value:1]; [h encodeSignalEvent:F value:(uint64_t)n - 1]; [h commit];
      tHang = Now();
    }
    id<MTLCommandBuffer> a = [A commandBuffer]; [a encodeWaitForEvent:E value:(uint64_t)n - 1]; EncOk(a, out, 1); [a encodeSignalEvent:F value:n]; [a commit];
    id<MTLCommandBuffer> b = [B commandBuffer]; [b encodeWaitForEvent:F value:n]; EncOk(b, out, 1); [b encodeSignalEvent:E value:n]; [b commit];
    if (n > kInFlight) {
      double t1 = Now();
      if (Spin(E, (uint64_t)n - kInFlight, 12) < 0) printf("  frame %d: stuck for 12 s, E=%llu\n", n, E.signaledValue);
      double now = Now(), gap = now - last; last = now; if (gap > worst) worst = gap; (void)t1;
      if (tHang > 0 && gap < 0.05) { if (++resumed == 60 && !tFirstAfter) tFirstAfter = now; } else if (tHang > 0) { resumed = 0; hangFrames++; }
    }
    usleep(4000);
  }
  printf("RESULT frames=%d of %d, worst single stop %.1f s, smooth again %.1f s after the hang, slow frames %d\n", n - 1, kFrames, worst, tFirstAfter ? tFirstAfter - tHang : -1.0, hangFrames);
  return 0;
}

static int Bench(int N) {
  const int K = 54, QN = 3;
  id<MTLCommandQueue> q[QN]; id<MTLSharedEvent> ev[QN]; uint64_t val[QN] = {0};
  for (int i = 0; i < QN; i++) { q[i] = [dev newCommandQueueWithMaxCommandBufferCount:256]; ev[i] = [dev newSharedEvent]; }
  id<MTLSharedEvent> frameEv = [dev newSharedEvent];
  id<MTLBuffer> out = [dev newBufferWithLength:1 << 16 options:MTLResourceStorageModePrivate];
  double t0 = Now(), c0 = CpuS(), worst = 0, subm = 0;
  for (int fr = 1; fr <= N; fr++) {
    double tf = Now();
    @autoreleasepool {
      double ts = Now();
      for (int k = 0; k < K; k++) {
        int qi = k % QN, prev = (k + QN - 1) % QN;
        id<MTLCommandBuffer> cb = (k % 2) ? [q[qi] commandBuffer] : [q[qi] commandBufferWithDescriptor:[MTLCommandBufferDescriptor new]];
        if (k > 0) [cb encodeWaitForEvent:ev[prev] value:val[prev]];
        for (int e = 0; e < 3; e++) EncOk(cb, out, e, 64);
        [cb encodeSignalEvent:ev[qi] value:++val[qi]];
        if (k == K - 1) [cb encodeSignalEvent:frameEv value:fr];
        [cb commit];
      }
      subm += Now() - ts;
    }
    // blocking wait (no CPU burn) so process CPU time = encode/commit + Metal/gpuguard completion threads
    if (fr > 2 && ![frameEv waitUntilSignaledValue:fr - 2 timeoutMS:10000]) { printf("bench: frame wait timed out\n"); return 1; }
    worst = std::max(worst, Now() - tf);
  }
  if (![frameEv waitUntilSignaledValue:N timeoutMS:10000]) { printf("bench: final wait timed out\n"); return 1; }
  double wall = Now() - t0, cpu = CpuS() - c0;
  printf("bench frames=%d cbs=%d per-frame %.3f ms  submit %.2f us/cb  process cpu %.2f us/cb  worst frame %.2f ms  encinfo=%s guard=%s\n",
         N, N * K, wall / N * 1e3, subm / (N * K) * 1e6, cpu / (N * K) * 1e6, worst * 1e3, getenv("GPUGUARD_ENCINFO") ?: "-",
         getenv("GPUGUARD_PROCESS") ? "on" : "off");
  return 0;
}

int main(int argc, char** argv) { @autoreleasepool {
  alarm(90);
  dev = MTLCreateSystemDefaultDevice();
  NSError* e = nil;
  MTLCompileOptions* co = [MTLCompileOptions new]; co.languageVersion = MTLLanguageVersion3_1;
  id<MTLLibrary> lib = [dev newLibraryWithSource:@(kSrc) options:co error:&e];
  if (!lib) { printf("lib: %s\n", e.localizedDescription.UTF8String); return 1; }
  psOk = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"ok"] error:&e];
  psBad = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bad"] error:&e];
  psBadW = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"badw"] error:&e];
  if (!psOk || !psBad || !psBadW) { printf("pso: %s\n", e.localizedDescription.UTF8String); return 1; }
  const char* mode = argc > 1 ? argv[1] : "fault";
  if (!strcmp(mode, "lower")) return Lower();
  if (!strcmp(mode, "faultne")) { g_nonShared = true; return Fault("uaf", false); }
  if (!strcmp(mode, "fault")) return Fault(argc > 2 ? argv[2] : "uaf", false);
  if (!strcmp(mode, "faultw")) return Fault(argc > 2 ? argv[2] : "+0x1000000000", true);
  if (!strcmp(mode, "probe")) return Probe(argv[2], false);
  if (!strcmp(mode, "probew")) return Probe(argv[2], true);
  if (!strcmp(mode, "block")) return Block();
  if (!strcmp(mode, "chain")) return Chain();
  if (!strcmp(mode, "bench")) return Bench(argc > 2 ? atoi(argv[2]) : 500);
  printf("usage: gg_harness lower|fault [addr]|bench N\n"); return 2;
} }
