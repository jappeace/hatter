{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ImportQualifiedPost      #-}
-- | Runs a Hatter app in a browser page. The page's Angular host makes
-- Angular Material components of the app's widgets, and gives the app what
-- the user does.
--
-- The app's module exports its start for the page:
--
-- > foreign export javascript "start" start :: IO ()
-- >
-- > start :: IO ()
-- > start = runBrowser app
module Hatter.Browser
  ( runBrowser
  ) where

import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Monad (join, (<=<))
import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Int (Int16, Int32, Int64)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Word (Word8)
import Foreign.C.String (CString, newCString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (allocaBytes, free)
import Foreign.Ptr (FunPtr, Ptr, castPtr, nullPtr)
import Foreign.Storable (peekElemOff)
import GHC.Wasm.Prim (JSString (..), JSVal, fromJSString, toJSString)
import Hatter
  ( MobileApp
  , haskellLazyItemKey
  , haskellOnBack
  , haskellOnBottomSheetResult
  , haskellOnDialogResult
  , haskellOnFilePicked
  , haskellOnLifecycle
  , haskellOnLazyBind
  , haskellOnPicturePicked
  , haskellOnUIEvent
  , haskellOnUIScroll
  , haskellOnUITextChange
  , haskellRenderUI
  , startMobileApp
  )
import Hatter.Lifecycle (LifecycleEvent (..), lifecycleToInt)

-- The page's host: what the bridge's calls do in the page.

foreign import javascript unsafe "globalThis.hatter.createNode($1)"
  js_createNode :: Int32 -> IO Int32

foreign import javascript unsafe "globalThis.hatter.setStrProp($1, $2, $3)"
  js_setStrProp :: Int32 -> Int32 -> JSString -> IO ()

foreign import javascript unsafe "globalThis.hatter.setNumProp($1, $2, $3)"
  js_setNumProp :: Int32 -> Int32 -> Double -> IO ()

foreign import javascript unsafe "globalThis.hatter.setImageData($1, new Uint8Array(__exports.memory.buffer, $2, $3).slice())"
  js_setImageData :: Int32 -> Ptr Word8 -> Int32 -> IO ()

foreign import javascript unsafe "globalThis.hatter.setHandler($1, $2, $3)"
  js_setHandler :: Int32 -> Int32 -> Int32 -> IO ()

foreign import javascript unsafe "globalThis.hatter.addChild($1, $2)"
  js_addChild :: Int32 -> Int32 -> IO ()

foreign import javascript unsafe "globalThis.hatter.removeChild($1, $2)"
  js_removeChild :: Int32 -> Int32 -> IO ()

foreign import javascript unsafe "globalThis.hatter.destroyNode($1)"
  js_destroyNode :: Int32 -> IO ()

foreign import javascript unsafe "globalThis.hatter.setRoot($1)"
  js_setRoot :: Int32 -> IO ()

foreign import javascript unsafe "globalThis.hatter.clear()"
  js_clear :: IO ()

foreign import javascript unsafe "globalThis.hatter.darkMode()"
  js_darkMode :: IO Bool

foreign import javascript unsafe "globalThis.hatter.clock24()"
  js_clock24 :: IO Bool

foreign import javascript unsafe "globalThis.hatter.copyText($1)"
  js_copyText :: JSString -> IO ()

foreign import javascript unsafe "globalThis.hatter.openUri($1)"
  js_openUri :: JSString -> IO ()

foreign import javascript unsafe "globalThis.hatter.dialog($1, $2, $3, $4, $5, $6)"
  js_dialog :: Int32 -> JSString -> JSString -> JSString -> JSString -> JSString -> IO ()

foreign import javascript unsafe "globalThis.hatter.sheet($1, $2, $3)"
  js_sheet :: Int32 -> JSString -> JSString -> IO ()

-- | Files the user picks of a MIME type: whether several, and whether with a camera.
foreign import javascript unsafe "globalThis.hatter.pickFiles($3, $1, $2)"
  js_pickFiles :: Bool -> Bool -> JSString -> IO ()

foreign import javascript unsafe "globalThis.hatter.pickPicture(new Int32Array(__exports.memory.buffer, $1, $2).slice(), $3)"
  js_pickPicture :: Ptr Int32 -> Int32 -> Int32 -> IO ()

foreign import javascript unsafe "globalThis.hatter.saveFile($1, $2, $3)"
  js_saveFile :: JSString -> JSString -> JSString -> IO ()

foreign import javascript unsafe "globalThis.hatter.openFile($1)"
  js_openFile :: JSString -> IO ()

-- | A picture file's width and height, written where they point.
foreign import javascript unsafe "globalThis.hatter.imageSize($3, new DataView(__exports.memory.buffer), $1, $2)"
  js_imageSize :: Ptr Int32 -> Ptr Int32 -> JSString -> IO Bool

-- | Copies a typed array's bytes from the page into the app's memory.
foreign import javascript unsafe "new Uint8Array(__exports.memory.buffer, $2, $1.byteLength).set(new Uint8Array($1.buffer, $1.byteOffset, $1.byteLength))"
  js_copyBytes :: JSVal -> Ptr Word8 -> IO ()

foreign import javascript unsafe "$1.byteLength"
  js_byteLength :: JSVal -> IO Int

foreign import javascript unsafe "globalThis.hatter.callAudioStart($1, $2)"
  js_callAudioStart :: Int32 -> Int32 -> IO ()

foreign import javascript unsafe "globalThis.hatter.callAudioStop()"
  js_callAudioStop :: IO ()

-- | Copied through bytes, as samples needn't start at an even address.
foreign import javascript unsafe "globalThis.hatter.callAudioPlay($1, $2, new Int16Array(new Uint8Array(__exports.memory.buffer, $3, 2 * $4).slice().buffer))"
  js_callAudioPlay :: Int32 -> Int32 -> Ptr Int16 -> Int32 -> IO Int32

foreign import javascript unsafe "globalThis.hatter.callAudioLatency()"
  js_callAudioLatency :: IO Int32

foreign import javascript unsafe "globalThis.hatter.callAudioTone($1)"
  js_callAudioTone :: Int32 -> IO ()

foreign import javascript unsafe "globalThis.hatter.cameraStart($1 !== 0)"
  js_cameraStart :: Int32 -> IO ()

foreign import javascript unsafe "globalThis.hatter.cameraStop()"
  js_cameraStop :: IO ()

-- | An I420 frame of a size, for the images that show a stream.
foreign import javascript unsafe "globalThis.hatter.showFrame($4, $1, $2, new Uint8Array(__exports.memory.buffer, $3, $1 * $2 + 2 * (($1 + 1) >> 1) * (($2 + 1) >> 1)).slice())"
  js_showFrame :: Int32 -> Int32 -> Ptr Word8 -> JSString -> IO ()

-- | Has the page render on its next frame.
foreign import javascript unsafe "globalThis.hatter.redraw()"
  js_redraw :: IO ()

-- | Hands the page what it calls for what the user does.
foreign import javascript unsafe "globalThis.hatter.start({render: $1, event: $2, text: $3, scroll: $4, back: $5, dialog: $6, sheet: $7, picked: $8, picture: $9, callFrame: $10, cameraFrame: $11, bind: $12, key: $13, size: $14, shown: $15})"
  js_start :: JSVal -> JSVal -> JSVal -> JSVal -> JSVal -> JSVal -> JSVal -> JSVal -> JSVal -> JSVal -> JSVal -> JSVal -> JSVal -> JSVal -> JSVal -> IO ()

-- What the user does comes as calls that may wait for the page. Lazy
-- columns ask for their rows while the page draws, so those calls answer
-- at once.

foreign import javascript "wrapper"
  js_action :: IO () -> IO JSVal

foreign import javascript "wrapper"
  js_event :: (Int32 -> IO ()) -> IO JSVal

foreign import javascript "wrapper"
  js_text :: (Int32 -> JSString -> IO ()) -> IO JSVal

foreign import javascript "wrapper"
  js_scroll :: (Int32 -> Int32 -> IO ()) -> IO JSVal

-- | Which button or item a dialog or sheet answers a request with.
foreign import javascript "wrapper"
  js_answer :: (Int32 -> Int32 -> IO ()) -> IO JSVal

foreign import javascript "wrapper"
  js_back :: IO Bool -> IO JSVal

-- | A file the user picked: where it is, its name and its size.
foreign import javascript "wrapper"
  js_picked :: (JSString -> JSString -> Double -> IO ()) -> IO JSVal

-- | A picture the user picked, as PNG bytes.
foreign import javascript "wrapper"
  js_picture :: (JSVal -> IO ()) -> IO JSVal

-- | A frame of a call's audio the microphone recorded, as 16-bit samples.
foreign import javascript "wrapper"
  js_callFrame :: (JSVal -> IO ()) -> IO JSVal

-- | A frame the camera filmed: its width and height, and its I420 bytes.
foreign import javascript "wrapper"
  js_cameraFrame :: (Int32 -> Int32 -> JSVal -> IO ()) -> IO JSVal

-- | Whether the tab is shown now.
foreign import javascript "wrapper"
  js_shown :: (Bool -> IO ()) -> IO JSVal

-- | The page's new width and height.
foreign import javascript "wrapper"
  js_size :: (Int32 -> Int32 -> IO ()) -> IO JSVal

foreign import javascript "wrapper sync"
  js_bind :: (Int32 -> Int32 -> Int32 -> IO Int32) -> IO JSVal

foreign import javascript "wrapper sync"
  js_key :: (Int32 -> Int32 -> IO Int64) -> IO JSVal

-- The bridge's callbacks, as C function pointers.

type CreateNode = Int32 -> IO Int32
type SetStr = Int32 -> Int32 -> CString -> IO ()
type SetNum = Int32 -> Int32 -> Double -> IO ()
type SetImage = Int32 -> Ptr Word8 -> Int32 -> IO ()
type Node3 = Int32 -> Int32 -> Int32 -> IO ()
type Node2 = Int32 -> Int32 -> IO ()
type Node1 = Int32 -> IO ()
type Flag = IO Int32
type Text1 = CString -> IO ()
type Redraw = Ptr () -> IO ()
type Dialog = Int32 -> Ptr CString -> IO ()
type Sheet = Ptr () -> Int32 -> CString -> CString -> IO ()
type PickPicture = Ptr Int32 -> Int32 -> Int32 -> IO ()
type Text3 = CString -> CString -> CString -> IO ()
type ImageSize = CString -> Ptr Int32 -> Ptr Int32 -> IO Int32
type Play = Int32 -> Int32 -> Ptr Int16 -> Int32 -> IO Int32
type ShowFrame = CString -> Int32 -> Int32 -> Ptr Word8 -> IO ()

foreign import ccall "wrapper" createNodeFun :: CreateNode -> IO (FunPtr CreateNode)
foreign import ccall "wrapper" setStrFun :: SetStr -> IO (FunPtr SetStr)
foreign import ccall "wrapper" setNumFun :: SetNum -> IO (FunPtr SetNum)
foreign import ccall "wrapper" setImageFun :: SetImage -> IO (FunPtr SetImage)
foreign import ccall "wrapper" node3Fun :: Node3 -> IO (FunPtr Node3)
foreign import ccall "wrapper" node2Fun :: Node2 -> IO (FunPtr Node2)
foreign import ccall "wrapper" node1Fun :: Node1 -> IO (FunPtr Node1)
foreign import ccall "wrapper" actionFun :: IO () -> IO (FunPtr (IO ()))
foreign import ccall "wrapper" flagFun :: Flag -> IO (FunPtr Flag)
foreign import ccall "wrapper" text1Fun :: Text1 -> IO (FunPtr Text1)
foreign import ccall "wrapper" redrawFun :: Redraw -> IO (FunPtr Redraw)
foreign import ccall "wrapper" dialogFun :: Dialog -> IO (FunPtr Dialog)
foreign import ccall "wrapper" sheetFun :: Sheet -> IO (FunPtr Sheet)
foreign import ccall "wrapper" pickPictureFun :: PickPicture -> IO (FunPtr PickPicture)
foreign import ccall "wrapper" text3Fun :: Text3 -> IO (FunPtr Text3)
foreign import ccall "wrapper" imageSizeFun :: ImageSize -> IO (FunPtr ImageSize)
foreign import ccall "wrapper" playFun :: Play -> IO (FunPtr Play)
foreign import ccall "wrapper" showFrameFun :: ShowFrame -> IO (FunPtr ShowFrame)

foreign import ccall "hatter_browser_register_call_video"
  c_registerCallVideo :: FunPtr Node1 -> FunPtr (IO ()) -> FunPtr ShowFrame -> IO ()

-- | Hands a filmed frame to the call: its bytes, how many, width and height.
foreign import ccall safe "hatter_browser_camera_frame"
  c_cameraFrame :: Ptr Word8 -> Int32 -> Int32 -> Int32 -> IO ()

foreign import ccall "hatter_browser_register_call_audio"
  c_registerCallAudio :: FunPtr Node2 -> FunPtr (IO ()) -> FunPtr Play -> FunPtr Flag -> FunPtr Node1 -> IO ()

-- | Hands a recorded frame to the call.
foreign import ccall safe "hatter_browser_call_audio_frame"
  c_callAudioFrame :: Ptr Int16 -> Int32 -> IO ()

foreign import ccall "hatter_browser_register_dialog"
  c_registerDialog :: FunPtr Dialog -> IO ()

foreign import ccall "bottom_sheet_register_impl"
  c_registerSheet :: FunPtr Sheet -> IO ()

foreign import ccall "redraw_register_impl"
  c_registerRedraw :: FunPtr Redraw -> IO ()

foreign import ccall "setAppFilesDir"
  c_setAppFilesDir :: CString -> IO ()

foreign import ccall "setDeviceScreenWidth"
  c_setScreenWidth :: CString -> IO ()

foreign import ccall "setDeviceScreenHeight"
  c_setScreenHeight :: CString -> IO ()

foreign import ccall "setDeviceScreenDensity"
  c_setScreenDensity :: CString -> IO ()

foreign import javascript unsafe "window.innerWidth"
  js_width :: IO Int

foreign import javascript unsafe "window.innerHeight"
  js_height :: IO Int

-- | Where the page keeps the app's files, as the WASI directory it gives.
filesDir :: String
filesDir = "/data"

foreign import ccall "hatter_browser_register_ui"
  c_registerUi
    :: FunPtr CreateNode -> FunPtr SetStr -> FunPtr SetNum -> FunPtr SetImage -> FunPtr Node3
    -> FunPtr Node2 -> FunPtr Node2 -> FunPtr Node1 -> FunPtr Node1 -> FunPtr (IO ())
    -> FunPtr Flag -> FunPtr Flag -> FunPtr Text1 -> FunPtr Text1 -> FunPtr Text1 -> FunPtr Text1
    -> FunPtr (IO ()) -> FunPtr PickPicture -> FunPtr Text3 -> FunPtr Text1 -> FunPtr ImageSize -> IO ()

-- | Text the bridge gives in UTF-8, for the page.
jsText :: CString -> IO JSString
jsText = fmap (toJSString . Text.unpack . Text.decodeUtf8Lenient) . BS.packCString

-- | Text the bridge may leave out, empty if it does.
jsOptional :: CString -> IO JSString
jsOptional text
  | text == nullPtr = pure (toJSString "")
  | otherwise = jsText text

-- | Text from the page, in UTF-8 for the app.
withUtf8 :: JSString -> (CString -> IO a) -> IO a
withUtf8 = BS.useAsCString . Text.encodeUtf8 . Text.pack . fromJSString

flag :: IO Bool -> Flag
flag = fmap (fromIntegral . fromEnum)

install :: IO ()
install = do
  createNode <- createNodeFun js_createNode
  setStr <- setStrFun $ \node prop -> js_setStrProp node prop <=< jsText
  setNum <- setNumFun js_setNumProp
  setImage <- setImageFun js_setImageData
  setHandler <- node3Fun js_setHandler
  addChild <- node2Fun js_addChild
  removeChild <- node2Fun js_removeChild
  destroyNode <- node1Fun js_destroyNode
  setRoot <- node1Fun js_setRoot
  clear <- actionFun js_clear
  darkMode <- flagFun (flag js_darkMode)
  clock24 <- flagFun (flag js_clock24)
  copyText <- text1Fun (js_copyText <=< jsText)
  openUri <- text1Fun (js_openUri <=< jsText)
  pickFile <- text1Fun (js_pickFiles False False <=< jsText)
  pickFiles <- text1Fun (js_pickFiles True False <=< jsText)
  capture <- actionFun (js_pickFiles False True (toJSString "image/*"))
  pickPicture <- pickPictureFun js_pickPicture
  saveFile <- text3Fun $ \path name mime -> join (js_saveFile <$> jsText path <*> jsText name <*> jsText mime)
  openFile <- text1Fun (js_openFile <=< jsText)
  imageSize <- imageSizeFun $ \path width height -> flag (js_imageSize width height =<< jsText path)
  c_registerUi createNode setStr setNum setImage setHandler addChild removeChild destroyNode setRoot clear
    darkMode clock24 copyText openUri pickFile pickFiles capture pickPicture saveFile openFile imageSize
  c_registerRedraw =<< redrawFun (const js_redraw)
  join $ c_registerCallAudio <$> node2Fun js_callAudioStart <*> actionFun js_callAudioStop
    <*> playFun js_callAudioPlay <*> flagFun js_callAudioLatency <*> node1Fun js_callAudioTone
  join $ c_registerCallVideo <$> node1Fun js_cameraStart <*> actionFun js_cameraStop
    <*> showFrameFun (\key width height i420 -> js_showFrame width height i420 =<< jsText key)
  c_registerDialog <=< dialogFun $ \request texts ->
    let text = jsText <=< peekElemOff texts
        optional = jsOptional <=< peekElemOff texts
    in join $ js_dialog request <$> text 0 <*> text 1 <*> text 2 <*> optional 3 <*> optional 4
  c_registerSheet <=< sheetFun $ \_ request title items ->
    join (js_sheet request <$> jsText title <*> jsText items)
  -- Kept for as long as the app runs.
  c_setAppFilesDir =<< newCString filesDir
  -- The page's lengths are CSS pixels, so a pixel per pixel.
  c_setScreenDensity =<< newCString "1"

-- | Gives the app the page's size. Returns the action that frees its
-- strings, to run once the app has a newer size.
setSize :: Int -> Int -> IO (IO ())
setSize width height = do
  w <- newCString (show width)
  h <- newCString (show height)
  c_setScreenWidth w
  c_setScreenHeight h
  pure (free w >> free h)

-- | Shows the app in the page, and gives it what the user does from then
-- on. Calls from the page take turns, as they would on a phone's UI
-- thread.
runBrowser :: IO MobileApp -> IO ()
runBrowser makeApp = do
  install
  sized <- newIORef =<< join (setSize <$> js_width <*> js_height)
  ptr <- startMobileApp =<< makeApp
  turn <- newMVar ()
  let inTurn :: IO a -> IO a
      inTurn = withMVar turn . const
  render <- js_action (inTurn (haskellRenderUI ptr))
  event <- js_event $ inTurn . haskellOnUIEvent ptr . CInt
  text <- js_text $ \callback value -> inTurn $ withUtf8 value (haskellOnUITextChange ptr (CInt callback))
  scroll <- js_scroll $ \callback position -> inTurn (haskellOnUIScroll ptr (CInt callback) (CInt position))
  back <- js_back $ inTurn ((/= 0) <$> haskellOnBack ptr)
  dialog <- js_answer $ \request action -> inTurn (haskellOnDialogResult ptr (CInt request) (CInt action))
  sheet <- js_answer $ \request action -> inTurn (haskellOnBottomSheetResult ptr (CInt request) (CInt action))
  picked <- js_picked $ \path name size -> inTurn $
    withUtf8 path $ \cpath -> withUtf8 name $ \cname -> haskellOnFilePicked ptr cpath cname (truncate size)
  picture <- js_picture $ \png -> do
    size <- js_byteLength png
    allocaBytes size $ \bytes -> js_copyBytes png bytes >> inTurn (haskellOnPicturePicked ptr bytes (fromIntegral size))
  -- Not in turn: it isn't the UI's, and mustn't wait behind a render.
  callFrame <- js_callFrame $ \samples -> do
    size <- js_byteLength samples
    allocaBytes size $ \bytes -> js_copyBytes samples bytes >> c_callAudioFrame (castPtr bytes) (fromIntegral (size `div` 2))
  cameraFrame <- js_cameraFrame $ \width height i420 -> do
    size <- js_byteLength i420
    allocaBytes size $ \bytes -> js_copyBytes i420 bytes >> c_cameraFrame bytes (fromIntegral size) width height
  bind <- js_bind $ \list row position -> (\(CInt n) -> n) <$> haskellOnLazyBind ptr (CInt list) (CInt row) (CInt position)
  key <- js_key $ \list position -> haskellLazyItemKey ptr (CInt list) (CInt position)
  size <- js_size $ \width height -> inTurn $ do
    old <- readIORef sized
    writeIORef sized =<< setSize (fromIntegral width) (fromIntegral height)
    old
  -- Shown while the tab is, as Android's activity between Start and Stop.
  let lifecycle = inTurn . mapM_ (haskellOnLifecycle ptr . lifecycleToInt)
  shown <- js_shown $ \now -> lifecycle (if now then [Start, Resume] else [Pause, Stop])
  js_start render event text scroll back dialog sheet picked picture callFrame cameraFrame bind key size shown
  lifecycle [Create, Start, Resume]
  inTurn (haskellRenderUI ptr)
