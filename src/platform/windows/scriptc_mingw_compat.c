/* MinGW startup and CRT pieces for scriptc's Windows runtime on MSVC targets.
 *
 * The pinned scriptc builds its Windows runtime pack against Zig's MinGW
 * sysroot (packages/runtime-win32-x64-msvc/scripts/build.mjs passes
 * -target x86_64-windows-gnu). The runtime is already Win32-native for
 * threads, child processes and its event loop; what remains is what MinGW
 * layers over the UCRT. The MSVC build links the same UCRT statically, so
 * this file restates exactly that, with the MinGW behaviour the runtime was
 * compiled against: running its .ctors constructors, the dllimport slots for
 * UCRT functions, stat64i32, the ___chkstk_ms stack probe, and <dirent.h>.
 * POSIX names such as open/read/close come from MSVC's oldnames.lib instead.
 *
 * Delete this file once scriptc ships a runtime pack built for the MSVC CRT.
 */

/* The import slots below only take the address of the UCRT's "insecure"
 * functions (_wfopen, _wopen); nothing here calls them. */
#define _CRT_SECURE_NO_WARNINGS

#include <ctype.h>
#include <errno.h>
#include <io.h>
#include <process.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/utime.h>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* clang places a MinGW object's __attribute__((constructor)) functions in
 * .ctors, which only MinGW's startup runs; the MSVC CRT runs .CRT$XCU. The
 * runtime initializes state that way (scr_json.c's small-int table, for one),
 * so walk this image's .ctors from a .CRT$XCU initializer, back to front as
 * MinGW's __do_global_ctors does, skipping its 0/-1 list markers. */
typedef void (*scriptc_ctor_fn)(void);
extern IMAGE_DOS_HEADER __ImageBase;

static void __cdecl scriptc_run_mingw_ctors(void) {
  const char *base = (const char *)&__ImageBase;
  const IMAGE_NT_HEADERS *nt = (const IMAGE_NT_HEADERS *)(base + __ImageBase.e_lfanew);
  const IMAGE_SECTION_HEADER *section = IMAGE_FIRST_SECTION(nt);
  for (WORD index = 0; index < nt->FileHeader.NumberOfSections; index++, section++) {
    if (memcmp(section->Name, ".ctors\0\0", IMAGE_SIZEOF_SHORT_NAME) != 0) continue;
    scriptc_ctor_fn *begin = (scriptc_ctor_fn *)(base + section->VirtualAddress);
    scriptc_ctor_fn *end = begin + section->Misc.VirtualSize / sizeof(scriptc_ctor_fn);
    while (end > begin) {
      scriptc_ctor_fn ctor = *--end;
      if (ctor && ctor != (scriptc_ctor_fn)(intptr_t)-1) ctor();
    }
  }
}

__attribute__((section(".CRT$XCU"), used)) static void(__cdecl *const scriptc_mingw_ctors)(void) =
    scriptc_run_mingw_ctors;

/* MinGW's headers declare UCRT functions dllimport, so the runtime calls them
 * through __imp_ slots that the static UCRT does not define. lld would bind
 * most of them to the static definitions anyway, but with one LNK4217 warning
 * each (and tolower not at all), so define every slot the runtime pack's
 * library objects reference. A slot added by a future pack shows up as an
 * undefined symbol or a new LNK4217 warning in the MSVC link. */
#define SCRIPTC_UCRT_IMPORT(name) __typeof__(&name) const __imp_##name = &name;
/* The UCRT exports _assert, but its <assert.h> declares only _wassert. */
void __cdecl _assert(const char *message, const char *file, unsigned line);
SCRIPTC_UCRT_IMPORT(__acrt_iob_func)
SCRIPTC_UCRT_IMPORT(_assert)
SCRIPTC_UCRT_IMPORT(_chsize_s)
SCRIPTC_UCRT_IMPORT(_commit)
SCRIPTC_UCRT_IMPORT(_errno)
SCRIPTC_UCRT_IMPORT(_fstat64)
SCRIPTC_UCRT_IMPORT(_fullpath)
SCRIPTC_UCRT_IMPORT(_get_osfhandle)
SCRIPTC_UCRT_IMPORT(_getpid)
SCRIPTC_UCRT_IMPORT(_stricmp)
SCRIPTC_UCRT_IMPORT(_umask_s)
SCRIPTC_UCRT_IMPORT(_utime64)
SCRIPTC_UCRT_IMPORT(_wfopen)
SCRIPTC_UCRT_IMPORT(_wopen)
SCRIPTC_UCRT_IMPORT(tolower)

/* MinGW-UCRT aliases stat64i32 to the UCRT's _stat64i32. */
int __cdecl stat64i32(const char *path, struct _stat64i32 *buf) {
  return _stat64i32(path, buf);
}

/* MinGW's stack probe: rax holds the frame size; touch every page below the
 * caller's stack pointer without moving it, preserving all registers. */
__attribute__((naked)) void ___chkstk_ms(void) {
  __asm__ volatile(
      "pushq %rcx\n\t"
      "pushq %rax\n\t"
      "cmpq $0x1000, %rax\n\t"
      "leaq 24(%rsp), %rcx\n\t"
      "jb 1f\n"
      "2:\n\t"
      "subq $0x1000, %rcx\n\t"
      "testq %rcx, (%rcx)\n\t"
      "subq $0x1000, %rax\n\t"
      "cmpq $0x1000, %rax\n\t"
      "ja 2b\n"
      "1:\n\t"
      "subq %rax, %rcx\n\t"
      "testq %rcx, (%rcx)\n\t"
      "popq %rax\n\t"
      "popq %rcx\n\t"
      "retq");
}

/* <dirent.h>, ported from mingw-w64's public-domain misc/dirent.c (char
 * variant). struct dirent and DIR keep mingw-w64's layout because the
 * runtime was compiled against its header. */

struct dirent {
  long d_ino;
  unsigned short d_reclen;
  unsigned short d_namlen;
  char d_name[260];
};

typedef struct {
  struct _finddata_t dd_dta;
  struct dirent dd_dir;
  intptr_t dd_handle;
  int dd_stat;
  char dd_name[1];
} DIR;

DIR *__cdecl opendir(const char *path) {
  errno = 0;
  if (!path) {
    errno = EFAULT;
    return NULL;
  }
  if (path[0] == '\0') {
    errno = ENOTDIR;
    return NULL;
  }
  DWORD attributes = GetFileAttributesA(path);
  if (attributes == INVALID_FILE_ATTRIBUTES) {
    errno = ENOENT;
    return NULL;
  }
  if (!(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
    errno = ENOTDIR;
    return NULL;
  }
  char full[MAX_PATH];
  if (!_fullpath(full, path, MAX_PATH)) return NULL;
  size_t len = strlen(full);
  /* The search pattern: the absolute path, a separator, "*", and NUL. */
  DIR *dir = malloc(sizeof(DIR) + len + 3);
  if (!dir) {
    errno = ENOMEM;
    return NULL;
  }
  memcpy(dir->dd_name, full, len);
  if (len > 0 && full[len - 1] != '/' && full[len - 1] != '\\') dir->dd_name[len++] = '\\';
  dir->dd_name[len++] = '*';
  dir->dd_name[len] = '\0';
  dir->dd_handle = -1;
  dir->dd_stat = 0;
  dir->dd_dir.d_ino = 0;
  dir->dd_dir.d_reclen = 0;
  dir->dd_dir.d_namlen = 0;
  memset(dir->dd_dir.d_name, 0, sizeof(dir->dd_dir.d_name));
  return dir;
}

struct dirent *__cdecl readdir(DIR *dir) {
  errno = 0;
  if (!dir) {
    errno = EFAULT;
    return NULL;
  }
  if (dir->dd_stat < 0) return NULL;
  if (dir->dd_stat == 0) {
    dir->dd_handle = _findfirst(dir->dd_name, &dir->dd_dta);
    dir->dd_stat = dir->dd_handle == -1 ? -1 : 1;
  } else if (_findnext(dir->dd_handle, &dir->dd_dta)) {
    /* _findnext reports the end as ENOENT; the end is not an error. */
    if (GetLastError() == ERROR_NO_MORE_FILES) errno = 0;
    _findclose(dir->dd_handle);
    dir->dd_handle = -1;
    dir->dd_stat = -1;
  } else {
    dir->dd_stat++;
  }
  if (dir->dd_stat <= 0) return NULL;
  /* Both buffers are MAX_PATH chars, so the name and its NUL always fit. */
  size_t len = strlen(dir->dd_dta.name);
  dir->dd_dir.d_namlen = (unsigned short)len;
  memcpy(dir->dd_dir.d_name, dir->dd_dta.name, len + 1);
  return &dir->dd_dir;
}

int __cdecl closedir(DIR *dir) {
  errno = 0;
  if (!dir) {
    errno = EFAULT;
    return -1;
  }
  int rc = dir->dd_handle != -1 ? _findclose(dir->dd_handle) : 0;
  free(dir);
  return rc;
}

void __cdecl rewinddir(DIR *dir) {
  errno = 0;
  if (!dir) {
    errno = EFAULT;
    return;
  }
  if (dir->dd_handle != -1) _findclose(dir->dd_handle);
  dir->dd_handle = -1;
  dir->dd_stat = 0;
}

long __cdecl telldir(DIR *dir) {
  errno = 0;
  if (!dir) {
    errno = EFAULT;
    return -1;
  }
  return dir->dd_stat;
}

void __cdecl seekdir(DIR *dir, long position) {
  errno = 0;
  if (!dir) {
    errno = EFAULT;
    return;
  }
  if (position < -1) {
    errno = EINVAL;
  } else if (position == -1) {
    if (dir->dd_handle != -1) _findclose(dir->dd_handle);
    dir->dd_handle = -1;
    dir->dd_stat = -1;
  } else {
    rewinddir(dir);
    while (dir->dd_stat < position && readdir(dir)) {
    }
  }
}
