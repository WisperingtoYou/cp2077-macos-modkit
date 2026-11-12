# gpuguard

A dylib that `launch_red4ext.sh` injects next to RED4ext. It uses no game addresses: it hooks the Metal (AGX) classes it finds at runtime.

- **Error log.** Each Metal command buffer that fails is logged to `<game>/gpuguard.log` with its queue, error, encoder counts, and the event waits and signals it carried. The first error also logs the last 256 command buffers. Use this log to find out why the game froze.
- **Memory line.** Every 15 s, one line with the game's memory, GPU memory against the working-set limit, swap, free memory and thermal state.
- **Hang and stall markers.** A command buffer that has not completed after 10 s, and 10 s with no new command buffers, are logged. These are log only.
- **Mip guard.** It clamps texture descriptors that ask for more mip levels than the texture size allows, and drops blits and views into the levels that were cut. D3D12 accepts such textures, but Metal asserts and crashes.

Environment variables:
- `GPUGUARD_LOG`: log path.
- `GPUGUARD_MEM_S`, `GPUGUARD_HANG_S`, `GPUGUARD_STALL_S`, `GPUGUARD_HEARTBEAT_S`: intervals in seconds (0 turns the memory line off).
- `GPUGUARD_ENCINFO=1`: per-encoder fault states. This costs about 3% GPU time.
- `GPUGUARD_RECOVER=1`, `GPUGUARD_QSWAP=1`: experimental. They re-signal the fences of a failed command buffer, or move work off a queue that timed out. These are off by default: in one test, recovery on a GPU that had stopped responding ended with WindowServer being killed.

Build: `./build.sh` (Command Line Tools only). `gg_harness` is a standalone test of the Metal behaviour gpuguard relies on.
