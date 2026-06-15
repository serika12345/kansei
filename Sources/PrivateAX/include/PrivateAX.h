#ifndef KANSEI_PRIVATE_AX_H
#define KANSEI_PRIVATE_AX_H

#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>

bool KanseiAXUIElementGetWindowAvailable(void);
AXError KanseiAXUIElementGetWindow(AXUIElementRef ref, CGWindowID *windowID);

#endif
