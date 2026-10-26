/* sp_terp_entry.c -- see sp_terp_entry.h. */

/* This file is built with exit() redirected to sp_terp_exit like the rest of
 * the framework, but here we do mean the real one. */
#include <stdlib.h>
#undef exit
extern void exit(int) __attribute__((noreturn));

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "sp_terp_entry.h"

/* glkimp/main.c, whose main() is renamed for the iOS build */
extern int spatterlight_terp_main(int argc, char **argv);
/* glkimp/connect.c */
extern void gli_set_pipe_fds(int read_fd, int send_fd);

/* Our own state lives in a section the snapshot below leaves alone. */
#define KEEP __attribute__((section("__DATA,__sp_keep")))

static KEEP pthread_t terp_thread;
static KEEP volatile int terp_thread_valid = 0;
static KEEP jmp_buf terp_exit_jump;
static KEEP volatile int terp_exit_status = 0;

int sp_terp_run(int argc, char **argv, int read_fd, int write_fd)
{
    int status;

    terp_thread = pthread_self();
    terp_thread_valid = 1;
    terp_exit_status = 0;

    gli_set_pipe_fds(read_fd, write_fd);

    if (setjmp(terp_exit_jump) == 0)
        status = spatterlight_terp_main(argc, argv);
    else
        status = terp_exit_status;

    terp_thread_valid = 0;

    /* Whatever the interpreter did, make sure the app sees end of file. */
    close(read_fd);
    close(write_fd);
    return status;
}

void sp_terp_exit(int status)
{
    if (terp_thread_valid && pthread_equal(pthread_self(), terp_thread)) {
        terp_exit_status = status;
        longjmp(terp_exit_jump, 1);
    }
    exit(status);
}

/* ---- Resetting the interpreter between games ------------------------------ */

typedef struct {
    uint8_t *address;
    size_t size;
    uint8_t *copy;
} region_t;

#define MAX_REGIONS 16

static KEEP region_t regions[MAX_REGIONS];
static KEEP int region_count = 0;
static KEEP int snapshot_taken = 0;
static KEEP const struct mach_header_64 *image_header = NULL;

static void note_region(const struct mach_header_64 *mh, intptr_t slide,
                        const struct section_64 *sect)
{
    if (region_count >= MAX_REGIONS || sect->size == 0)
        return;
    region_t *r = &regions[region_count++];
    r->address = (uint8_t *)(uintptr_t)(sect->addr + slide);
    r->size = (size_t)sect->size;
    r->copy = malloc(r->size);
    memcpy(r->copy, r->address, r->size);
}

/* Runs before any other initializer of the framework (see -init in the
 * target's linker flags), so the snapshot is of the data as the program
 * starts, before the C++ static constructors have built anything. */
__attribute__((visibility("default")))
void sp_terp_early_init(void)
{
    if (snapshot_taken)
        return;
    snapshot_taken = 1;

    Dl_info info;
    if (!dladdr((void *)sp_terp_early_init, &info))
        return;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)info.dli_fbase;
    image_header = mh;

    intptr_t slide = 0;
    const uint8_t *cmd = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, cmd += ((const struct load_command *)cmd)->cmdsize) {
        const struct load_command *lc = (const struct load_command *)cmd;
        if (lc->cmd != LC_SEGMENT_64)
            continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        if (strcmp(seg->segname, "__TEXT") == 0)
            slide = (intptr_t)mh - (intptr_t)seg->vmaddr;
    }

    cmd = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, cmd += ((const struct load_command *)cmd)->cmdsize) {
        const struct load_command *lc = (const struct load_command *)cmd;
        if (lc->cmd != LC_SEGMENT_64)
            continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        if (strcmp(seg->segname, "__DATA") != 0)
            continue;
        const struct section_64 *sect = (const struct section_64 *)(seg + 1);
        for (uint32_t j = 0; j < seg->nsects; j++, sect++) {
            if (strcmp(sect->sectname, "__data") == 0 ||
                strcmp(sect->sectname, "__bss") == 0 ||
                strcmp(sect->sectname, "__common") == 0)
                note_region(mh, slide, sect);
        }
    }
}

typedef void (*initializer_t)(int, const char **, const char **, const char **, void *);

void sp_terp_reset_state(void)
{
    if (!snapshot_taken || !image_header)
        return;

    for (int i = 0; i < region_count; i++)
        memcpy(regions[i].address, regions[i].copy, regions[i].size);

    /* The static constructors have to run again over the restored data. */
    const struct mach_header_64 *mh = image_header;
    unsigned long size = 0;

    /* Older style: a table of function pointers. */
    uint8_t *table = getsectiondata(mh, "__DATA_CONST", "__mod_init_func", &size);
    if (!table)
        table = getsectiondata(mh, "__DATA", "__mod_init_func", &size);
    if (table) {
        initializer_t *fns = (initializer_t *)table;
        for (unsigned long i = 0; i < size / sizeof(initializer_t); i++)
            fns[i](0, NULL, NULL, NULL, NULL);
    }

    /* Newer style: 32-bit offsets from the start of the image. */
    uint8_t *offsets = getsectiondata(mh, "__TEXT", "__init_offsets", &size);
    if (offsets) {
        uint32_t *offs = (uint32_t *)offsets;
        for (unsigned long i = 0; i < size / sizeof(uint32_t); i++) {
            initializer_t fn = (initializer_t)((uintptr_t)mh + offs[i]);
            fn(0, NULL, NULL, NULL, NULL);
        }
    }
}
