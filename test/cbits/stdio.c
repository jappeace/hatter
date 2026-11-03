/* C's stderr, for the tests that capture what the bridges' stubs print. */

#include <stdio.h>

/* Clears a failed write's mark on C's stderr: macOS's stdio drops all
 * that's printed after one, until cleared, and there a write from another
 * thread fails while dup2 swaps fd 2. */
void hatter_test_clear_stderr_error(void)
{
    clearerr(stderr);
}
