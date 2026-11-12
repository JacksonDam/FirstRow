// Putting a file in the system's trash: the Recycle Bin on Windows, and on Linux the trash
// the desktops share (the freedesktop.org trash, in the home folder), from where either can be
// put back.

#include "CPortable.h"

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#include <stdlib.h>
#include <string.h>

int fr_move_to_trash(const char *path_utf8) {
    // (The list of files to act on ends with two zeros.)
    wchar_t path[32768];
    int length = MultiByteToWideChar(CP_UTF8, 0, path_utf8, -1, path, 32766);
    if (length <= 0) return 0;
    for (wchar_t *letter = path; *letter; letter++) {
        if (*letter == L'/') *letter = L'\\';
    }
    path[length] = 0;
    SHFILEOPSTRUCTW operation;
    ZeroMemory(&operation, sizeof(operation));
    operation.wFunc = FO_DELETE;
    operation.pFrom = path;
    operation.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT;
    return SHFileOperationW(&operation) == 0 && !operation.fAnyOperationsAborted;
}
#elif defined(__linux__)
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int fr_make_folders(const char *path) {
    char partial[PATH_MAX];
    snprintf(partial, sizeof(partial), "%s", path);
    for (char *at = partial + 1; *at; at++) {
        if (*at != '/') continue;
        *at = 0;
        mkdir(partial, 0700);
        *at = '/';
    }
    return mkdir(partial, 0700) == 0 || errno == EEXIST;
}

int fr_move_to_trash(const char *path) {
    char real[PATH_MAX], trash[PATH_MAX], files[PATH_MAX + 16], info[PATH_MAX + 16];
    if (!realpath(path, real)) return 0;
    const char *data = getenv("XDG_DATA_HOME");
    const char *home = getenv("HOME");
    if (data && *data) snprintf(trash, sizeof(trash), "%s/Trash", data);
    else if (home && *home) snprintf(trash, sizeof(trash), "%s/.local/share/Trash", home);
    else return 0;
    snprintf(files, sizeof(files), "%s/files", trash);
    snprintf(info, sizeof(info), "%s/info", trash);
    if (!fr_make_folders(files) || !fr_make_folders(info)) return 0;

    // The home trash takes only what is on the home folder's own disk (a rename can't cross
    // from one disk to another, and nothing is copied or deleted here).
    struct stat source, target;
    if (lstat(real, &source) != 0 || stat(files, &target) != 0 || source.st_dev != target.st_dev) return 0;

    const char *name = strrchr(real, '/');
    name = name ? name + 1 : real;
    char kept[PATH_MAX * 2], record[PATH_MAX * 2];
    for (int copy = 1; copy < 1000; copy++) {
        if (copy == 1) snprintf(kept, sizeof(kept), "%s/%s", files, name);
        else snprintf(kept, sizeof(kept), "%s/%s.%d", files, name, copy);
        if (access(kept, F_OK) != 0) {
            const char *kept_name = strrchr(kept, '/') + 1;
            snprintf(record, sizeof(record), "%s/%s.trashinfo", info, kept_name);
            // Where it came from and when, which is what lets the desktop put it back.
            FILE *out = fopen(record, "wx");
            if (!out) continue;
            time_t now = time(NULL);
            struct tm when;
            localtime_r(&now, &when);
            char stamp[32];
            strftime(stamp, sizeof(stamp), "%Y-%m-%dT%H:%M:%S", &when);
            fprintf(out, "[Trash Info]\nPath=");
            for (const unsigned char *letter = (const unsigned char *)real; *letter; letter++) {
                if ((*letter >= 'A' && *letter <= 'Z') || (*letter >= 'a' && *letter <= 'z') || (*letter >= '0' && *letter <= '9') || strchr("/-_.~", *letter)) fputc(*letter, out);
                else fprintf(out, "%%%02X", *letter);
            }
            fprintf(out, "\nDeletionDate=%s\n", stamp);
            fclose(out);
            if (rename(real, kept) == 0) return 1;
            unlink(record);
            return 0;
        }
    }
    return 0;
}
#else
int fr_move_to_trash(const char *path) {
    (void)path;
    return 0;
}
#endif
