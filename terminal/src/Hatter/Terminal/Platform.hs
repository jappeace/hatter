{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ImportQualifiedPost      #-}
{-# LANGUAGE LambdaCase               #-}
{-# LANGUAGE OverloadedStrings        #-}
{-# LANGUAGE ScopedTypeVariables      #-}
{-# LANGUAGE TypeApplications         #-}
-- | Hatter's platform calls, answered in a terminal. Those that need the
-- user come to the terminal as requests.
module Hatter.Terminal.Platform
  ( Request (..)
  , Settings (..)
  , install
  , setFilesDir
  , setScreenWidth
  , readKey
  , pictureSize
  , squarePicture
  , logLine
  ) where

import Codec.Picture (DynamicImage (..), Image (..), PixelRGBA8 (..), convertRGBA8,
                      encodePng, generateImage, imageHeight, imageWidth, pixelAt, readImage, saveJpgImage,
                      savePngImage)
import Codec.Picture.Types (dropAlphaLayer)
import Control.Concurrent (forkIO)
import Control.Exception (IOException, SomeException, displayException, finally, fromException, try)
import Control.Monad (unless, void)
import Data.Bool (bool)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.CaseInsensitive qualified as CI
import Data.Int (Int32)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import Data.Vector.Storable qualified as SV
import Data.Word (Word8)
import Foreign.C.String (CString, newCString)
import Foreign.C.Types (CInt (..), CLLong (..), CSize (..))
import Foreign.Marshal.Alloc (mallocBytes)
import Foreign.Marshal.Array (peekArray)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (FunPtr, Ptr, castPtr, nullPtr)
import Foreign.Storable (poke)
import Hatter.Marshal (newPath)
import Network.HTTP.Client qualified as Http
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types (statusCode)
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory)
import System.Posix.Files (createLink, ownerReadMode, ownerWriteMode, removeLink, rename, unionFileModes)
import System.IO (IOMode (..), hClose, hFlush, hPutStrLn, stderr, withFile)
import System.Posix.IO (OpenFileFlags (..), OpenMode (..), closeFd, defaultFileFlags, fdToHandle, openFd)
import System.Posix.Process (getProcessID)
import System.Posix.Unistd (fileSynchronise)

-- | What the app asked for that the terminal shows.
data Request
  = Redraw
  | ShowDialog CInt Text Text [Text]
    -- ^ Request, title, message, buttons.
  | ShowSheet CInt Text [Text]
  | Permit CInt Bool
    -- ^ A permission request answered.
  | Notify Text Text
    -- ^ Key and what to show.
  | Unnotify Text
  | Status Text
  | HttpDone CInt CInt CInt (Maybe Text) ByteString
    -- ^ Request, result code, HTTP status, headers or error, body.
  | PickFile
    -- ^ One at a time, also when the app takes several.
  | PickPicture [Int] Int
  | SaveFile FilePath Text
  | Copy Text
  | Open Text
    -- ^ A file or address, for another program.

data Settings = Settings
  { settingDark    :: Bool
  , settingClock24 :: Bool
  }

type DialogShow = Ptr () -> Int32 -> CString -> CString -> CString -> CString -> CString -> IO ()
type SheetShow = Ptr () -> Int32 -> CString -> CString -> IO ()
type HttpRequest = Ptr () -> Int32 -> Int32 -> CString -> CString -> CString -> Int32 -> IO ()
type PermissionRequest = Ptr () -> Int32 -> Int32 -> IO ()
type PermissionCheck = Int32 -> IO Int32
type NotificationShow = CString -> CString -> CString -> CString -> CString -> CInt -> IO ()
type Text1 = CString -> IO ()
type Text3 = CString -> CString -> CString -> IO ()
type Ongoing = CString -> CString -> CLLong -> IO ()
type Flag = CInt -> IO ()
type Answer = IO CInt
type Answer32 = IO Int32
type Ctx = Ptr () -> IO ()
type Nothing' = IO ()
type PicturePick = Ptr Int32 -> Int32 -> Int32 -> IO ()
type ImageSize = CString -> Ptr Int32 -> Ptr Int32 -> IO Int32
type PicturePixels = CString -> Int32 -> Ptr Int32 -> Ptr Int32 -> IO (Ptr Word8)
type PictureShrink = CString -> CString -> Int32 -> IO Int32

foreign import ccall "wrapper" dialogShow :: DialogShow -> IO (FunPtr DialogShow)
foreign import ccall "wrapper" sheetShow :: SheetShow -> IO (FunPtr SheetShow)
foreign import ccall "wrapper" httpRequest :: HttpRequest -> IO (FunPtr HttpRequest)
foreign import ccall "wrapper" permissionRequest :: PermissionRequest -> IO (FunPtr PermissionRequest)
foreign import ccall "wrapper" permissionCheck :: PermissionCheck -> IO (FunPtr PermissionCheck)
foreign import ccall "wrapper" notificationShow :: NotificationShow -> IO (FunPtr NotificationShow)
foreign import ccall "wrapper" text1 :: Text1 -> IO (FunPtr Text1)
foreign import ccall "wrapper" text3 :: Text3 -> IO (FunPtr Text3)
foreign import ccall "wrapper" ongoing :: Ongoing -> IO (FunPtr Ongoing)
foreign import ccall "wrapper" flag :: Flag -> IO (FunPtr Flag)
foreign import ccall "wrapper" answer :: Answer -> IO (FunPtr Answer)
foreign import ccall "wrapper" answer32 :: Answer32 -> IO (FunPtr Answer32)
foreign import ccall "wrapper" ctx :: Ctx -> IO (FunPtr Ctx)
foreign import ccall "wrapper" nothing :: Nothing' -> IO (FunPtr Nothing')
foreign import ccall "wrapper" picturePick :: PicturePick -> IO (FunPtr PicturePick)
foreign import ccall "wrapper" imageSizeOf :: ImageSize -> IO (FunPtr ImageSize)
foreign import ccall "wrapper" picturePixels :: PicturePixels -> IO (FunPtr PicturePixels)
foreign import ccall "wrapper" pictureShrink :: PictureShrink -> IO (FunPtr PictureShrink)

foreign import ccall "dialog_register_impl" c_dialog :: FunPtr DialogShow -> IO ()
foreign import ccall "bottom_sheet_register_impl" c_sheet :: FunPtr SheetShow -> IO ()
foreign import ccall "http_register_impl" c_http :: FunPtr HttpRequest -> IO ()
foreign import ccall "permission_register_impl" c_permission :: FunPtr PermissionRequest -> FunPtr PermissionCheck -> IO ()
foreign import ccall "notification_register_impl" c_notification :: FunPtr NotificationShow -> FunPtr Text1 -> IO ()
foreign import ccall "notification_register_status" c_status :: FunPtr Text1 -> IO ()
foreign import ccall "notification_register_ongoing" c_ongoing :: FunPtr Ongoing -> IO ()
foreign import ccall "notification_register_background" c_background :: FunPtr Flag -> FunPtr Nothing' -> IO ()
foreign import ccall "notification_register_lock_screen" c_lockScreen :: FunPtr Flag -> FunPtr Answer -> FunPtr Nothing' -> IO ()
foreign import ccall "redraw_register_impl" c_redraw :: FunPtr Ctx -> IO ()
foreign import ccall "location_register_impl" c_location :: FunPtr Ctx -> FunPtr Nothing' -> IO ()
foreign import ccall "picture_register_impl" c_picture :: FunPtr PicturePixels -> FunPtr PictureShrink -> IO ()
foreign import ccall "hatter_terminal_register_ui" c_ui
  :: FunPtr Answer32 -> FunPtr Answer32 -> FunPtr Text1 -> FunPtr Text1 -> FunPtr Text1
  -> FunPtr PicturePick -> FunPtr Text3 -> FunPtr Text1 -> FunPtr Text1 -> FunPtr ImageSize -> IO ()

foreign import ccall "setAppFilesDir" c_setAppFilesDir :: CString -> IO ()
foreign import ccall "setDeviceScreenWidth" c_setScreenWidth :: CString -> IO ()
foreign import ccall "setDatabaseKey" c_setDatabaseKey :: Ptr Word8 -> CSize -> IO ()
foreign import ccall "setDatabaseKeyFailed" c_setDatabaseKeyFailed :: IO ()

-- | Answers the platform calls, sending what needs the user. The bridges
-- keep the functions for good.
install :: Settings -> (Request -> IO ()) -> IO ()
install settings send = do
  manager <- newTlsManager
  c_dialog =<< dialogShow (\_ request title message b1 b2 b3 -> do
    buttons <- mapM peekText [b1, b2, b3]
    t <- peekText title
    m <- peekText message
    send (ShowDialog (fromIntegral request) (orEmpty t) (orEmpty m) [ b | Just b <- buttons, not (Text.null b) ]))
  c_sheet =<< sheetShow (\_ request title items -> do
    t <- peekText title
    i <- peekText items
    send (ShowSheet (fromIntegral request) (orEmpty t) (Text.lines (orEmpty i))))
  c_http =<< httpRequest (\_ request method url headers body len -> do
    u <- orEmpty <$> peekText url
    h <- orEmpty <$> peekText headers
    b <- if body == nullPtr || len <= 0 then pure BS.empty else BS.packCStringLen (body, fromIntegral len)
    logLine ("http " <> Text.decodeUtf8Lenient (methodName method) <> " " <> u)
    void . forkIO $ fetch manager u (methodName method) h b >>= \case
      Right (status, headers', body') -> send (HttpDone (fromIntegral request) 0 status (Just headers') body')
      Left (code, err) -> send (HttpDone (fromIntegral request) code 0 (Just err) BS.empty))
  -- The terminal has no camera or location. Its microphone is silent, so
  -- calls can go (without frames).
  let allowed code = code `notElem` [0, 2]
  ask <- permissionRequest (\_ code request -> send (Permit (fromIntegral request) (allowed code)))
  check <- permissionCheck (\code -> pure (if allowed code then 0 else 1))
  c_permission ask check
  notify <- notificationShow (\key _ _ title body _ -> do
    k <- orEmpty <$> peekText key
    t <- orEmpty <$> peekText title
    b <- orEmpty <$> peekText body
    send (Notify k (t <> ": " <> Text.replace "\n" " \x00b7 " b)))
  unnotify <- text1 (\key -> peekText key >>= send . Unnotify . orEmpty)
  c_notification notify unnotify
  c_status =<< text1 (\status -> peekText status >>= send . Status . orEmpty)
  c_ongoing =<< ongoing (\_ _ _ -> pure ())
  ignore <- flag (\_ -> pure ())
  none <- nothing (pure ())
  allowedFullScreen <- answer (pure 1)
  c_background ignore none
  c_lockScreen ignore allowedFullScreen none
  c_redraw =<< ctx (\_ -> send Redraw)
  noLocation <- ctx (\_ -> pure ())
  c_location noLocation none
  pixels' <- picturePixels pixels
  shrink' <- pictureShrink shrink
  c_picture pixels' shrink'
  dark <- answer32 (pure (if settingDark settings then 1 else 0))
  clock <- answer32 (pure (if settingClock24 settings then 1 else 0))
  copy <- text1 (\t -> peekText t >>= send . Copy . orEmpty)
  pickFile <- text1 (\_ -> send PickFile)
  pickPicture <- picturePick (\sides count limit -> do
    s <- peekArray (fromIntegral count) sides
    send (PickPicture (map fromIntegral s) (fromIntegral limit)))
  save <- text3 (\path name _ -> do
    p <- orEmpty <$> peekText path
    n <- orEmpty <$> peekText name
    send (SaveFile (Text.unpack p) n))
  open <- text1 (\t -> peekText t >>= send . Open . orEmpty)
  size <- imageSizeOf (\path pw ph -> do
    p <- orEmpty <$> peekText path
    pictureSize (Text.unpack p) >>= \case
      Just (w, h) -> poke pw (fromIntegral w) >> poke ph (fromIntegral h) >> pure 1
      Nothing -> pure 0)
  c_ui dark clock copy pickFile pickFile pickPicture save open open size

-- | A line in the log, with the time.
logLine :: Text -> IO ()
logLine line = do
  now <- getZonedTime
  hPutStrLn stderr (formatTime defaultTimeLocale "%H:%M:%S " now <> Text.unpack line)

peekText :: CString -> IO (Maybe Text)
peekText p
  | p == nullPtr = pure Nothing
  | otherwise = Just . Text.decodeUtf8Lenient <$> BS.packCString p

orEmpty :: Maybe Text -> Text
orEmpty = fromMaybe Text.empty

methodName :: Int32 -> ByteString
methodName = \case
  1 -> "POST"
  2 -> "PUT"
  3 -> "DELETE"
  _ -> "GET"

-- | The status, headers and body, or Hatter's code for what went wrong.
fetch :: Http.Manager -> Text -> ByteString -> Text -> ByteString -> IO (Either (CInt, Text) (CInt, Text, ByteString))
fetch manager url method headers body = do
  result <- try $ do
    request <- Http.parseRequest (Text.unpack url)
    let request' = request
          { Http.method = method
          , Http.requestHeaders =
              [ (CI.mk (Text.encodeUtf8 k), Text.encodeUtf8 (Text.strip (Text.drop 1 v)))
              | line <- Text.lines headers, let (k, v) = Text.breakOn ":" line, not (Text.null v) ]
          , Http.requestBody = Http.RequestBodyBS body
          }
    response <- Http.httpLbs request' manager
    pure ( fromIntegral (statusCode (Http.responseStatus response))
         , Text.concat [ Text.decodeUtf8Lenient (CI.original k) <> ": " <> Text.decodeUtf8Lenient v <> "\n"
                       | (k, v) <- Http.responseHeaders response ]
         , LBS.toStrict (Http.responseBody response) )
  pure $ case result of
    Right ok -> Right ok
    Left err -> case fromException err of
      Just (Http.HttpExceptionRequest _ Http.ResponseTimeout) -> Left (2, "Timed out")
      Just (Http.HttpExceptionRequest _ Http.ConnectionTimeout) -> Left (2, "Timed out")
      _ -> Left (1, Text.pack (displayException (err :: SomeException)))

-- | Where the app keeps its files. Hatter keeps the string.
setFilesDir :: FilePath -> IO ()
setFilesDir dir = newPath dir >>= c_setAppFilesDir

-- | In density-independent pixels, as the app sees it.
setScreenWidth :: Int -> IO ()
setScreenWidth width = newCString (show width) >>= c_setScreenWidth

-- | The database key in a file only the user can read, made the first time.
readKey :: FilePath -> IO ()
readKey path = try load >>= \case
  Right key | BS.length key == 32 -> BS.useAsCStringLen key $ \(p, n) -> c_setDatabaseKey (castPtr p) (fromIntegral n)
  Right _ -> c_setDatabaseKeyFailed
  Left (_ :: SomeException) -> c_setDatabaseKeyFailed
  where
    load = do
      exists <- doesFileExist path
      unless exists $ withFile "/dev/urandom" ReadMode (`BS.hGet` 32) >>= keep
      BS.readFile path
    -- On the disk before it has its name, as what it encrypts is kept as
    -- soon as it's made: else a crash may leave the name with nothing.
    keep key = do
      made <- (\pid -> path <> "." <> show pid) <$> getProcessID
      -- Left by a start that crashed.
      void (try @IOException (removeLink made))
      fd <- openFd made WriteOnly defaultFileFlags
        { exclusive = True, creat = Just (unionFileModes ownerReadMode ownerWriteMode) }
      handle <- fdToHandle fd
      (BS.hPut handle key >> hFlush handle >> fileSynchronise fd) `finally` hClose handle
      -- Only if no other start made one meanwhile, whose key may be in use.
      try @IOException (createLink made path) >>= \case
        Right () -> removeLink made
        Left _ -> doesFileExist path >>= bool (rename made path) (removeLink made)
      synchronised (takeDirectory path)
    synchronised dir = do
      fd <- openFd dir ReadOnly defaultFileFlags { directory = True }
      fileSynchronise fd `finally` closeFd fd

-- Pictures, with JuicyPixels. Camera turns are not read.

-- | From the header of a PNG, JPEG, GIF or BMP alone: decoding a picture
-- whole can take gigabytes, as one a few kilobytes big may say it has
-- billions of pixels.
pictureSize :: FilePath -> IO (Maybe (Int, Int))
pictureSize path = try (BS.readFile path) >>= \case
  Right bytes | Just (w, h) <- pictureBounds bytes, w > 0, h > 0 -> pure (Just (w, h))
  Right _ -> pure Nothing
  Left (_ :: SomeException) -> pure Nothing

pictureBounds :: ByteString -> Maybe (Int, Int)
pictureBounds b
  | is 1 "PNG", long 24 = Just (be 16 4, be 20 4)
  | is 0 "GIF8", long 10 = Just (le 6 2, le 8 2)
  | is 0 "BM", long 26 = Just (signed (le 18 4), abs (signed (le 22 4)))
  | be 0 2 == 0xffd8 = jpeg 2
  | otherwise = Nothing
  where
    long n = BS.length b >= n
    is at s = BS.take (length s) (BS.drop at b) == Text.encodeUtf8 (Text.pack s)
    byte at = if at < BS.length b then fromIntegral (BS.index b at) else 0 :: Int
    be at n = foldl (\v i -> v * 256 + byte (at + i)) 0 [0 .. n - 1]
    le at n = foldr (\i v -> v * 256 + byte (at + i)) 0 [0 .. n - 1]
    signed v = if v >= 2 ^ (31 :: Int) then v - 2 ^ (32 :: Int) else v
    -- Segment by segment to the start of the frame, which isn't a Huffman
    -- (C4), JPG extension (C8) or arithmetic coding (CC) table.
    jpeg at
      | not (long (at + 9)) || byte at /= 0xff = Nothing
      | marker >= 0xffc0 && marker <= 0xffcf && marker `notElem` [0xffc4, 0xffc8, 0xffcc] =
          Just (be (at + 7) 2, be (at + 5) 2)
      | size < 2 = Nothing
      | otherwise = jpeg (at + 2 + size)
      where
        marker = be at 2
        size = be (at + 2) 2

-- | RGBA pixels, halved until there are at most so many.
pixels :: PicturePixels
pixels cpath most pw ph = do
  path <- Text.unpack . orEmpty <$> peekText cpath
  readImage path >>= \case
    Left _ -> pure nullPtr
    Right image -> do
      let rgba = halve (convertRGBA8 image)
          halve i
            | imageWidth i * imageHeight i > fromIntegral most, imageWidth i > 1, imageHeight i > 1 =
                halve (resize (imageWidth i `div` 2) (imageHeight i `div` 2) i)
            | otherwise = i
          bytes = SV.unsafeCast (imageData rgba) :: SV.Vector Word8
          n = SV.length bytes
      out <- mallocBytes n
      SV.unsafeWith bytes $ \src -> copyBytes out src n
      poke pw (fromIntegral (imageWidth rgba))
      poke ph (fromIntegral (imageHeight rgba))
      pure out

-- | Writes a picture again, no longer than so many pixels: 1 as JPEG, 2 as
-- PNG (if it has see-through pixels), 0 if it isn't one.
shrink :: PictureShrink
shrink cpath cout longest = do
  path <- Text.unpack . orEmpty <$> peekText cpath
  out <- Text.unpack . orEmpty <$> peekText cout
  readImage path >>= \case
    Left _ -> pure 0
    Right image -> do
      let rgba = convertRGBA8 image
          w = imageWidth rgba
          h = imageHeight rgba
          factor = min 1 (fromIntegral longest / fromIntegral (max w h)) :: Double
          small = resize (max 1 (round (fromIntegral w * factor))) (max 1 (round (fromIntegral h * factor))) rgba
          seeThrough = SV.any (< 255) (SV.ifilter (\i _ -> i `mod` 4 == 3) (SV.unsafeCast (imageData small) :: SV.Vector Word8))
      written <- try $ if seeThrough
        then savePngImage out (ImageRGBA8 small) >> pure 2
        else saveJpgImage 90 out (ImageRGB8 (dropAlphaLayer small)) >> pure 1
      case written of
        Right kind -> pure kind
        Left (_ :: SomeException) -> pure 0

-- | A picture cut to a square, as a PNG of the first side with at most so
-- many bytes.
squarePicture :: FilePath -> [Int] -> Int -> IO (Maybe ByteString)
squarePicture path sides limit = readImage path >>= \case
  Left _ -> pure Nothing
  Right image -> do
    let rgba = convertRGBA8 image
        side = min (imageWidth rgba) (imageHeight rgba)
        x0 = (imageWidth rgba - side) `div` 2
        y0 = (imageHeight rgba - side) `div` 2
        square = generateImage (\x y -> pixelAt rgba (x0 + x) (y0 + y)) side side
        fits = [ png | s <- sides, let png = LBS.toStrict (encodePng (resize s s square)), BS.length png <= limit ]
    pure (case fits of
      png : _ -> Just png
      []      -> Nothing)

-- | Averages the pixels each new one covers.
resize :: Int -> Int -> Image PixelRGBA8 -> Image PixelRGBA8
resize w h image = generateImage pixel w h
  where
    sx = fromIntegral (imageWidth image) / fromIntegral w :: Double
    sy = fromIntegral (imageHeight image) / fromIntegral h :: Double
    pixel x y =
      let xs = [floor (fromIntegral x * sx) .. max (floor (fromIntegral x * sx)) (ceiling (fromIntegral (x + 1) * sx) - 1)]
          ys = [floor (fromIntegral y * sy) .. max (floor (fromIntegral y * sy)) (ceiling (fromIntegral (y + 1) * sy) - 1)]
          ps = [ pixelAt image (min (imageWidth image - 1) px) (min (imageHeight image - 1) py) | px <- xs, py <- ys ]
          n = length ps
          avg f = fromIntegral (sum (map (fromIntegral . f) ps :: [Int]) `div` n)
      in PixelRGBA8 (avg (\(PixelRGBA8 r _ _ _) -> r)) (avg (\(PixelRGBA8 _ g _ _) -> g))
                    (avg (\(PixelRGBA8 _ _ b _) -> b)) (avg (\(PixelRGBA8 _ _ _ a) -> a))
