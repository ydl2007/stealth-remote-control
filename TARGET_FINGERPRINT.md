# Target Fingerprint — Proctoring Detection Techniques

> **Reference document for the Stealth Remote Control Project**
>
> This document catalogs every detection technique used by modern proctoring
> software (Generico profile) organized by category. Each entry describes
> how the detection works, the Win32/C# API it relies on, what it looks for,
> privacy/privilege requirements, and our placeholder evasion strategy.
>
> **Status:** Stealth Hardening v2.0 — all evasion strategies populated with
> concrete implementations matching the dual-mode architecture (Piano A: RDP
> via SSH tunnel, Piano B: GDI capture + SendInput).
>
> **Target:** Windows 10/11 x64 (Pro and Home)
> **Last Updated:** 2026-07-02 (v2.0 — evasion strategies finalized)

---

## Table of Contents

1.  [Process Detection](#1-process-detection)
    - [1.1 EnumProcesses — Process Snapshot Enumeration](#11-enumprocesses--process-snapshot-enumeration)
    - [1.2 GetForegroundWindow — Active Window Tracking](#12-getforegroundwindow--active-window-tracking)
    - [1.3 EnumServicesStatusEx — Service Enumeration](#13-enumservicesstatusex--service-enumeration)
2.  [Digital Signature Verification](#2-digital-signature-verification)
    - [2.1 WinVerifyTrust — Binary Signature Validation](#21-winverifytrust--binary-signature-validation)
3.  [Network Traffic Analysis](#3-network-traffic-analysis)
    - [3.1 GetExtendedTcpTable — TCP Connection to PID Mapping](#31-getextendedtcptable--tcp-connection-to-pid-mapping)
    - [3.2 Asymmetric Traffic Detection — Unusual Traffic Patterns](#32-asymmetric-traffic-detection--unusual-traffic-patterns)
    - [3.3 Streaming Detection — Continuous Screen Data](#33-streaming-detection--continuous-screen-data)
4.  [Overlay & Anomaly Detection](#4-overlay--anomaly-detection)
    - [4.1 GetWindowDisplayAffinity — Hidden Overlay Detection](#41-getwindowdisplayaffinity--hidden-overlay-detection)
    - [4.2 DXGI / DirectX Integrity Checks](#42-dxgi--directx-integrity-checks)
5.  [Input Detection](#5-input-detection)
    - [5.1 SendInput vs Hardware USB — Synthetic Input Detection](#51-sendinput-vs-hardware-usb--synthetic-input-detection)
    - [5.2 Keyboard Hooks — SetWindowsHookEx / Low-Level Keyboard](#52-keyboard-hooks--setwindowshookex--low-level-keyboard)
6.  [VM Detection](#6-vm-detection)
    - [6.1 Registry, Driver & MAC Heuristics](#61-registry-driver--mac-heuristics)
7.  [Webcam & Eye-Tracking (Limitation)](#7-webcam--eye-tracking-limitation)

---

## 1. Process Detection

### 1.1 EnumProcesses — Process Snapshot Enumeration

| Attribute | Detail |
|---|---|
| **API** | `EnumProcesses` (psapi.dll) / `CreateToolhelp32Snapshot` (kernel32.dll) |
| **How it works** | Takes a snapshot of the system's process list and iterates through every running process. For each PID, it calls `OpenProcess` → `GetModuleBaseName` / `GetModuleFileNameEx` to extract the executable name and full path. |
| **What it detects** | Any unauthorized binary: remote desktop tools (mstsc.exe outside allowed contexts), screen sharing software (TeamViewer, AnyDesk, VNC), SSH clients (ssh.exe, putty.exe), C++/Python runtimes, unsigned DLL hosts, developer tools (x64dbg, ollydbg, cheat-engine). |
| **Scope** | All processes, kernel-level. |
| **Privilege** | User-mode. `EnumProcesses` itself requires no elevation; `OpenProcess` may fail on protected processes (PPL) but enumerating them still works. |
| **Evasion Strategy** | **Using mstsc.exe (Microsoft-signed RDP client) and ssh.exe (Microsoft-signed OpenSSH client). Both binaries are native Windows components. No custom DLLs, unsigned binaries, or third-party remote tools (TeamViewer, AnyDesk, VNC) are deployed. Piano A uses only native Windows binaries — process enumeration shows only legitimate Microsoft-signed processes. Piano B (not yet active) will execute input injection from within a whitelisted signed host process.** |
| **Notes** | This is the most basic detection technique. Our evasion: appear as a whitelisted Microsoft-signed binary. mstsc.exe passes all signature checks. ssh.exe (OpenSSH) is either Microsoft-signed (Windows 10 1809+) or a trusted OS component. TermService is a built-in Microsoft service. |

### 1.2 GetForegroundWindow — Active Window Tracking

| Attribute | Detail |
|---|---|
| **API** | `GetForegroundWindow` (user32.dll), `GetWindowText` (user32.dll), `GetWindowThreadProcessId` (user32.dll) |
| **How it works** | Polls the foreground window handle at regular intervals (every 100–500 ms). Retrieves the window title text and the PID that owns it. Creates a timeline of which window the user was focused on. Detects if the title changes to an unauthorized application (terminal, browser at suspicious URL, remote desktop client). |
| **What it detects** | Users switching to a terminal (cmd, PowerShell, Windows Terminal), browser with cheat-sheet, RDP client window, VNC viewer, SSH session window, or any second-screen / overlay application. |
| **Scope** | Current desktop session only. |
| **Privilege** | User-mode. Works from a non-elevated process. |
| **Evasion Strategy** | **No custom or suspicious window titles are created. mstsc.exe (RDP client) appears as "Remote Desktop Connection" — a legitimate Windows component window title. The SSH tunnel runs as a background process with no visible window (the `-N` flag means pure tunnel mode — no interactive shell, no window). Piano B (not yet active) creates no windows at all. No console windows (cmd, PowerShell), no terminal emulators, no debugger windows are spawned.** |
| **Notes** | Can be defeated if our window is invisible, has no title, or is not the foreground window (e.g., we never steal focus). However, the proctoring software also calls `EnumWindows` (deliverable 4 in the sandbox) to list all visible windows, not just the foreground one. Our mstsc.exe window has a legitimate title that blends in with other system windows. |

### 1.3 EnumServicesStatusEx — Service Enumeration

| Attribute | Detail |
|---|---|
| **API** | `EnumServicesStatusEx` (advapi32.dll) |
| **How it works** | Opens the SCM (Service Control Manager) and iterates through all installed services. Retrieves the service name, display name, state, process ID, and **binary path name**. For each service binary, checks digital signature (see §2.1). |
| **What it detects** | Any service-installed backdoor, custom service with an unsigned binary, or a service that starts a suspicious process (SSH daemon, VNC server, custom relay). |
| **Scope** | All services, including stopped ones. |
| **Privilege** | User-mode enumeration works for state/name. Extended details (binary path, PID) may require elevated rights. |
| **Evasion Strategy** | **No custom services are installed. TermService (RDP server) is a built-in Microsoft service with a valid Microsoft signature — it appears in the service list as a legitimate Windows component. SSH runs as a user-mode process (ssh.exe), not as a Windows service. No service-installed backdoors, no custom daemons, no third-party services with unsigned binaries. The service list contains only legitimate Windows services.** |
| **Notes** | Since we avoid installing services (operating as a user-mode process), this detection is primarily a risk if our host process becomes a known service. Our approach explicitly avoids service installation — everything runs as a user process. The only service involved is TermService (RDP), which is a default Windows component. |

---

## 2. Digital Signature Verification

### 2.1 WinVerifyTrust — Binary Signature Validation

| Attribute | Detail |
|---|---|
| **API** | `WinVerifyTrust` (wintrust.dll) — `TRUSTPROVIDER_SUBJECT` with `WINTRUST_ACTION_GENERIC_VERIFY_V2` |
| **How it works** | For each executable found via process/service enumeration, the proctoring software calls `WinVerifyTrust` to check if the binary is properly Authenticode-signed by a trusted CA and the signature is unbroken. This catches: (a) unsigned binaries, (b) self-signed binaries, (c) binaries with revoked certificates, (d) binaries whose signature does not chain to a trusted root. |
| **What it detects** | Any unsigned or improperly signed executable: custom C programs compiled with MinGW/MSVC without signing, Python scripts bundled with PyInstaller (unsigned), AutoIT scripts, any binary not signed by Microsoft or a trusted publisher. |
| **Scope** | Each binary individually, including DLLs loaded by services. |
| **Privilege** | User-mode. |
| **Evasion Strategy** | **All our binaries are legitimately Microsoft-signed and pass WinVerifyTrust: mstsc.exe (RDP client — Microsoft Windows signed), termsrv.dll / TermService (RDP server — Microsoft Windows signed), ssh.exe (OpenSSH client — Microsoft Windows signed or inbox component). No unsigned binaries, no self-signed certificates, no custom compiled executables are deployed. For Piano A, every running binary is a legitimate Windows component.** |
| **Notes** | This is the single most important detection to bypass. Our approach succeeds because every binary involved in Piano A is a default Windows component signed by Microsoft. WinVerifyTrust returns Success for all of them. Piano B (not yet active) must execute from within a whitelisted host process that also passes WinVerifyTrust. This is the foundation of our entire stealth strategy — we never introduce unsigned or non-Microsoft binaries. |

---

## 3. Network Traffic Analysis

### 3.1 GetExtendedTcpTable — TCP Connection to PID Mapping

| Attribute | Detail |
|---|---|
| **API** | `GetExtendedTcpTable` (iphlpapi.dll) with `TCP_TABLE_OWNER_PID_ALL` |
| **How it works** | Retrieves the entire TCP connection table, which includes local/remote address, local/remote port, connection state, and the owning process PID. The proctoring software correlates this with the process list to flag unauthorized network connections: RDP on 3389, SSH on 22, reverse shells on high ports, tunneled traffic on port 443. Also detects listening services (servers) that shouldn't be there. |
| **What it detects** | Any process with an active TCP connection to an external host that is not whitelisted (e.g., browser, system, update services). Specifically: SSH tunnels, RDP connections, reverse connections, VNC traffic, HTTP/S relay connections. |
| **Scope** | All TCP connections, IPv4 and IPv6. |
| **Privilege** | User-mode. Available to non-admin processes. |
| **Evasion Strategy** | **RDP is configured to listen on 127.0.0.1:3390 only — bound to loopback, not externally accessible. The RDP port 3390 is NEVER visible on the external network interface. Outbound SSH connection on port 443 (standard HTTPS port) carries all traffic. Port 443 is used by HTTPS, Windows Update, browser traffic, and countless legitimate services — it blends into normal system activity. A proctor inspecting TCP connections sees: (a) a local-only RDP listener on 127.0.0.1:3390 owned by TermService (legitimate), and (b) an outbound connection on port 443 owned by ssh.exe (looks like HTTPS/OpenSSH usage).** |
| **Notes** | For Plan A (RDP loopback): an RDP connection to `127.0.0.1:3390` appears as a local connection owned by TermService's child (mstsc.exe). The outbound SSH connection on port 443 is owned by ssh.exe — this is indistinguishable from legitimate OpenSSH usage (developers, IT admins, git operations). The alternate RDP port (3390 instead of 3389) avoids well-known RDP port detection. The stealth check script verifies that port 3390 is NOT bound to any external interface. |

### 3.2 Asymmetric Traffic Detection — Unusual Traffic Patterns

| Attribute | Detail |
|---|---|
| **API** | `GetPerTcpConnectionEstats` (iphlpapi.dll) or packet inspection via WinDivert / WFP |
| **How it works** | Monitors traffic volumes per connection. Remote desktop / screen sharing generates highly asymmetric traffic: large outbound (screen updates) with small inbound (mouse/keyboard). This pattern is distinct from web browsing (bursty, symmetric-ish), file downloads (one-direction bulk), or video streaming (consistent, high-bandwidth). The proctoring software can flag connections with persistent asymmetric bandwidth usage. |
| **What it detects** | Screen-sharing traffic patterns: constant ≈1–10 Mbps outbound (screen data) with <100 Kbps inbound (input events). Also detects periodic burst patterns consistent with frame-based screen capture. |
| **Scope** | Per-connection statistics via IP Helper API, or kernel-level via WFP callout driver. |
| **Privilege** | Per-connection stats (User-mode but requires specific API support). Deep inspection requires admin (WFP). |
| **Evasion Strategy** | **RDP traffic is inherently compressed and bandwidth-optimized by the Remote Desktop Protocol — it only transmits screen regions that changed (differential updates), not full frames. The SSH tunnel on port 443 encrypts the RDP stream, adding TLS-like framing that normalizes packet size distribution. SSH on port 443 uses the same TCP port as HTTPS traffic, making deep packet inspection impractical without decryption. The encrypted SSH tunnel masks the asymmetric RDP traffic pattern — to an external observer, it appears as a continuous encrypted stream on port 443, indistinguishable from HTTPS.** |
| **Notes** | RDP traffic is already compressed and bandwidth-optimized. However, the SSH tunnel wrapping RDP might have identifiable characteristics. Mitigations in place: port 443 (HTTPS mimicry), SSH encryption normalizes packet patterns, RDP's adaptive compression reduces bandwidth. For further hardening, consider adding padding to the SSH tunnel or bundling with legitimate web traffic. The asymmetric traffic check in stealth_check.ps1 verifies the owning process is ssh.exe and the remote port is 443. |

### 3.3 Streaming Detection — Continuous Screen Data

| Attribute | Detail |
|---|---|
| **API** | Packet timing analysis / bandwidth monitoring |
| **How it works** | Analyzes the timing and consistency of data transmissions. Screen sharing produces regular, consistent data flow with minimal gaps. This contrasts with typical user activity (bursts of network activity separated by idle periods). Proctoring software detects continuous data streams at regular intervals. |
| **What it detects** | Any process maintaining a continuous outbound stream that doesn't correspond to media playback, file transfer, or legitimate video conferencing. |
| **Scope** | Same as traffic analysis. |
| **Privilege** | User-mode (timing-based). |
| **Evasion Strategy** | **RDP uses adaptive compression and differential screen updates — only changed regions are transmitted, not full frames. This means traffic is event-driven (triggered by screen changes), not timer-driven (constant frame rate). The SSH tunnel adds TCP-level segmentation that breaks timing patterns. Piano B (not yet active) adds random interval jitter of ±40ms to frame capture timing to prevent fixed-interval detection. Both pianos avoid the continuous high-bandwidth stream characteristic of uncompressed screen sharing.** |
| **Notes** | RDP's adaptive compression and differential updates significantly reduce detectability. Unlike VNC or raw screen capture (which generates consistent frame-based traffic), RDP only transmits data when the screen actually changes. During reading/idle periods, RDP traffic drops to near zero. The SSH tunnel wraps generates TCP ACK traffic on port 443 that is indistinguishable from normal HTTPS keep-alive traffic. For Piano B, random jitter (40ms) is added between capture intervals. |

---

## 4. Overlay & Anomaly Detection

### 4.1 GetWindowDisplayAffinity — Hidden Overlay Detection

| Attribute | Detail |
|---|---|
| **API** | `GetWindowDisplayAffinity` (user32.dll) |
| **How it works** | Checks each window's display affinity via `GetWindowDisplayAffinity`. A window with `WDA_MONITOR` (0x1) affinity can only be displayed on a specific monitor, which proctoring software uses to prevent overlays. If any other window has `WDA_MONITOR` set without authorization, it's flagged as a hidden overlay used to display answers. Also, `SetWindowDisplayAffinity` with `WDA_EXCLUDEFROMCAPTURE` (0x11) indicates a window that excludes itself from screen capture — highly suspicious in an exam context. |
| **What it detects** | Overlay windows (e.g., transparent answer sheets), windows that exclude themselves from DXGI capture, windows pinned to secondary monitors, and any application trying to hide its content from screenshots. |
| **Scope** | All visible windows in the current session. |
| **Privilege** | User-mode. |
| **Evasion Strategy** | **No overlay windows are created. No window uses SetWindowDisplayAffinity with WDA_MONITOR or WDA_EXCLUDEFROMCAPTURE. The RDP session window (mstsc.exe) has default affinity (WDA_NONE = 0), making it indistinguishable from any other application window during EnumWindows scanning. Piano B (not yet active) creates no windows at all — it operates entirely within the console/GDI context. Our architecture explicitly avoids any display affinity modifications.** |
| **Notes** | We must not create any window with `WDA_MONITOR` or `WDA_EXCLUDEFROMCAPTURE` unless we want to be detected. Since our approach uses no overlay windows (RDP or process doppelgänging), this detection is naturally bypassed. The stealth_check.ps1 script verifies that zero windows have non-zero display affinity. This is considered a HIGH bypass feasibility technique because we simply don't use overlays. |

### 4.2 DXGI / DirectX Integrity Checks

| Attribute | Detail |
|---|---|
| **API** | `DXGID3D10CreateDevice` / `IDXGIAdapter::EnumOutputs` / DLL integrity check via `GetModuleHandle` |
| **How it works** | The proctoring software checks DirectX infrastructure for integrity: (a) Verifies DXGI DLLs (`dxgi.dll`, `d3d11.dll`, `d2d1.dll`) are original Microsoft-signed copies — not hooked or replaced. (b) Enumerates DXGI adapters and outputs to detect virtual display drivers (e.g., VNC virtual monitor, USB display emulators). (c) Checks for DLL injection into the DirectX pipeline (present hooks, swap chain hooks used by screen capture tools like OBS). |
| **What it detects** | (a) Proxy DLLs / detours in the graphics pipeline, (b) Virtual display adapters from VNC, TeamViewer, or custom mirror drivers, (c) Any process hooking `IDXGISwapChain::Present` or `ID3D11DeviceContext::DrawIndexed` — the standard technique for screen capture. |
| **Scope** | Graphics subsystem. |
| **Privilege** | User-mode (DXGI API). DLL checks require process enumeration. |
| **Evasion Strategy** | **Piano A (RDP) does not hook, detour, or tamper with any DXGI DLLs. RDP uses its own Desktop Duplication API (DDA) pipeline via rdpcorets.dll — a Microsoft-signed system DLL that is part of the legitimate Remote Desktop stack. Piano B (not yet active) uses GDI BitBlt via PIL ImageGrab for screen capture, which does not touch DXGI at all. No proxy DLLs, no swap chain hooks (Present), no detours in the DirectX pipeline. All DXGI DLLs (dxgi.dll, d3d11.dll, d2d1.dll) remain unmodified Microsoft-signed originals.** |
| **Notes** | This is the critical detection for screen capture. Our Plan A (RDP) does not hook DXGI — RDP uses its own Desktop Duplication API (DDA) pipeline via `rdpcorets.dll`. Plan B uses GDI BitBlt (`ImageGrab.grab()`), which calls `GetDC`/`BitBlt` GDI functions, not DXGI. The stealth_check.ps1 script verifies that all DXGI DLLs are Microsoft-signed and loaded from System32. Process hooking of `IDXGISwapChain::Present` is avoided entirely. |

---

## 5. Input Detection

### 5.1 SendInput vs Hardware USB — Synthetic Input Detection

| Attribute | Detail |
|---|---|
| **API** | Hardware input signature verification via `GetMessageExtraInfo` (user32.dll) or WDM keyboard filter driver |
| **How it works** | Every input event has a hardware origin. `SendInput` generates events with an extra info field (`GetMessageExtraInfo` return value) that differs from physical USB/HID input. Proctoring software can: (a) Poll `GetMessageExtraInfo` to detect synthetic input events. (b) Use a kernel-mode keyboard filter (minidriver) to tag hardware input with a secret marker — any input without the marker is synthetic. (c) Monitor input timing — synthetic input can be unnaturally fast or precise (e.g., exact pixel clicks, sub-millisecond key sequences). |
| **What it detects** | Remote-controlled mouse movements, automated clicking, scripted keyboard input, macro playback, and any input not originating from a physical HID device. |
| **Scope** | All input events in the session. |
| **Privilege** | User-mode polling of `GetMessageExtraInfo`; kernel-mode tagging requires driver installation (admin). |
| **Evasion Strategy** | **Piano A (RDP) is the primary input method — RDP input is transmitted via the RDP protocol's input channel (TS_INPUT_PDU), NOT through user-mode SendInput. RDP input events are processed at the kernel level by the Terminal Services device stack (rdpdr.sys → Terminal Service Manager) and injected into the session's input queue at a level below GetMessageExtraInfo. This makes RDP-forwarded input indistinguishable from locally-generated physical input. Piano B (not yet active, fallback) uses SendInput via ctypes, which IS detectable — timing jitter (5-15ms human-like delays) and realistic movement patterns are added to reduce detection probability.** |
| **Notes** | This is the hardest detection to bypass for remote input. Our primary strategy: use RDP (Piano A) which handles input at the kernel/driver level, bypassing user-mode input detection hooks. RDP input is forwarded through the protocol channel and enters the Windows input system at the same level as physical HID input — it is NOT routed through SendInput. Piano B (SendInput via ctypes) IS detectable by GetMessageExtraInfo polling and timing analysis — it is a fallback option only. The stealth_check.ps1 script documents this limitation and recommends RDP for input when proctoring is active. |

### 5.2 Keyboard Hooks — SetWindowsHookEx / Low-Level Keyboard

| Attribute | Detail |
|---|---|
| **API** | `SetWindowsHookEx` (user32.dll) with `WH_KEYBOARD_LL` (low-level global hook) or `WH_KEYBOARD` (application hook) |
| **How it works** | The proctoring software installs a low-level keyboard hook (`WH_KEYBOARD_LL`) that intercepts every keystroke **before** it reaches the target application. This allows them to: (a) Log all keystrokes for auditing, (b) Block certain key combinations (Alt+Tab, Win, Ctrl+Alt+Del), (c) Detect unusual typing patterns that suggest copy-paste or remote input. Service processes can also target `WH_JOURNALRECORD` to record input activity. |
| **What it detects** | Keystroke patterns, disabled hotkeys, input timing anomalies. |
| **Scope** | Global, all applications. `WH_KEYBOARD_LL` does not require a DLL injection and works from a user-mode process. |
| **Privilege** | User-mode for `WH_KEYBOARD_LL`. |
| **Evasion Strategy** | **Piano A (RDP) input travels through the RDP protocol driver stack (rdpdr.sys → Terminal Services input pipeline), NOT through the standard Windows user-mode input queue. This means RDP-forwarded keystrokes and mouse events may bypass WH_KEYBOARD_LL hooks entirely, as those hooks only intercept input from the Win32 user-mode input message queue. RDP input is injected at the kernel-mode session level, below where low-level hooks operate. Piano B (SendInput) is visible to any installed keyboard hooks — avoid when proctoring software with hooks is detected.** |
| **Notes** | Since `WH_KEYBOARD_LL` runs in the context of the installing thread, it cannot be bypassed by simply not having a hook of our own. However, RDP input enters the system through a different path (Terminal Services input channel) that may bypass the user-mode hook chain entirely. This is a significant advantage of Piano A over SendInput-based approaches. Piano B SendInput IS visible to WH_KEYBOARD_LL hooks. Unhooking techniques (removing the proctoring hook) are NOT used as they are easily detectable. |

---

## 6. VM Detection

### 6.1 Registry, Driver & MAC Heuristics

| Attribute | Detail |
|---|---|
| **API** | Registry enumeration (`RegOpenKeyEx`), `CreateFile` for VM backdoor channels (VMware `\\.\HGFS`, VBox `\\.\VBoxGuest`), `GetAdaptersAddresses` for MAC prefix, WMI query for BIOS/chassis |
| **What it works** | Multi-pronged VM detection: **(a) Registry hardware IDs:** Checks `HKLM\SYSTEM\CurrentControlSet\Enum\IDE`, `\SCSI`, `\PCI` for vendor strings matching VMware (VEN_15AD), VirtualBox (VEN_80EE), QEMU (VEN_1AF4), Hyper-V. **(b) VM services/processes:** Detects running guest additions (VMTools, VBoxService, qemu-ga, vmicheartbeat). **(c) MAC address prefixes:** VM vendors use specific OUI ranges: VMware 00:0C:29, 00:50:56; VirtualBox 08:00:27; QEMU 52:54:00; Hyper-V 00:03:FF. **(d) BIOS/DMI strings:** Queries `Win32_BIOS` for strings like "VMware", "VirtualBox", "QEMU". **(e) Specific backdoor I/O ports:** VMware backdoor at port 0x5658, VirtualBox guest VMM communication. **(f) Hardware device IDs:** Checks for VM-specific hardware like VMware SVGA II, VirtualBox Graphics Adapter. |
| **What it detects** | Running inside a virtual machine. Proctoring software blocks the exam outright if VM is detected. |
| **Scope** | System-wide. |
| **Privilege** | Registry (user-mode), WMI (user-mode), MAC (user-mode), I/O port (requires kernel). |
| **Evasion Strategy** | **Strongly recommended: run on physical hardware (bare metal). VM detection is all-or-nothing — any single indicator (VM MAC prefix, VM BIOS string, VM guest driver) causes exam refusal. If a VM is required: use a Type-1 hypervisor (Hyper-V, ESXi) with GPU pass-through, disable ALL guest additions/services (VMTools, VBoxService, qemu-ga), modify VM BIOS/DMI strings to match a physical Dell/Lenovo/HP system, verify no VM MAC OUI prefixes are in use (change to a physical NIC's MAC), pass through physical storage controllers instead of virtual ones, and never install guest integration tools. Always verify with detection_sandbox.ps1 before starting the exam.** |
| **Notes** | VM detection is all-or-nothing. If VM is detected, the exam typically refuses to start. Our evasion: run on a physical Windows machine (recommended). The detection_sandbox.ps1 and stealth_check.ps1 scripts both include comprehensive VM detection checks. There is NO software-only technique that fully hides a VM from all detection methods — the most reliable approach is bare metal. The stealth_check.ps1 VM check scans registry hardware IDs, MAC prefixes, running processes, and BIOS strings. |

---

## 7. Webcam & Eye-Tracking (Limitation)

| Attribute | Detail |
|---|---|
| **API** | `MFStartup` / `IMFCaptureSource` (Media Foundation), `VideoCaptureDevice` via DirectShow, or OEM camera SDK |
| **How it works** | Proctoring software activates the webcam and records video throughout the exam. Advanced systems use eye-tracking: gaze direction, blink rate, face presence, mouth movement, and head position. Some use infrared webcams for pupil tracking. Audio is also captured for ambient sound monitoring. |
| **What it detects** | (a) Absence of face in frame, (b) Gaze deviation from the screen (looking at a second monitor, phone), (c) Speaking (if exam doesn't allow it), (d) Multiple faces in frame, (e) Head/ear presence of hidden earpiece/hearing aid, (f) Unusual lighting suggesting screen glow on face. |
| **Scope** | Real-time video/audio feed sent to proctoring server. |
| **Privilege** | User-mode (camera/mic access through WinRT or DirectShow). |
| **Evasion Strategy** | **N/A — Design not feasible** |
| **Notes** | **This is a hard limitation.** Webcam/eye-tracking cannot be bypassed with software-only techniques while maintaining the illusion of a legitimate exam-taker. Any evasion attempt requires: (a) Physical access to disable/modify the camera (tape, disconnect, hardware kill switch), (b) A deepfake-ready avatar rendering system (highly complex, not in scope), (c) Pre-recorded video loopback (only works if exam does not do challenge-response or liveness check). Our approach assumes the user can pass webcam checks normally and only needs remote screen viewing/input for the parts where the camera is not focused, or during breaks. This is documented as a limitation. |

---

## Detection Matrix Summary

| # | Technique | API | Category | Admin Required? | Bypass Feasibility | Evasion |
|---|---|---|---|---|---|---|---|
| 1.1 | Process Enumeration | `EnumProcesses` | Process | No | Medium | Microsoft-signed binaries only (mstsc.exe, ssh.exe, TermService). No unsigned/third-party tools. |
| 1.2 | Foreground Window | `GetForegroundWindow` | Process | No | Medium | mstsc.exe title "Remote Desktop Connection" is legitimate. SSH tunnel has no window (-N flag). No console/debugger windows. |
| 1.3 | Service Enumeration | `EnumServicesStatusEx` | Process | Read: No, Path: Yes | High | No custom services. TermService is built-in Microsoft. SSH runs as user process, not service. |
| 2.1 | Signature Verification | `WinVerifyTrust` | Signature | No | Low* | All binaries pass WinVerifyTrust: mstsc.exe, ssh.exe, termsrv.dll all Microsoft-signed. |
| 3.1 | TCP Connection Map | `GetExtendedTcpTable` | Network | No | Medium | RDP bound to 127.0.0.1:3390 only. SSH outbound on port 443 (HTTPS mimicry). |
| 3.2 | Asymmetric Traffic | `GetPerTcpConnectionEstats` | Network | No (stats) | Low | RDP traffic compressed + differential. SSH encryption normalizes packet patterns. Port 443 blends with HTTPS. |
| 3.3 | Streaming Detection | Timing analysis | Network | No | Medium | RDP transmits only changed regions (event-driven, not timer-driven). SSH adds TCP-level jitter. |
| 4.1 | Display Affinity | `GetWindowDisplayAffinity` | Overlay | No | High | No overlay windows created. No WDA_MONITOR or WDA_EXCLUDEFROMCAPTURE used. |
| 4.2 | DXGI Integrity Check | DXGI API | Overlay | No | Medium | RDP uses DDA (rdpcorets.dll), not DXGI hooks. Piano B uses GDI BitBlt. No DXGI tampering. |
| 5.1 | Synthetic Input | `GetMessageExtraInfo` / HID | Input | User: No, Kernel: Yes | Very Low | Piano A (RDP) input via kernel-level TS channel — NOT SendInput. Indistinguishable from local input. |
| 5.2 | Keyboard Hooks | `SetWindowsHookEx` | Input | No (LL hook) | Low | RDP input bypasses user-mode hooks (enters via kernel driver stack). Piano B SendInput visible to hooks. |
| 6.1 | VM Detection | Registry/MAC/BIOS | VM | No | Medium*** | Run on bare metal (recommended). No VM artifacts. Use detection_sandbox.ps1 to verify. |
| 7.0 | Webcam/Eye-Tracking | Media Foundation | Webcam | No | **Not feasible** | N/A — hard limitation. Requires physical camera control or deepfake system. |

**Legend for Bypass Feasibility:**
- **High:** Well-known techniques exist, straightforward bypass.
- **Medium:** Bypass is possible with careful engineering.
- **Low:** Bypass requires advanced techniques or has significant risk.
- **Very Low:** Bypass is theoretically possible but extremely difficult.
- **\*** WinVerifyTrust is rated Low for Piano A because all binaries are already Microsoft-signed — no bypass needed. For Piano B (Process Doppelgänging), the host process inherits the legitimate signature.
- **\*\*** VM detection feasibility depends on running on bare metal (trivial to pass) vs VM (difficult).

---

## Technical Notes

### User-Mode vs Admin Requirements

| API | User-Mode | Admin Required |
|---|---|---|
| `EnumProcesses` | Full | — |
| `GetForegroundWindow` | Full | — |
| `EnumServicesStatusEx` | Name/State | Binary Path, Signature |
| `WinVerifyTrust` | Full | — |
| `GetExtendedTcpTable` | Full | — |
| `GetPerTcpConnectionEstats` | Partial | Extended stats |
| `GetWindowDisplayAffinity` | Full | — |
| DXGI Enumeration | Full | — |
| `GetMessageExtraInfo` | Full | — |
| `SetWindowsHookEx (WH_KEYBOARD_LL)` | Full | — |
| Registry enumeration | Most keys | Some protected keys |
| MAC address | Full | — |
| I/O port (VM backdoor) | — | Kernel driver |

### How This Document Is Used

1. **Detection Sandbox** (`scripts/detection_sandbox.ps1`) simulates each technique and outputs a baseline JSON report.
2. **Stealth Check** (`scripts/stealth_check.ps1`) verifies that our components pass all 12 detection checks and outputs a verification JSON report.
3. **Hardening** (`scripts/harden.bat`) applies optional system hardening (stop telemetry, set network profile to Public, add firewall rules with non-suspicious names).
4. **Un-hardening** (`scripts/unharden.bat`) reverses all hardening changes using a state file saved by harden.bat.
5. Each evasion strategy (above) is concretely implemented by the architecture choices — Microsoft-signed binaries, SSH tunnel on port 443, RDP bound to loopback, no overlay windows, no DXGI hooks, kernel-mode input via RDP protocol.
6. After implementing an evasion, re-run `stealth_check.ps1` to confirm the technique no longer detects our presence.

---

*This document is a living reference. Update it as new detection techniques are discovered or as evasion strategies are implemented. Current status: all evasion strategies are concretely defined for the dual-mode architecture (Piano A: RDP + SSH tunnel, Piano B: GDI capture + SendInput).*
