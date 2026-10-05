/* SPDX-License-Identifier: MIT
 *
 * One statically initialized mutex and condition variable per RT_SYNC_PREFIX.
 * Weak definitions let repeated imports share that prefix's synchronization.
 */

#include "sync.h"

#if defined(__GNUC__) || defined(__clang__)
#define RT_WEAK __attribute__((weak))
#else
#define RT_WEAK
#endif

#if defined(_WIN32)

#include <windows.h>

static SRWLOCK rt_sync_lock_object = SRWLOCK_INIT;
static CONDITION_VARIABLE rt_sync_cond_object = CONDITION_VARIABLE_INIT;

RT_WEAK void RT_FN(lock)(void) { AcquireSRWLockExclusive(&rt_sync_lock_object); }

RT_WEAK void RT_FN(unlock)(void) { ReleaseSRWLockExclusive(&rt_sync_lock_object); }

RT_WEAK void RT_FN(wait)(void) {
  SleepConditionVariableSRW(&rt_sync_cond_object, &rt_sync_lock_object, INFINITE, 0);
}

RT_WEAK void RT_FN(broadcast)(void) { WakeAllConditionVariable(&rt_sync_cond_object); }

RT_WEAK unsigned long long RT_FN(thread_self)(void) {
  return (unsigned long long)GetCurrentThreadId();
}

#elif defined(__wasi__) || defined(__EMSCRIPTEN__)

RT_WEAK void RT_FN(lock)(void) {}

RT_WEAK void RT_FN(unlock)(void) {}

RT_WEAK void RT_FN(wait)(void) {}

RT_WEAK void RT_FN(broadcast)(void) {}

/* One constant, because one thread is all this backend has. It is non-zero so
 * the loader can still tell "a load is in flight on this thread" from "no load
 * is in flight". */
RT_WEAK unsigned long long RT_FN(thread_self)(void) { return 1ULL; }

#else

#include <pthread.h>

static pthread_mutex_t rt_sync_lock_object = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t rt_sync_cond_object = PTHREAD_COND_INITIALIZER;

RT_WEAK void RT_FN(lock)(void) { pthread_mutex_lock(&rt_sync_lock_object); }

RT_WEAK void RT_FN(unlock)(void) { pthread_mutex_unlock(&rt_sync_lock_object); }

RT_WEAK void RT_FN(wait)(void) {
  pthread_cond_wait(&rt_sync_cond_object, &rt_sync_lock_object);
}

RT_WEAK void RT_FN(broadcast)(void) { pthread_cond_broadcast(&rt_sync_cond_object); }

RT_WEAK unsigned long long RT_FN(thread_self)(void) {
  return (unsigned long long)pthread_self();
}

#endif