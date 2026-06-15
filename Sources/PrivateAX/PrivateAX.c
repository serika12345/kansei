#include "PrivateAX.h"

#include <dlfcn.h>

typedef AXError (*AXUIElementGetWindowFn)(AXUIElementRef ref, CGWindowID *windowID);

static AXUIElementGetWindowFn resolvedAXUIElementGetWindow(void)
{
    static AXUIElementGetWindowFn fn = NULL;
    static bool didResolve = false;

    if (didResolve) {
        return fn;
    }

    didResolve = true;

    fn = (AXUIElementGetWindowFn)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    if (fn) {
        return fn;
    }

    const char *candidates[] = {
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        NULL,
    };

    for (int i = 0; candidates[i] != NULL && fn == NULL; ++i) {
        void *handle = dlopen(candidates[i], RTLD_LAZY | RTLD_LOCAL);
        if (handle) {
            fn = (AXUIElementGetWindowFn)dlsym(handle, "_AXUIElementGetWindow");
        }
    }

    return fn;
}

bool KanseiAXUIElementGetWindowAvailable(void)
{
    return resolvedAXUIElementGetWindow() != NULL;
}

AXError KanseiAXUIElementGetWindow(AXUIElementRef ref, CGWindowID *windowID)
{
    AXUIElementGetWindowFn fn = resolvedAXUIElementGetWindow();
    if (!fn) {
        if (windowID) {
            *windowID = 0;
        }
        return kAXErrorFailure;
    }

    return fn(ref, windowID);
}
