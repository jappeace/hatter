/*
 * Stubs for symbols that GHC RTS expects but Android bionic libc lacks.
 * Only compiled in on Android builds; the #ifdef makes this a no-op
 * on regular (glibc/musl) builds.
 *
 * Add more stubs here as link errors reveal missing symbols.
 */

#ifdef __ANDROID__

/* GHC's RTS uses these internally via libc wrappers that bionic omits */
void __svfscanf(void) {}
void __vfwscanf(void) {}

#endif
