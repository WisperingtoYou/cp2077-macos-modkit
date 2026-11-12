// Curated notes for mods with Windows-only parts. Matched by file name or target path (case-insensitive).
enum KnownIssues {
    static let json = #"""
[
  {"match": "AppearanceRuntimePlugin.dll", "level": "partial",
   "note": "AMM's AppearanceRuntimePlugin is a closed-source Windows plugin with no macOS version. AMM works without it; only its optional native ACM presets are unavailable."},
  {"match": "red4ext/plugins/RedHotTools", "level": "partial",
   "note": "RedHotTools is a Windows-only developer plugin; mods that only use it for debugging still work."},
  {"match": "version.dll", "level": "partial",
   "note": "Contains a Windows loader DLL (version.dll / winmm.dll). The macOS stack loads mods through RED4ext instead; the DLL is skipped."},
  {"match": "winmm.dll", "level": "partial",
   "note": "Contains a Windows loader DLL (winmm.dll). The macOS stack loads mods through RED4ext instead; the DLL is skipped."},
  {"match": "cyber_engine_tweaks.asi", "level": "partial",
   "note": "Contains the Windows build of Cyber Engine Tweaks. The macOS port is already installed; the Windows files are skipped."}
]
"""#
}
