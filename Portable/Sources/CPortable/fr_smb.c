// Shared folders (SMB) on Linux and Windows: what a computer shares and what a shared folder
// holds, for the menus, and on Linux a file there read piece by piece for mpv.
//
// On Linux this is done with the system's own libsmbclient (Samba's, which the desktops and
// their file managers use), loaded as First Row runs if it is there. On Windows the system
// itself reaches shared folders by their names ("\\server\share"), so only signing in and
// listing are done here, and mpv opens the files as it opens any other.

#include "CPortable.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Adds a line ("d<tab>name" for a folder or a share, "f<tab>name" for a file) to what is answered.
static int fr_add_line(char *out, int capacity, int *used, char kind, const char *name) {
    int needed = (int)strlen(name) + 3;
    if (*used + needed >= capacity) return 0;
    *used += snprintf(out + *used, (size_t)(capacity - *used), "%c\t%s\n", kind, name);
    return 1;
}

#ifdef _WIN32
#include <windows.h>
#include <lm.h>
#include <winnetwk.h>

static int fr_wide(const char *text, wchar_t *out, int letters) {
    return MultiByteToWideChar(CP_UTF8, 0, text ? text : "", -1, out, letters) > 0;
}

static int fr_sign_in_failed(DWORD error) {
    return error == ERROR_ACCESS_DENIED || error == ERROR_LOGON_FAILURE || error == ERROR_INVALID_PASSWORD ||
        error == ERROR_BAD_USERNAME || error == ERROR_NOT_AUTHENTICATED || error == ERROR_ACCOUNT_DISABLED || error == ERROR_PASSWORD_EXPIRED;
}

int fr_smb_available(void) { return 1; }

static DWORD fr_add_connection(wchar_t *remote, const wchar_t *user, const wchar_t *password) {
    NETRESOURCEW resource;
    ZeroMemory(&resource, sizeof(resource));
    resource.dwType = RESOURCETYPE_ANY;
    resource.lpRemoteName = remote;
    return WNetAddConnection2W(&resource, password, user, CONNECT_TEMPORARY);
}

// Signs in to a share (or, with "IPC$", to the computer), so that the system reaches it.
// Returns 0 if it is reached, -1 if it can't be, -2 if a name and password are wanted (or
// these are wrong), -4 if the system is signed in to that computer as someone else already.
int fr_smb_connect(const char *server, const char *share, const char *user, const char *password) {
    wchar_t remote[1024], host[512], name[256], wideUser[256], widePassword[256];
    if (!fr_wide(server, host, 512) || !fr_wide(share, name, 256)) return -1;
    // (Windows reaches shared folders at their usual port only: one in the name is left out.)
    wchar_t *port = wcsrchr(host, L':');
    if (port && !wcschr(host, L']') && wcschr(host, L':') == port) *port = 0;
    swprintf(remote, 1024, L"\\\\%ls\\%ls", host, name);
    int signsIn = user && user[0];
    if (signsIn) { fr_wide(user, wideUser, 256); fr_wide(password, widePassword, 256); }
    DWORD result = fr_add_connection(remote, signsIn ? wideUser : NULL, signsIn ? widePassword : NULL);
    if (result == ERROR_SESSION_CREDENTIAL_CONFLICT && signsIn) {
        // Windows signs in to a computer as one person at a time, and it has already, as
        // someone else (as whoever is using the PC, often, when it first looked). What it
        // holds open there without a drive letter is let go of, and it is tried once more.
        wchar_t whole[1024];
        swprintf(whole, 1024, L"\\\\%ls\\IPC$", host);
        WNetCancelConnection2W(whole, 0, TRUE);
        WNetCancelConnection2W(remote, 0, TRUE);
        result = fr_add_connection(remote, wideUser, widePassword);
        if (result == ERROR_SESSION_CREDENTIAL_CONFLICT) return -4;
    }
    if (result == NO_ERROR || result == ERROR_ALREADY_ASSIGNED || result == ERROR_SESSION_CREDENTIAL_CONFLICT) return 0;
    return fr_sign_in_failed(result) ? -2 : -1;
}

int fr_smb_list(const char *server, const char *share, const char *path, const char *user, const char *password, char *out, int capacity) {
    int used = 0, count = 0;
    out[0] = 0;
    wchar_t host[512];
    if (!fr_wide(server, host, 512)) return -1;
    wchar_t *port = wcsrchr(host, L':');
    if (port && !wcschr(host, L']') && wcschr(host, L':') == port) *port = 0;
    if (!share || !share[0]) {
        if (user && user[0]) {
            int signedIn = fr_smb_connect(server, "IPC$", user, password);
            if (signedIn == -2 || signedIn == -4) return signedIn;
        }
        wchar_t computer[600];
        swprintf(computer, 600, L"\\\\%ls", host);
        SHARE_INFO_1 *shares = NULL;
        DWORD read = 0, total = 0;
        NET_API_STATUS status = NetShareEnum(computer, 1, (LPBYTE *)&shares, MAX_PREFERRED_LENGTH, &read, &total, NULL);
        if (status != NERR_Success && status != ERROR_MORE_DATA) return fr_sign_in_failed(status) ? -2 : -1;
        for (DWORD index = 0; index < read; index++) {
            // (Folders of files only: not printers, nor the system's own hidden shares.)
            if ((shares[index].shi1_type & 0xFF) != STYPE_DISKTREE || (shares[index].shi1_type & STYPE_SPECIAL)) continue;
            char name[1024];
            if (!WideCharToMultiByte(CP_UTF8, 0, shares[index].shi1_netname, -1, name, sizeof(name), NULL, NULL)) continue;
            size_t length = strlen(name);
            if (length == 0 || name[length - 1] == '$') continue;
            if (fr_add_line(out, capacity, &used, 'd', name)) count++;
        }
        if (shares) NetApiBufferFree(shares);
        return count;
    }
    int signedIn = fr_smb_connect(server, share, user, password);
    if (signedIn == -2 || signedIn == -4) return signedIn;
    wchar_t pattern[4096], wideShare[256], widePath[2048];
    if (!fr_wide(share, wideShare, 256) || !fr_wide(path, widePath, 2048)) return -1;
    for (wchar_t *letter = widePath; *letter; letter++) {
        if (*letter == L'/') *letter = L'\\';
    }
    if (widePath[0]) swprintf(pattern, 4096, L"\\\\%ls\\%ls\\%ls\\*", host, wideShare, widePath);
    else swprintf(pattern, 4096, L"\\\\%ls\\%ls\\*", host, wideShare);
    WIN32_FIND_DATAW entry;
    HANDLE search = FindFirstFileW(pattern, &entry);
    if (search == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError();
        if (error == ERROR_FILE_NOT_FOUND) return 0;
        return fr_sign_in_failed(error) ? -2 : -1;
    }
    do {
        if (wcscmp(entry.cFileName, L".") == 0 || wcscmp(entry.cFileName, L"..") == 0) continue;
        if (entry.dwFileAttributes & (FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM)) continue;
        char name[1024];
        if (!WideCharToMultiByte(CP_UTF8, 0, entry.cFileName, -1, name, sizeof(name), NULL, NULL)) continue;
        if (fr_add_line(out, capacity, &used, (entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 'd' : 'f', name)) count++;
    } while (FindNextFileW(search, &entry));
    FindClose(search);
    return count;
}

// Whether a file or a folder of a share that has been signed in to opens: a computer lists
// things it then keeps to itself, and pointers to files it holds somewhere else.
int fr_smb_reachable(const char *server, const char *share, const char *path, int isFolder, const char *user, const char *password) {
    (void)user; (void)password;
    wchar_t host[512], wideShare[256], widePath[2048], whole[4096];
    if (!fr_wide(server, host, 512) || !fr_wide(share, wideShare, 256) || !fr_wide(path, widePath, 2048)) return 0;
    wchar_t *port = wcsrchr(host, L':');
    if (port && !wcschr(host, L']') && wcschr(host, L':') == port) *port = 0;
    for (wchar_t *letter = widePath; *letter; letter++) {
        if (*letter == L'/') *letter = L'\\';
    }
    swprintf(whole, 4096, L"\\\\%ls\\%ls\\%ls", host, wideShare, widePath);
    if (isFolder) {
        // Looked in the way it is listed when it is opened. (Opened as a file is, a folder has
        // to be asked for as a backup would ask, and whoever runs the other computer is then
        // let into the folders that are kept from them.)
        wchar_t pattern[4200];
        swprintf(pattern, 4200, L"%ls\\*", whole);
        WIN32_FIND_DATAW entry;
        HANDLE search = FindFirstFileW(pattern, &entry);
        if (search == INVALID_HANDLE_VALUE) return GetLastError() == ERROR_FILE_NOT_FOUND;
        FindClose(search);
        return 1;
    }
    HANDLE opened = CreateFileW(whole, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
    if (opened == INVALID_HANDLE_VALUE) return 0;
    CloseHandle(opened);
    return 1;
}

void *fr_smb_open(const char *server, const char *share, const char *path, const char *user, const char *password) { return NULL; }
long long fr_smb_read(void *file, char *buffer, unsigned long long count) { return -1; }
long long fr_smb_seek(void *file, long long offset) { return -1; }
long long fr_smb_size(void *file) { return -1; }
void fr_smb_close(void *file) {}

#elif defined(__linux__)
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

// (libsmbclient's own description of an entry in a folder.)
struct fr_smbc_dirent {
    unsigned int smbc_type;
    unsigned int dirlen;
    unsigned int commentlen;
    char *comment;
    unsigned int namelen;
    char name[1];
};

typedef void (*fr_auth_fn)(const char *, const char *, char *, int, char *, int, char *, int);
static pthread_mutex_t fr_smb_lock = PTHREAD_MUTEX_INITIALIZER;
static int fr_smb_state = 0;   // 0 not tried, 1 ready, -1 not there
static int (*fr_smbc_init)(fr_auth_fn, int);
static int (*fr_smbc_opendir)(const char *);
static struct fr_smbc_dirent *(*fr_smbc_readdir)(unsigned int);
static int (*fr_smbc_closedir)(int);
static int (*fr_smbc_open)(const char *, int, mode_t);
static ssize_t (*fr_smbc_read)(int, void *, size_t);
static off_t (*fr_smbc_lseek)(int, off_t, int);
static int (*fr_smbc_fstat)(int, struct stat *);
static int (*fr_smbc_close)(int);
static char fr_smb_user[256], fr_smb_password[256];

static void fr_smb_auth(const char *server, const char *share, char *workgroup, int workgroupRoom, char *user, int userRoom, char *password, int passwordRoom) {
    (void)server; (void)share; (void)workgroup; (void)workgroupRoom;
    snprintf(user, (size_t)userRoom, "%s", fr_smb_user);
    snprintf(password, (size_t)passwordRoom, "%s", fr_smb_password);
}

// (Called with the lock held.)
static int fr_smb_ready(void) {
    if (fr_smb_state != 0) return fr_smb_state == 1;
    fr_smb_state = -1;
    void *library = dlopen("libsmbclient.so.0", RTLD_NOW | RTLD_GLOBAL);
    if (!library) return 0;
    fr_smbc_init = (int (*)(fr_auth_fn, int))dlsym(library, "smbc_init");
    fr_smbc_opendir = (int (*)(const char *))dlsym(library, "smbc_opendir");
    fr_smbc_readdir = (struct fr_smbc_dirent *(*)(unsigned int))dlsym(library, "smbc_readdir");
    fr_smbc_closedir = (int (*)(int))dlsym(library, "smbc_closedir");
    fr_smbc_open = (int (*)(const char *, int, mode_t))dlsym(library, "smbc_open");
    fr_smbc_read = (ssize_t (*)(int, void *, size_t))dlsym(library, "smbc_read");
    fr_smbc_lseek = (off_t (*)(int, off_t, int))dlsym(library, "smbc_lseek");
    fr_smbc_fstat = (int (*)(int, struct stat *))dlsym(library, "smbc_fstat");
    fr_smbc_close = (int (*)(int))dlsym(library, "smbc_close");
    if (!fr_smbc_init || !fr_smbc_opendir || !fr_smbc_readdir || !fr_smbc_closedir || !fr_smbc_open || !fr_smbc_read || !fr_smbc_lseek || !fr_smbc_fstat || !fr_smbc_close) return 0;
    if (fr_smbc_init(fr_smb_auth, 0) < 0) return 0;
    fr_smb_state = 1;
    return 1;
}

// "smb://server/share/a%20folder/file": the names with what an address can't hold written as %XX.
static void fr_smb_address(char *out, size_t room, const char *server, const char *share, const char *path) {
    size_t used = (size_t)snprintf(out, room, "smb://%s", server);
    const char *parts[2] = {share, path};
    for (int part = 0; part < 2; part++) {
        if (!parts[part] || !parts[part][0]) continue;
        if (used + 2 < room) out[used++] = '/';
        for (const unsigned char *letter = (const unsigned char *)parts[part]; *letter && used + 4 < room; letter++) {
            if ((*letter >= 'A' && *letter <= 'Z') || (*letter >= 'a' && *letter <= 'z') || (*letter >= '0' && *letter <= '9') || strchr("-_.~/", *letter)) out[used++] = (char)*letter;
            else used += (size_t)snprintf(out + used, room - used, "%%%02X", *letter);
        }
    }
    out[used < room ? used : room - 1] = 0;
}

static void fr_smb_sign_in(const char *user, const char *password) {
    snprintf(fr_smb_user, sizeof(fr_smb_user), "%s", user ? user : "");
    snprintf(fr_smb_password, sizeof(fr_smb_password), "%s", password ? password : "");
}

int fr_smb_available(void) {
    pthread_mutex_lock(&fr_smb_lock);
    int ready = fr_smb_ready();
    pthread_mutex_unlock(&fr_smb_lock);
    return ready;
}

int fr_smb_connect(const char *server, const char *share, const char *user, const char *password) {
    (void)server; (void)share; (void)user; (void)password;
    return 0;
}

int fr_smb_list(const char *server, const char *share, const char *path, const char *user, const char *password, char *out, int capacity) {
    int used = 0, count = 0;
    out[0] = 0;
    pthread_mutex_lock(&fr_smb_lock);
    if (!fr_smb_ready()) {
        pthread_mutex_unlock(&fr_smb_lock);
        return -3;
    }
    fr_smb_sign_in(user, password);
    char address[4096];
    fr_smb_address(address, sizeof(address), server, share, path);
    int folder = fr_smbc_opendir(address);
    if (folder < 0) {
        int why = errno;
        pthread_mutex_unlock(&fr_smb_lock);
        return (why == EACCES || why == EPERM) ? -2 : -1;
    }
    struct fr_smbc_dirent *entry;
    while ((entry = fr_smbc_readdir((unsigned int)folder)) != NULL) {
        if (strcmp(entry->name, ".") == 0 || strcmp(entry->name, "..") == 0) continue;
        size_t length = strlen(entry->name);
        if (entry->smbc_type == 3) {            // a share of files
            if (length == 0 || entry->name[length - 1] == '$') continue;
            if (fr_add_line(out, capacity, &used, 'd', entry->name)) count++;
        } else if (entry->smbc_type == 7) {     // a folder
            if (fr_add_line(out, capacity, &used, 'd', entry->name)) count++;
        } else if (entry->smbc_type == 8) {     // a file
            if (entry->name[0] == '.') continue;
            if (fr_add_line(out, capacity, &used, 'f', entry->name)) count++;
        }
    }
    fr_smbc_closedir(folder);
    pthread_mutex_unlock(&fr_smb_lock);
    return count;
}

// Whether a file or a folder of a share opens: a computer lists things it then keeps to
// itself, and pointers to files it holds somewhere else.
int fr_smb_reachable(const char *server, const char *share, const char *path, int isFolder, const char *user, const char *password) {
    int reached = 0;
    pthread_mutex_lock(&fr_smb_lock);
    if (fr_smb_ready()) {
        fr_smb_sign_in(user, password);
        char address[4096];
        fr_smb_address(address, sizeof(address), server, share, path);
        if (isFolder) {
            int folder = fr_smbc_opendir(address);
            if (folder >= 0) {
                fr_smbc_closedir(folder);
                reached = 1;
            }
        } else {
            int descriptor = fr_smbc_open(address, O_RDONLY, 0);
            if (descriptor >= 0) {
                fr_smbc_close(descriptor);
                reached = 1;
            }
        }
    }
    pthread_mutex_unlock(&fr_smb_lock);
    return reached;
}

struct fr_smb_file {
    int descriptor;
    long long size;
};

void *fr_smb_open(const char *server, const char *share, const char *path, const char *user, const char *password) {
    pthread_mutex_lock(&fr_smb_lock);
    struct fr_smb_file *file = NULL;
    if (fr_smb_ready()) {
        fr_smb_sign_in(user, password);
        char address[4096];
        fr_smb_address(address, sizeof(address), server, share, path);
        int descriptor = fr_smbc_open(address, O_RDONLY, 0);
        if (descriptor >= 0) {
            file = calloc(1, sizeof(*file));
            file->descriptor = descriptor;
            struct stat about;
            file->size = fr_smbc_fstat(descriptor, &about) == 0 ? (long long)about.st_size : -1;
        }
    }
    pthread_mutex_unlock(&fr_smb_lock);
    return file;
}

long long fr_smb_read(void *opened, char *buffer, unsigned long long count) {
    struct fr_smb_file *file = opened;
    if (count > (1 << 20)) count = 1 << 20;
    pthread_mutex_lock(&fr_smb_lock);
    long long got = (long long)fr_smbc_read(file->descriptor, buffer, (size_t)count);
    pthread_mutex_unlock(&fr_smb_lock);
    return got;
}

long long fr_smb_seek(void *opened, long long offset) {
    struct fr_smb_file *file = opened;
    pthread_mutex_lock(&fr_smb_lock);
    long long place = (long long)fr_smbc_lseek(file->descriptor, (off_t)offset, SEEK_SET);
    pthread_mutex_unlock(&fr_smb_lock);
    return place;
}

long long fr_smb_size(void *opened) {
    return ((struct fr_smb_file *)opened)->size;
}

void fr_smb_close(void *opened) {
    struct fr_smb_file *file = opened;
    pthread_mutex_lock(&fr_smb_lock);
    fr_smbc_close(file->descriptor);
    pthread_mutex_unlock(&fr_smb_lock);
    free(file);
}

#else
int fr_smb_available(void) { return 0; }
int fr_smb_connect(const char *server, const char *share, const char *user, const char *password) { return -1; }
int fr_smb_list(const char *server, const char *share, const char *path, const char *user, const char *password, char *out, int capacity) { return -3; }
int fr_smb_reachable(const char *server, const char *share, const char *path, int isFolder, const char *user, const char *password) { return 0; }
void *fr_smb_open(const char *server, const char *share, const char *path, const char *user, const char *password) { return NULL; }
long long fr_smb_read(void *file, char *buffer, unsigned long long count) { return -1; }
long long fr_smb_seek(void *file, long long offset) { return -1; }
long long fr_smb_size(void *file) { return -1; }
void fr_smb_close(void *file) {}
#endif
