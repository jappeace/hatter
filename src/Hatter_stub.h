#include <HsFFI.h>
#if defined(__cplusplus)
extern "C" {
#endif
extern void haskellRenderUI(HsPtr a1);
extern void haskellOnUIEvent(HsPtr a1, HsInt32 a2);
extern void haskellOnUITextChange(HsPtr a1, HsInt32 a2, HsPtr a3);
extern void haskellOnPermissionResult(HsPtr a1, HsInt32 a2, HsInt32 a3);
extern void haskellOnBleScanResult(HsPtr a1, HsPtr a2, HsPtr a3, HsInt32 a4);
extern void haskellOnDialogResult(HsPtr a1, HsInt32 a2, HsInt32 a3);
extern void haskellOnLocationUpdate(HsPtr a1, HsDouble a2, HsDouble a3, HsDouble a4, HsDouble a5);
extern void haskellOnLifecycle(HsPtr a1, HsInt32 a2);
extern void haskellOnSecureStorageResult(HsPtr a1, HsInt32 a2, HsInt32 a3, HsPtr a4);
extern void haskellOnAuthSessionResult(HsPtr a1, HsInt32 a2, HsInt32 a3, HsPtr a4, HsPtr a5);
extern void haskellOnPlatformSignInResult(HsPtr a1, HsInt32 a2, HsInt32 a3, HsPtr a4, HsPtr a5, HsPtr a6, HsPtr a7, HsInt32 a8);
extern void haskellOnCameraResult(HsPtr a1, HsInt32 a2, HsInt32 a3, HsPtr a4, HsInt32 a5, HsInt32 a6, HsInt32 a7);
extern void haskellOnVideoFrame(HsPtr a1, HsInt32 a2, HsPtr a3, HsInt32 a4, HsInt32 a5, HsInt32 a6);
extern void haskellOnAudioChunk(HsPtr a1, HsInt32 a2, HsPtr a3, HsInt32 a4);
extern void haskellOnBottomSheetResult(HsPtr a1, HsInt32 a2, HsInt32 a3);
extern void haskellOnHttpResult(HsPtr a1, HsInt32 a2, HsInt32 a3, HsInt32 a4, HsPtr a5, HsPtr a6, HsInt32 a7);
extern void haskellOnNetworkStatusChange(HsPtr a1, HsInt32 a2, HsInt32 a3);
extern void haskellOnAnimationFrame(HsPtr a1, HsDouble a2);
#if defined(__cplusplus)
}
#endif

