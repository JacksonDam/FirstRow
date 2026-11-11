#include "CPortable.h"

#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

/* Font files are mapped into memory, not read into it. plutovg's own loader reads the whole file for each
   face, and to find fonts by name every face on the machine is looked at: read in, that was hundreds of
   megabytes on Windows and more than a gigabyte on a Linux desktop with the Noto CJK fonts. Mapped, only the
   parts that are looked at come into memory, and they stay the system's to take back. */

typedef struct {
    void* base;
    size_t length;
} fr_font_mapping;

static fr_font_mapping* fr_font_map(const char* path)
{
    void* base = NULL;
    size_t length = 0;
#ifdef _WIN32
    wchar_t wide[1024];
    if(MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, 1024) == 0)
        return NULL;
    HANDLE file = CreateFileW(wide, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if(file == INVALID_HANDLE_VALUE)
        return NULL;
    LARGE_INTEGER size;
    if(!GetFileSizeEx(file, &size) || size.QuadPart <= 0 || size.QuadPart > 0x7fffffff) {
        CloseHandle(file);
        return NULL;
    }
    HANDLE mapping = CreateFileMappingW(file, NULL, PAGE_READONLY, 0, 0, NULL);
    CloseHandle(file);
    if(mapping == NULL)
        return NULL;
    base = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0);
    CloseHandle(mapping);
    if(base == NULL)
        return NULL;
    length = (size_t)size.QuadPart;
#else
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if(fd < 0)
        return NULL;
    struct stat info;
    if(fstat(fd, &info) != 0 || info.st_size <= 0 || info.st_size > 0x7fffffff) {
        close(fd);
        return NULL;
    }
    length = (size_t)info.st_size;
    base = mmap(NULL, length, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if(base == MAP_FAILED)
        return NULL;
#endif
    fr_font_mapping* mapped = malloc(sizeof(fr_font_mapping));
    mapped->base = base;
    mapped->length = length;
    return mapped;
}

static void fr_font_unmap(void* closure)
{
    fr_font_mapping* mapped = closure;
#ifdef _WIN32
    UnmapViewOfFile(mapped->base);
#else
    munmap(mapped->base, mapped->length);
#endif
    free(mapped);
}

static uint32_t fr_be32(const unsigned char* p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint32_t fr_be16(const unsigned char* p)
{
    return ((uint32_t)p[0] << 8) | (uint32_t)p[1];
}

/* Whether a face's table directory, every table it lists and every string of its name table lie inside the
   file. The font code trusts the offsets it reads: in a file cut short they point past the end, and past the
   end of a mapped file there is nothing to read. */
static int fr_font_fits(const unsigned char* data, size_t length, int index)
{
    size_t start = 0;
    if(length < 12)
        return 0;
    if(memcmp(data, "ttcf", 4) == 0) {
        uint32_t count = fr_be32(data + 8);
        if(index < 0 || (uint32_t)index >= count || (length - 12) / 4 < count)
            return 0;
        start = fr_be32(data + 12 + 4 * (size_t)index);
    } else if(index != 0) {
        return 0;
    }
    if(start > length || length - start < 12)
        return 0;
    uint32_t tables = fr_be16(data + start + 4);
    if((length - start - 12) / 16 < tables)
        return 0;
    for(uint32_t i = 0; i < tables; i++) {
        const unsigned char* record = data + start + 12 + 16 * (size_t)i;
        uint32_t offset = fr_be32(record + 8);
        uint32_t size = fr_be32(record + 12);
        if(offset > length || size > length - offset)
            return 0;
        if(memcmp(record, "name", 4) == 0) {
            const unsigned char* name = data + offset;
            if(size < 6)
                return 0;
            uint32_t count = fr_be16(name + 2);
            uint32_t strings = fr_be16(name + 4);
            if((size - 6) / 12 < count || strings > size)
                return 0;
            for(uint32_t n = 0; n < count; n++) {
                const unsigned char* entry = name + 6 + 12 * (size_t)n;
                if(fr_be16(entry + 8) + fr_be16(entry + 10) > size - strings)
                    return 0;
            }
        }
    }
    return 1;
}

plutovg_font_face_t* fr_font_face_load_mapped(const char* path, int index)
{
    fr_font_mapping* mapped = fr_font_map(path);
    if(mapped == NULL)
        return NULL;
    if(!fr_font_fits(mapped->base, mapped->length, index)) {
        fr_font_unmap(mapped);
        return NULL;
    }
    /* (The face unmaps the file when it's destroyed, or now if it can't be made.) */
    return plutovg_font_face_load_from_data(mapped->base, (unsigned int)mapped->length, index, fr_font_unmap, mapped);
}

int fr_font_file_face_count(const char* path)
{
    fr_font_mapping* mapped = fr_font_map(path);
    if(mapped == NULL)
        return 0;
    int count = mapped->length >= 12 ? plutovg_font_data_face_count(mapped->base) : 0;
    fr_font_unmap(mapped);
    return count;
}
