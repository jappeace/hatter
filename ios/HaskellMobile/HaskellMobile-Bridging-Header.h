#include "HaskellMobile.h"
#include "UIBridge.h"

/* iOS UI bridge setup — called from Swift before haskellRenderUI */
void setup_ios_ui_bridge(void *viewController, void *haskellCtx);
