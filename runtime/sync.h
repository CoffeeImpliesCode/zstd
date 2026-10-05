/* SPDX-License-Identifier: MIT
 *
 * Process-global mutex, wake-up and thread identity for the loader.
 * Each SDK supplies RT_SYNC_PREFIX to keep its synchronization symbols distinct.
 */

#ifndef ZSTD_RUNTIME_SYNC_H
#define ZSTD_RUNTIME_SYNC_H

#if !defined(RT_SYNC_PREFIX)
#error "RT_SYNC_PREFIX must be defined before this header is used; runtime/graph.zig passes it."
#endif

/* Token pasting, so a prefix becomes part of the symbol name rather than part
 * of a string. */
#define RT_JOIN_INNER(a, b) a##b
#define RT_JOIN(a, b) RT_JOIN_INNER(a, b)
#define RT_FN(name) RT_JOIN(RT_SYNC_PREFIX, RT_JOIN(_, name))

/* Exclude the lock. Called by the thread that owns the loader state. */
void RT_FN(lock)(void);

/* Release the lock. */
void RT_FN(unlock)(void);

/* Release the lock, block until a broadcast arrives, and take the lock again.
 * Every caller must re-test its predicate in a loop. */
void RT_FN(wait)(void);

/* Wake every waiter. */
void RT_FN(broadcast)(void);

/* An identifier for the calling thread. Never zero, distinct between threads
 * that are alive at the same time, and equal for a thread compared with
 * itself. The loader stores it while a load attempt is in flight so it can
 * tell a reentrant call on that same thread from a contending call on another
 * one. */
unsigned long long RT_FN(thread_self)(void);

#endif /* ZSTD_RUNTIME_SYNC_H */