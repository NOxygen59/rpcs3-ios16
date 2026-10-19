// The RPCS3 core's C API (rpcs3/ios/RPCS3IOS.h of XITRIX/rpcs3, branch ios-port, ABI 30), and the
// one private libSystem call the app needs: whether a debugger enabled JIT (CS_DEBUGGED).
#include "RPCS3IOS.h"
#include <sys/types.h>
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
