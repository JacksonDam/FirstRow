// Handing a DVD to the PC's own DVD player on Windows.
//
// First Row plays a DVD that isn't protected against copying itself. One that is protected
// can only be played by an app that is licensed to: Windows has none of its own, but a PC
// often has one (Microsoft's Windows DVD Player, or the one that came with the drive). Such
// apps tell Windows that they play DVD movies, for its AutoPlay settings, and that is where
// they are found here: first the one the person has chosen there, then any that is listed.

#include "CPortable.h"

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#include <wchar.h>

#define FR_AUTOPLAY L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\AutoplayHandlers"
#define FR_DVD_MOVIE L"PlayDVDMovieOnArrival"

static int fr_registry_text(HKEY root, const wchar_t *key, const wchar_t *name, wchar_t *text, DWORD letters) {
    DWORD size = letters * sizeof(wchar_t);
    text[0] = 0;
    return RegGetValueW(root, key, name, RRF_RT_REG_SZ, NULL, text, &size) == ERROR_SUCCESS && text[0] != 0;
}

// Windows' own entries in the list aren't players: "take no action", "open the folder",
// "ask every time", the old Windows Media Player, which no longer plays DVDs, and "look for
// an app in the Store", which is what a PC with no player has there.
static int fr_is_player(const wchar_t *handler) {
    static const wchar_t *others[] = { L"MSTakeNoAction", L"MSOpenFolder", L"MSPromptEachTime", L"MSPlayDVDMovieOnArrival", NULL };
    for (int index = 0; others[index]; index++) {
        if (_wcsicmp(handler, others[index]) == 0) return 0;
    }
    return _wcsnicmp(handler, L"FindApp", 7) != 0;
}

// Starts the app behind an AutoPlay entry on the drive, the way Windows itself would.
static int fr_start_player(const wchar_t *handler, const wchar_t *drive) {
    static const HKEY roots[2] = { HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE };
    wchar_t key[768], kind[256], verb[128];
    if (!fr_is_player(handler)) return 0;
    _snwprintf(key, 767, L"%ls\\Handlers\\%ls", FR_AUTOPLAY, handler);
    key[767] = 0;
    for (int index = 0; index < 2; index++) {
        if (!fr_registry_text(roots[index], key, L"InvokeProgID", kind, 256)) continue;
        if (!fr_registry_text(roots[index], key, L"InvokeVerb", verb, 128)) wcscpy(verb, L"open");
        SHELLEXECUTEINFOW request;
        ZeroMemory(&request, sizeof(request));
        request.cbSize = sizeof(request);
        request.fMask = SEE_MASK_CLASSNAME | SEE_MASK_FLAG_NO_UI;
        request.lpClass = kind;
        request.lpVerb = verb;
        request.lpFile = drive;
        request.nShow = SW_SHOWNORMAL;
        if (ShellExecuteExW(&request)) return 1;
    }
    return 0;
}

int fr_windows_open_dvd_player(const char *drive_utf8) {
    static const HKEY roots[2] = { HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE };
    static const wchar_t *choices[2] = { L"UserChosenExecuteHandlers", L"EventHandlersDefaultSelection" };
    wchar_t drive[16], key[768], handler[512];
    if (!MultiByteToWideChar(CP_UTF8, 0, drive_utf8, -1, drive, 16)) return 0;

    // The player chosen for DVD movies in Windows' AutoPlay settings.
    for (int index = 0; index < 2; index++) {
        _snwprintf(key, 767, L"%ls\\%ls\\%ls", FR_AUTOPLAY, choices[index], FR_DVD_MOVIE);
        key[767] = 0;
        if (fr_registry_text(HKEY_CURRENT_USER, key, NULL, handler, 512) && fr_start_player(handler, drive)) return 1;
    }

    // Or the first app that has told Windows it plays them.
    _snwprintf(key, 767, L"%ls\\EventHandlers\\%ls", FR_AUTOPLAY, FR_DVD_MOVIE);
    key[767] = 0;
    for (int index = 0; index < 2; index++) {
        HKEY list;
        if (RegOpenKeyExW(roots[index], key, 0, KEY_READ, &list) != ERROR_SUCCESS) continue;
        for (DWORD entry = 0;; entry++) {
            DWORD letters = 512;
            if (RegEnumValueW(list, entry, handler, &letters, NULL, NULL, NULL, NULL) != ERROR_SUCCESS) break;
            if (fr_start_player(handler, drive)) {
                RegCloseKey(list);
                return 1;
            }
        }
        RegCloseKey(list);
    }
    return 0;
}
#else
int fr_windows_open_dvd_player(const char *drive_utf8) {
    (void)drive_utf8;
    return 0;
}
#endif
