/* The one header this package translates.
 *
 * `zig build` runs translate-c over this file, and what that translation
 * becomes is the `c` module the Zig facade in zig/root.zig imports.  Its whole
 * job is to name the public headers of the library this build compiles.
 *
 * Which headers those are
 * -----------------------
 * Zstandard installs three public headers, and this file names all three:
 *
 *   zstd.h          the frame, one-shot, simple and advanced streaming API.
 *                   It includes upstream's own zstd_errors.h itself
 *                   (`src/lib/zstd.h:18`), so the whole error-code namespace
 *                   reaches the translation by including zstd.h, exactly as
 *                   every C consumer gets it.
 *   zdict.h         the dictionary builder, `ZDICT_*`. It includes only
 *                   `<stddef.h>` (`src/lib/zdict.h:16`), so it adds nothing
 *                   that is not already reachable.
 *   zstd_errors.h   the pinned `ZSTD_ErrorCode` values and
 *                   `ZSTD_getErrorString`. Included separately as well as
 *                   through zstd.h, because its own guard makes the second
 *                   include a no-op and because a build that adds the error
 *                   header to a consumer's include line should not have to
 *                   know that zstd.h already pulls it in.
 *
 * All three are included whole, with their own include guards, so this wrapper
 * cannot disagree with the real headers by omission and cannot re-declare a
 * prototype with a different type.
 *
 * Why the search path is src/lib and not src
 * ------------------------------------------
 * Every internal include in this tree is quoted and relative to the directory
 * it sits in - `zstd_compress.c` reaches `../common/zstd_internal.h` that way,
 * `zstd.h` reaches `"zstd_errors.h"` that way - so one `-I src/lib` is what
 * keeps all of `src/lib/` resolvable, and it is the directory the three public
 * headers are in.  `src/` itself is *not* on the translation's include path:
 * nothing in the closure needs it, and adding it would let a future
 * `zig/translate.h` reach a header that no C consumer of this installed tree
 * would find.  build.zig gives `src/lib` to the library's own C compilation, to
 * this translation and to the module a dependent imports, which is what keeps
 * the declarations the facade was typed against and the ones the archive was
 * compiled from the same bytes.
 *
 * What is deliberately not here
 * -----------------------------
 * A copy of any declaration, and no macro of this build's own except the
 * include guard below.
 *
 * `ZSTD_STATIC_LINKING_ONLY` is the macro that matters, and it is on the
 * compile line rather than in this header.  It is what makes upstream's
 * experimental surface visible at all: without it `ZSTD_frameHeaderSize`
 * (`src/lib/zstd.h:1508`) and `ZSTD_CCtx_getParameter`
 * (`src/lib/zstd.h:2364`) are not declared, because both are spelled
 * `ZSTDLIB_STATIC_API` rather than `ZSTDLIB_API`, and the facade has to wrap
 * both.  `build.zig` defines it once for the library's own compilation and for
 * this translation alike, so the declarations below and the code that
 * implements them cannot be built for two different configurations.
 *
 * It is deliberately *not* something a dependent has to repeat.  The module
 * this translation becomes already carries the declarations, and the header is
 * reached through `dep.module("zstd").c`, so a Zig dependent names
 * `ZSTD_CCtx_setParameter` through the facade and never sees a macro.  A C
 * consumer of the *installed* tree is the one place the macro would matter, and
 * it has two honest answers: either it uses only the stable `ZSTDLIB_API`
 * surface, or it defines `ZSTD_STATIC_LINKING_ONLY` itself, which
 * `src/lib/zstd.h:104-109` is written to support and which upstream states is
 * for static linking only.  Putting it in this header would force it on every
 * dependent of this package, including ones that only want
 * `ZSTD_compress`, and that is a policy decision rather than a fact about the
 * interface.
 *
 * The other macros on the compile line - `XXH_NAMESPACE=ZSTD_` and
 * `DEBUGLEVEL=0` (`src/lib/libzstd.mk:109`), `ZSTD_LEGACY_SUPPORT=5`
 * (`src/lib/libzstd.mk:207`) and `DYNAMIC_BMI2` where a target needs it - are
 * upstream's own defaults for this build, not something this header has to
 * say.  All of them select branches inside upstream's `.c` units; none of them
 * reaches a declaration in a header, so none of them can make this translation
 * and the compiled archive disagree about a type.
 */

#ifndef ZSTD_TRANSLATE_H
#define ZSTD_TRANSLATE_H

#include <zstd.h>
#include <zdict.h>
#include <zstd_errors.h>

#endif /* ZSTD_TRANSLATE_H */