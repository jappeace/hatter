{-# LANGUAGE ForeignFunctionInterface #-}
-- | Low-level FFI bindings to the C UI bridge (@cbits/ui_bridge.c@).
--
-- These functions delegate to platform-native implementations on
-- Android/iOS and fall back to stderr stubs on desktop. Call them on the UI
-- thread (from event handlers and while rendering).
module Hatter.UIBridge
  ( NodeType(..)
  , nodeTypeToInt
  , StrProp(..)
  , strPropToInt
  , NumProp(..)
  , numPropToInt
  , EventType(..)
  , eventTypeToInt
  , createNode
  , setStrProp
  , setNumProp
  , setImageData
  , setHandler
  , addChild
  , removeChild
  , destroyNode
  , setRoot
  , clear
  , darkMode
  , clock24
  , copyText
  , pickFile
  , openFile
  , openUri
  , pickFiles
  , pickPicture
  , saveFile
  , imageSize
  , capturePicture
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Int (Int32)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Word (Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt(..), CDouble(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (withArrayLen)
import Foreign.Storable (peek)
import Foreign.Ptr (Ptr, castPtr)
import Hatter.Marshal (withText, withPath)
import Unwitch.Convert.Int qualified as Int
import Unwitch.Convert.Int32 qualified as Int32
import Unwitch.Convert.CInt qualified as CInt

-- | Widget node types corresponding to @UI_NODE_*@ in @UIBridge.h@.
data NodeType
  = NodeText
  | NodeButton
  | NodeColumn
  | NodeRow
  | NodeTextInput
  | NodeScrollView
  | NodeImage
  | NodeMapView
  | NodeWebView
  | NodeStack
  | NodeHorizontalScrollView
  | NodeLazyColumn
  | NodeSwitch
  deriving (Show, Eq, Enum, Bounded)

-- | Map a 'NodeType' to its C integer code.
nodeTypeToInt :: NodeType -> Int32
nodeTypeToInt NodeText       = 0
nodeTypeToInt NodeButton     = 1
nodeTypeToInt NodeColumn     = 2
nodeTypeToInt NodeRow        = 3
nodeTypeToInt NodeTextInput  = 4
nodeTypeToInt NodeScrollView = 5
nodeTypeToInt NodeImage      = 6
nodeTypeToInt NodeMapView    = 7
nodeTypeToInt NodeWebView    = 8
nodeTypeToInt NodeStack      = 9
nodeTypeToInt NodeHorizontalScrollView = 10
nodeTypeToInt NodeLazyColumn = 11
nodeTypeToInt NodeSwitch     = 12

-- | The text properties, for 'setStrProp': @UI_PROP_*@ in @UIBridge.h@.
data StrProp
  = PropText
  | PropColor
  | PropHint
  | PropBgColor
  | PropImageResource
  | PropImageFile
  | PropWebViewUrl
  | PropImageStream
  deriving (Show, Eq, Enum, Bounded)

-- | Map a 'StrProp' to its C integer code.
strPropToInt :: StrProp -> Int32
strPropToInt PropText          = 0
strPropToInt PropColor         = 1
strPropToInt PropHint          = 2
strPropToInt PropBgColor       = 3
strPropToInt PropImageResource = 4
strPropToInt PropImageFile     = 5
strPropToInt PropWebViewUrl    = 6
strPropToInt PropImageStream   = 7

-- | The number properties, for 'setNumProp': @UI_PROP_*@ in @UIBridge.h@.
data NumProp
  = PropFontSize
  | PropPadding
  | PropInputType
  | PropGravity
  | PropScaleType
  | PropMapLat
  | PropMapLon
  | PropMapZoom
  | PropMapShowUserLoc
  | PropTranslateX
  | PropTranslateY
  | PropAutoFocus
  | PropTouchPassthrough
  | PropWidth
  | PropHeight
  | PropWeight
  | PropAlignSelf
  | PropMargin
  | PropMaxWidth
  | PropCornerRadius
  | PropKeepAtEnd
  | PropMaxLines
  | PropItemCount
  | PropScrollToEnd
  | PropFontStyle
  | PropPaddingY
  | PropCornerTopLeft
  | PropCornerTopRight
  | PropCornerBottomRight
  | PropCornerBottomLeft
  | PropChecked
  deriving (Show, Eq, Enum, Bounded)

-- | Map a 'NumProp' to its C integer code.
numPropToInt :: NumProp -> Int32
numPropToInt PropFontSize          = 0
numPropToInt PropPadding           = 1
numPropToInt PropInputType         = 2
numPropToInt PropGravity           = 3
numPropToInt PropScaleType         = 4
numPropToInt PropMapLat            = 5
numPropToInt PropMapLon            = 6
numPropToInt PropMapZoom           = 7
numPropToInt PropMapShowUserLoc    = 8
numPropToInt PropTranslateX        = 9
numPropToInt PropTranslateY        = 10
numPropToInt PropAutoFocus         = 11
numPropToInt PropTouchPassthrough  = 12
numPropToInt PropWidth             = 13
numPropToInt PropHeight            = 14
numPropToInt PropWeight            = 15
numPropToInt PropAlignSelf         = 16
numPropToInt PropMargin            = 17
numPropToInt PropMaxWidth          = 18
numPropToInt PropCornerRadius      = 19
numPropToInt PropKeepAtEnd         = 20
numPropToInt PropMaxLines          = 21
numPropToInt PropItemCount         = 22
numPropToInt PropScrollToEnd       = 23
numPropToInt PropFontStyle         = 24
numPropToInt PropPaddingY          = 25
numPropToInt PropCornerTopLeft     = 26
numPropToInt PropCornerTopRight    = 27
numPropToInt PropCornerBottomRight = 28
numPropToInt PropCornerBottomLeft  = 29
numPropToInt PropChecked           = 30

-- | Event types corresponding to @UI_EVENT_*@ in @UIBridge.h@.
data EventType
  = EventClick
  | EventTextChange
  | EventLongPress
  | EventScrolled
  deriving (Show, Eq, Enum, Bounded)

-- | Map an 'EventType' to its C integer code.
eventTypeToInt :: EventType -> Int32
eventTypeToInt EventClick      = 0
eventTypeToInt EventTextChange = 1
eventTypeToInt EventLongPress  = 2
eventTypeToInt EventScrolled   = 3

-- Raw FFI imports
foreign import ccall "ui_create_node"    c_createNode   :: CInt -> IO CInt
foreign import ccall "ui_set_str_prop"   c_setStrProp   :: CInt -> CInt -> CString -> IO ()
foreign import ccall "ui_set_num_prop"   c_setNumProp   :: CInt -> CInt -> CDouble -> IO ()
foreign import ccall "ui_set_image_data" c_setImageData :: CInt -> Ptr Word8 -> CInt -> IO ()
foreign import ccall "ui_set_handler"    c_setHandler   :: CInt -> CInt -> CInt -> IO ()
foreign import ccall "ui_add_child"      c_addChild     :: CInt -> CInt -> IO ()
foreign import ccall "ui_remove_child"   c_removeChild  :: CInt -> CInt -> IO ()
foreign import ccall "ui_destroy_node"   c_destroyNode  :: CInt -> IO ()
foreign import ccall "ui_set_root"       c_setRoot      :: CInt -> IO ()
foreign import ccall "ui_clear"          c_clear        :: IO ()
foreign import ccall "ui_dark_mode"      c_darkMode     :: IO CInt
foreign import ccall "ui_clock24"        c_clock24      :: IO CInt
foreign import ccall "ui_copy_text"      c_copyText     :: CString -> IO ()
foreign import ccall "ui_pick_file"      c_pickFile     :: CString -> IO ()
foreign import ccall "ui_open_file"      c_openFile     :: CString -> IO ()
foreign import ccall "ui_open_uri"       c_openUri      :: CString -> IO ()
foreign import ccall "ui_pick_files"     c_pickFiles    :: CString -> IO ()
foreign import ccall "ui_pick_picture"   c_pickPicture  :: Ptr CInt -> CInt -> CInt -> IO ()
foreign import ccall "ui_save_file"      c_saveFile     :: CString -> CString -> CString -> IO ()
foreign import ccall "ui_image_size"     c_imageSize    :: CString -> Ptr CInt -> Ptr CInt -> IO CInt
foreign import ccall "ui_capture_picture" c_capturePicture :: IO ()

-- | Create a native node of the given type. Returns an opaque node ID.
createNode :: NodeType -> IO Int32
createNode nt = CInt.toInt32 <$> c_createNode (Int32.toCInt (nodeTypeToInt nt))

-- | Set a string property on a node.
setStrProp :: Int32 -> StrProp -> Text -> IO ()
setStrProp nodeId prop value =
  withText value $ \cstr ->
    c_setStrProp (Int32.toCInt nodeId) (Int32.toCInt (strPropToInt prop)) cstr

-- | Set a numeric property on a node.
setNumProp :: Int32 -> NumProp -> Double -> IO ()
setNumProp nodeId prop value =
  c_setNumProp (Int32.toCInt nodeId) (Int32.toCInt (numPropToInt prop)) (realToFrac value)

-- | Set raw image data (PNG/JPEG bytes) on a node.
setImageData :: Int32 -> ByteString -> IO ()
setImageData nodeId imageBytes =
  BS.useAsCStringLen imageBytes $ \(ptr, len) ->
    c_setImageData (Int32.toCInt nodeId) (castPtr ptr) (fromMaybe 0 (Int.toCInt len))

-- | Register an event handler on a node. The @callbackId@ is looked up
-- in the 'RenderState' callback registry when the event fires.
setHandler :: Int32 -> EventType -> Int32 -> IO ()
setHandler nodeId eventType callbackId =
  c_setHandler (Int32.toCInt nodeId) (Int32.toCInt (eventTypeToInt eventType)) (Int32.toCInt callbackId)

-- | Add a child node to a parent container.
addChild :: Int32 -> Int32 -> IO ()
addChild parentId childId =
  c_addChild (Int32.toCInt parentId) (Int32.toCInt childId)

-- | Remove a child node from a parent container.
removeChild :: Int32 -> Int32 -> IO ()
removeChild parentId childId =
  c_removeChild (Int32.toCInt parentId) (Int32.toCInt childId)

-- | Destroy a node and free its native resources.
destroyNode :: Int32 -> IO ()
destroyNode nodeId =
  c_destroyNode (Int32.toCInt nodeId)

-- | Set a node as the root of the display.
setRoot :: Int32 -> IO ()
setRoot nodeId =
  c_setRoot (Int32.toCInt nodeId)

-- | Clear all nodes (called before re-render).
clear :: IO ()
clear = c_clear

-- | Whether the platform shows dark colours now. It renders again when
-- this changes.
darkMode :: IO Bool
darkMode = (/= 0) <$> c_darkMode

-- | Whether the user wants times on a 24-hour clock.
clock24 :: IO Bool
clock24 = (/= 0) <$> c_clock24

-- | Put text on the platform's clipboard. The user is told it's copied:
-- by the system where it says so, else by a short note.
copyText :: Text -> IO ()
copyText value = withText value c_copyText

-- | Let the user pick a file of a MIME type, such as @*/*@.
pickFile :: Text -> IO ()
pickFile mimeType = withText mimeType c_pickFile

-- | Show one of the app's files in another app.
openFile :: FilePath -> IO ()
openFile path = withPath path c_openFile

-- | As 'pickFile', for several.
pickFiles :: Text -> IO ()
pickFiles mimeType = withText mimeType c_pickFiles

-- | Let the user pick a picture, as a square PNG of one of the sides of at
-- most so many bytes.
pickPicture :: [Int] -> Int -> IO ()
pickPicture sides limit =
  withArrayLen (map fromIntegral sides) $ \count ptr -> c_pickPicture ptr (fromIntegral count) (fromIntegral limit)

-- | Let the user save one of the app's files, which is deleted afterwards.
saveFile :: FilePath -> Text -> Text -> IO ()
saveFile path name mimeType =
  withPath path $ \cpath ->
    withText name $ \cname ->
      withText mimeType $ c_saveFile cpath cname

-- | The size a picture file shows at, turned as its camera says.
imageSize :: FilePath -> IO (Maybe (Int, Int))
imageSize path =
  withPath path $ \cpath ->
    alloca $ \pw -> alloca $ \ph -> do
      found <- c_imageSize cpath pw ph
      if found == 0 then pure Nothing
        else (\w h -> Just (fromIntegral w, fromIntegral h)) <$> peek pw <*> peek ph

-- | Take a picture with the platform's camera app.
capturePicture :: IO ()
capturePicture = c_capturePicture

-- | Open a web or mail address in another app.
openUri :: Text -> IO ()
openUri uri = withText uri c_openUri
