/* sp_terp_entry.h -- how the iOS app starts an interpreter.
 *
 * On macOS every interpreter is a separate process that talks to the app over
 * its stdin and stdout. iOS does not let an app spawn processes, so each
 * interpreter is built as a framework and run on a thread of the app itself.
 * This file is compiled into every one of those frameworks. */

#ifndef SP_TERP_ENTRY_H
#define SP_TERP_ENTRY_H

#ifdef __cplusplus
extern "C" {
#endif

/* Run the interpreter to completion on the calling thread. argv[0] is the
 * interpreter's name, the rest are what its command line would have been.
 * The interpreter reads the app's events from read_fd and writes its requests
 * to write_fd (see glkimp/protocol.h). Returns what the interpreter would have
 * passed to exit(). */
__attribute__((visibility("default")))
int sp_terp_run(int argc, char **argv, int read_fd, int write_fd);

/* Put the interpreter and the Glk library back as they were when the
 * framework was loaded: zeroed globals, initial values, static constructors
 * run again. Needed to play a second game after the first. Frameworks that
 * contain Objective-C cannot be unloaded and loaded again, so this restores
 * the writable data instead. Must not be called while sp_terp_run is running.
 * (Memory the first game allocated is not given back.) */
__attribute__((visibility("default")))
void sp_terp_reset_state(void);

/* Replaces exit() inside the interpreter and the Glk library (the frameworks
 * are built with -Dexit=sp_terp_exit). On the interpreter thread it unwinds
 * back to sp_terp_run; anywhere else it is a plain exit(). */
void sp_terp_exit(int status) __attribute__((noreturn));

#ifdef __cplusplus
}
#endif

#endif
