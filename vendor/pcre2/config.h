/* GraphQLite's portable, static 8-bit PCRE2 configuration.
 * Defaults come from the unmodified upstream generic configuration. */
#define SUPPORT_PCRE2_8 1
#define SUPPORT_UNICODE 1
#define PCRE2_STATIC 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_LIMITS_H 1
#define HAVE_ASSERT_H 1
#define HAVE_MEMMOVE 1
#define HEAP_LIMIT 65536
/* No JIT: no executable allocations or architecture-specific dependency. */
#include "config.h.generic"
