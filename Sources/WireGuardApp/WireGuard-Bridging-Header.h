#include "../WireGuardKitC/WireGuardKitC.h"
#include "wireguard-go-version.h"

#include "unzip.h"
#include "zip.h"
#include "ringlogger.h"
#include "key.h"
#include "highlighter.h"

#import "TargetConditionals.h"
#if TARGET_OS_OSX
#include <libproc.h>
#endif

//#include "../../wireguard-go-bridge/wireguard.h"
