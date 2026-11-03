{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
-- | Runs a Hatter app in a terminal: the widgets drawn in character cells,
-- Tab and the arrow keys to move between what can be tapped or typed in,
-- Enter to tap, Esc for Back.
module Hatter.Terminal
  ( TerminalConfig (..)
  , terminalConfig
  , runTerminal
  ) where

import Brick qualified as B
import Brick.BChan (newBChan, writeBChan)
import Brick.Widgets.Border qualified as B
import Brick.Widgets.Center qualified as B
import Control.Exception (SomeException, displayException, evaluate, try)
import Control.Monad (forM_, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State (gets, modify)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Char (isAlphaNum, isSpace)
import Data.IORef (atomicModifyIORef', newIORef, writeIORef)
import Data.List (find, findIndex, maximumBy, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Foreign.C.Types (CInt)
import Foreign.Ptr (Ptr)
import GHC.IO.Handle (hDuplicateTo)
import Graphics.Vty qualified as Vty
import Graphics.Vty.CrossPlatform (mkVty)
import Hatter (MobileApp (..), currentWidget, startMobileApp)
import Hatter.Action (Action (..), ListPosition (..), OnChange (..), OnScroll (..), lookupAction, lookupScrollAction,
                      lookupTextAction)
import Hatter.AppContext (AppContext (..), derefAppContext)
import Hatter.BottomSheet (dispatchBottomSheetResult)
import Hatter.Dialog (dispatchDialogResult)
import Hatter.Http (dispatchHttpResult)
import Hatter.Lifecycle (LifecycleEvent (..), MobileContext (..), PickedFile (..))
import Hatter.Permission (dispatchPermissionResult)
import Hatter.Widget (Color (..), InputType (..), ResourceName, TextInputConfig (..), Widget, text)
import System.Directory (XdgDirectory (..), copyFile, createDirectoryIfMissing, doesDirectoryExist,
                         getFileSize, getHomeDirectory, getXdgDirectory, makeAbsolute, removeFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName, (</>))
import System.IO (BufferMode (..), IOMode (..), hSetBuffering, openFile, stderr,
                  withFile)
import System.Posix.Files (ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, readProcessWithExitCode)

import Hatter.Terminal.Draw
import Hatter.Terminal.Layout
import Hatter.Terminal.Platform

data TerminalConfig = TerminalConfig
  { terminalName  :: String
    -- ^ Names the app's directories.
  , terminalGlyph :: ResourceName -> Maybe Text
    -- ^ What to show for the app's image resources, like its icons.
  , terminalScale :: Scale
  }

terminalConfig :: String -> TerminalConfig
terminalConfig name = TerminalConfig name (const Nothing) defaultScale

-- | Keeps the app's files in the XDG data directory, its database key in
-- a file there only the user can read, and its log there too. The app is
-- made once those are set up.
runTerminal :: TerminalConfig -> IO MobileApp -> IO ()
runTerminal config makeApp = do
  dir <- getXdgDirectory XdgData (terminalName config)
  createDirectoryIfMissing True dir
  -- Whatever writes to stderr would break the screen. The log has bits of
  -- what's on it, so only the user may read it.
  logFile <- openFile (dir </> "log.txt") AppendMode
  setFileMode (dir </> "log.txt") (ownerReadMode `unionFileModes` ownerWriteMode)
  hDuplicateTo logFile stderr
  hSetBuffering stderr LineBuffering
  setFilesDir dir
  readKey (dir </> "database.key")
  settings <- Settings <$> darkTerminal <*> clock24
  chan <- newBChan 4096
  pending <- newIORef False
  let send = \case
        -- One redraw waiting is enough.
        Redraw -> do
          already <- atomicModifyIORef' pending (True,)
          unless already (writeBChan chan Redraw)
        other -> writeBChan chan other
  install settings send
  let build = do
        vty <- mkVty Vty.defaultConfig
        Vty.setMode (Vty.outputIface vty) Vty.Mouse True
        Vty.setMode (Vty.outputIface vty) Vty.BracketedPaste True
        pure vty
  vty <- build
  (width, height) <- Vty.displayBounds (Vty.outputIface vty)
  setScreenWidth (round (fromIntegral width * scaleColumn (terminalScale config)))
  app <- makeApp
  ptr <- startMobileApp app
  context <- derefAppContext ptr
  pictures <- newPictures
  let fixed = Fixed
        { fixedConfig = config
        , fixedApp = app
        , fixedPtr = ptr
        , fixedContext = context
        , fixedColours = coloursFor (settingDark settings)
        , fixedPictures = pictures
        , fixedDir = dir
        , fixedLetRedraw = writeIORef pending False
        }
      start = St
        { stFixed = fixed
        , stWidget = text ""
        , stFrame = Frame [] [] [] Nothing
        , stImage = Vty.emptyImage
        , stFocus = Nothing
        , stScroll = Map.empty
        , stScrolled = Map.empty
        , stCursor = 0
        , stEdited = Nothing
        , stPopups = []
        , stNotes = []
        , stStatus = Nothing
        , stSize = (width, max 1 (height - 1))
        , stTitle = ""
        }
  void (B.customMain vty build (Just chan) terminal start)

-- | Dark unless the terminal says its background is light.
darkTerminal :: IO Bool
darkTerminal = lookupEnv "COLORFGBG" >>= \case
  Just colours | [(n, "")] <- reads (reverse (takeWhile (/= ';') (reverse colours))) ->
    pure (n < 7 || n == (8 :: Int))
  _ -> pure True

-- | As the locale writes times: 12 hours if it has AM and PM.
clock24 :: IO Bool
clock24 = try (readProcessWithExitCode "locale" ["t_fmt"] "") >>= \case
  Right (ExitSuccess, out, _) -> pure (not (any (`Text.isInfixOf` Text.pack out) ["%r", "%I", "%l", "%p"]))
  Right _ -> pure True
  Left (_ :: SomeException) -> pure True

data Name = Screen
  deriving (Eq, Ord, Show)

-- | What doesn't change while the app runs.
data Fixed = Fixed
  { fixedConfig    :: TerminalConfig
  , fixedApp       :: MobileApp
  , fixedPtr       :: Ptr AppContext
  , fixedContext   :: AppContext
  , fixedColours   :: Colours
  , fixedPictures  :: Pictures
  , fixedDir       :: FilePath
  , fixedLetRedraw :: IO ()
    -- ^ Lets the next redraw request through.
  }

data Popup
  = DialogPopup CInt Text Text [Text] Int
  | SheetPopup CInt Text [Text] Int
  | Prompt Text Text Int (Maybe Text -> IO ())
    -- ^ What to type, what is typed, the cursor, and what to do with it.

data St = St
  { stFixed    :: !Fixed
  , stWidget   :: !Widget
  , stFrame    :: !Frame
  , stImage    :: !Vty.Image
  , stFocus    :: !(Maybe Path)
  , stScroll   :: !(Map Path Scroll)
  , stScrolled :: !(Map Path (Int, ListPosition, [Int]))
    -- ^ For lists that say where they are: the number last seen, where
    -- they were, and their items' keys.
  , stCursor   :: !Int
  , stEdited   :: !(Maybe (Path, Text))
    -- ^ What we last typed into the focused input.
  , stPopups   :: ![Popup]
  , stNotes    :: ![(Text, Text)]
    -- ^ Notifications, newest first.
  , stStatus   :: !(Maybe Text)
  , stSize     :: !(Int, Int)
    -- ^ Of the app's part of the screen, above the status line.
  , stTitle    :: !Text
    -- ^ The top line of the screen, last logged.
  }

type Event = B.EventM Name St

terminal :: B.App St Request Name
terminal = B.App
  { B.appDraw = draw
  , B.appChooseCursor = B.showFirstCursor
  , B.appHandleEvent = handle
  , B.appStartEvent = do
      mobile <- gets mobileContext
      (width, height) <- gets stSize
      say ("started at " <> dimensions width height)
      liftIO (mapM_ (safely . onLifecycle mobile) [Create, Start, Resume])
      refresh
  , B.appAttrMap = \st ->
      let Colours fg bg = fixedColours (stFixed st)
      in B.attrMap (Vty.defAttr `Vty.withForeColor` rgb fg `Vty.withBackColor` rgb bg)
           [(chosen, Vty.defAttr `Vty.withStyle` Vty.reverseVideo)]
  }

rgb :: Color -> Vty.Color
rgb (Color r g b _) = Vty.linearColor r g b

chosen :: B.AttrName
chosen = B.attrName "chosen"

mobileContext :: St -> MobileContext
mobileContext = maContext . fixedApp . stFixed

-- | Runs some of the app's code, logging what it throws.
safely :: IO () -> IO ()
safely f = try f >>= \case
  Right () -> pure ()
  Left (e :: SomeException) -> logLine ("Uncaught exception: " <> Text.pack (displayException e))

-- | So what happens can be followed in the log.
say :: Text -> Event ()
say = liftIO . logLine

-- | Short enough for a line in the log.
quoted :: Int -> Text -> Text
quoted most t = "\"" <> (if Text.length t > most then Text.take most t <> "\x2026" else t) <> "\""

dimensions :: Int -> Int -> Text
dimensions w h = Text.pack (show w <> "\x00d7" <> show h)

-- | The text drawn on something that can be tapped.
labelOf :: Frame -> Focusable -> Text
labelOf frame f = Text.unwords
  [ Text.strip t | Write x y t _ <- frameOps frame, inside x y (focusVisible f), not (Text.null (Text.strip t)) ]

-- | The text along the top of the screen.
topLine :: Frame -> Text
topLine frame = case [ (y, x, Text.strip t) | Write x y t _ <- frameOps frame, not (Text.null (Text.strip t)) ] of
  [] -> ""
  writes -> let top = minimum [ y | (y, _, _) <- writes ]
            in Text.unwords [ t | (_, _, t) <- sortOn (\(_, x, _) -> x) [ w | w@(y, _, _) <- writes, y == top ] ]

-- Drawing.

draw :: St -> [B.Widget Name]
draw st = map popup (take 1 (stPopups st)) ++ [B.vBox [screen, statusLine]]
  where
    screen = case frameCursor (stFrame st) of
      Just (x, y) | null (stPopups st) -> B.showCursor Screen (B.Location (x, y)) (B.raw (stImage st))
      _ -> B.raw (stImage st)
    statusLine = B.withAttr chosen . B.padRight B.Max . B.txt . Text.take (fst (stSize st)) $
      case (stNotes st, stStatus st) of
        ((_, note) : _, _) -> "\x25cf " <> note
        ([], Just status)  -> status
        ([], Nothing)      -> "Tab: move \x00b7 Enter: tap \x00b7 Alt-Enter: hold \x00b7 Esc: back \x00b7 Ctrl-Q: quit"
    popup = \case
      DialogPopup _ title message buttons selected -> boxed title $ B.vBox
        [ B.txtWrap message
        , B.txt " "
        , B.hBox [ B.padRight (B.Pad 2) (choice (i == selected) b) | (i, b) <- zip [0 ..] (orOk buttons) ]
        ]
      SheetPopup _ title items selected -> boxed title $ B.vBox
        [ choice (i == selected) i' | (i, i') <- zip [0 :: Int ..] items ]
      Prompt question typed cursor _ -> boxed question $
        B.showCursor Screen (B.Location (min cursor (Text.length typed), 0)) (B.padRight B.Max (B.txt typed))
    boxed title = B.centerLayer . B.borderWithLabel (B.txt (" " <> title <> " ")) . B.hLimit 72 . B.padAll 1
    choice on = (if on then B.withAttr chosen else id) . B.txt . (\t -> " " <> t <> " ")

orOk :: [Text] -> [Text]
orOk [] = ["OK"]
orOk bs = bs

-- | Asks the app what it shows now, and lays it out.
refresh :: Event ()
refresh = do
  st <- B.get
  liftIO (fixedLetRedraw (stFixed st))
  widget <- liftIO (try (currentWidget (fixedPtr (stFixed st))))
  let shown = case widget of
        Right w -> w
        Left (e :: SomeException) -> text ("An error occurred: " <> Text.pack (displayException e))
  modify (\s -> s { stWidget = shown })
  relayout
  scrolled

-- | Lays out the widgets again, as they are.
relayout :: Event ()
relayout = do
  began <- liftIO getPOSIXTime
  st <- B.get
  let frame = frameOf st
      fixed = stFixed st
      (width, height) = stSize st
      -- The focus stays on what it was on, wherever that went.
      was = focused (stFrame st) (stFocus st)
      same f = Just (focusPath f) == stFocus st && maybe False (sameTarget (focusTarget f)) was
      kept = fmap focusPath (find same (frameFocus frame)
        `orElse` find (\f -> maybe False (sameTarget (focusTarget f)) was) (frameFocus frame))
      orElse (Just a) _ = Just a
      orElse Nothing b  = b
      focus = case kept of
        Just path -> Just path
        Nothing -> listToMaybe ([ focusPath f | f <- frameFocus frame, Input _ c <- [focusTarget f], tiAutoFocus c ]
                                ++ map focusPath (frameFocus frame))
      -- The cursor goes to the end when the app changed the text itself.
      cursor = case focused frame focus of
        Just (Input _ config)
          | Just (path, typed) <- stEdited st, Just path == focus, typed == tiValue config -> stCursor st
          | otherwise -> Text.length (tiValue config)
        _ -> 0
      st' = st { stFocus = focus, stCursor = cursor
               , stEdited = case focused frame focus of
                   Just (Input _ config) -> (, tiValue config) <$> focus
                   _ -> Nothing }
      frame' = frameOf st'
  _ <- liftIO (evaluate (sum (map (length . focusPath) (frameFocus frame')) + length (frameViewports frame') + length (frameOps frame')))
  image <- liftIO (paint (fixedColours fixed) (fixedPictures fixed) width height (frameOps frame'))
  ended <- liftIO getPOSIXTime
  when (ended - began >= 0.1) (say ("slow layout " <> Text.pack (show (round ((ended - began) * 1000) :: Int)) <> " ms, " <> Text.pack (show (length (frameFocus frame'))) <> " focusable"))
  let title = topLine frame'
  B.put st' { stFrame = frame', stImage = image, stTitle = title }
  when (title /= stTitle st) (say ("screen " <> quoted 60 title))
  -- A new focus is brought into view.
  when (focus /= kept && focus /= Nothing) reveal

frameOf :: St -> Frame
frameOf st = layout Inputs
  { inScale = terminalScale (fixedConfig (stFixed st))
  , inWidth = fst (stSize st)
  , inHeight = snd (stSize st)
  , inScroll = (`Map.lookup` stScroll st)
  , inFocus = stFocus st
  , inCursor = stCursor st
  , inGlyph = terminalGlyph (fixedConfig (stFixed st))
  } (stWidget st)

-- | The same thing to tap or type in, whatever is typed in it.
sameTarget :: Target -> Target -> Bool
sameTarget (Input a _) (Input b _) = a == b
sameTarget a b = a == b

focused :: Frame -> Maybe Path -> Maybe Target
focused frame focus = focusTarget <$> find ((== focus) . Just . focusPath) (frameFocus frame)

-- | Tells lists that say so where they are, again near their start when
-- their items change there, and takes them to their end when their number
-- changes.
scrolled :: Event ()
scrolled = do
  st <- B.get
  let views = [ (viewPath v, change, n, position v, viewItems v)
              | v <- frameViewports (stFrame st), Just (change, n) <- [viewScrolled v] ]
      position v
        | viewOffset v + rectH (viewRect v) >= viewContent v = if nearStart v then ListBoth else ListEnd
        | nearStart v = ListStart
        | otherwise = ListMiddle
      nearStart v = viewOffset v <= rectH (viewRect v)
      seen path = Map.lookup path (stScrolled st)
      moved = [ path | (path, _, n, _, _) <- views, Just (m, _, _) <- [seen path], m /= n ]
      changed = [ (change, end)
                | (path, change, _, end, items) <- views
                , Just (_, was, had) <- [seen path]
                , was /= end || end `elem` [ListStart, ListBoth] && had /= items ]
      -- Where they were and what they had, until they are where they move to.
      before path end items
        | null moved = (end, items)
        | otherwise = maybe (end, items) (\(_, e, is) -> (e, is)) (seen path)
  -- Evaluated now, or each would keep the last state and all it showed.
  B.put st { stScrolled = Map.fromList [ (path, kept) | (path, _, n, end, items) <- views
                                       , let (!was, had) = before path end items
                                             !kept = n `seq` foldl' (flip seq) () had `seq` (n, was, had) ]
           , stScroll = foldr (`Map.insert` FromEnd 0) (stScroll st) moved }
  if not (null moved)
    then relayout >> scrolled
    else unless (null changed) $ do
      forM_ changed $ \(change, now) -> do
        actions <- gets (maActionState . fixedApp . stFixed)
        liftIO (lookupScrollAction actions (onScrollId change) >>= mapM_ (safely . ($ now)))
      refresh

-- | Scrolls the lists the focus is in so it can be seen.
reveal :: Event ()
reveal = do
  st <- B.get
  case find ((== stFocus st) . Just . focusPath) (frameFocus (stFrame st)) of
    Just f | Just (path, top, size) <- focusScroller f
           , Just v <- find ((== path) . viewPath) (frameViewports (stFrame st)) -> do
      let h = rectH (viewRect v)
          offset = viewOffset v
          offset'
            | top < offset = top
            | top + size > offset + h = top + size - h
            | otherwise = offset
      when (offset' /= offset) $ do
        setScroll v offset'
        relayout
    _ -> pure ()

setScroll :: Viewport -> Int -> Event ()
setScroll v offset = modify $ \st -> st
  { stScroll = Map.insert (viewPath v)
      (if viewKeep v || toEnd <= 0 then FromEnd (max 0 toEnd) else FromStart (max 0 offset)) (stScroll st) }
  where toEnd = viewContent v - rectH (viewRect v) - offset

-- Events.

handle :: B.BrickEvent Name Request -> Event ()
handle = \case
  B.AppEvent request -> answer request
  B.VtyEvent (Vty.EvResize w h) -> do
    say ("resize " <> dimensions w h)
    modify (\st -> st { stSize = (w, max 1 (h - 1)) })
    relayout
  B.VtyEvent (Vty.EvKey key mods) -> gets stPopups >>= \case
    p : rest -> popupKey p rest key mods
    [] -> screenKey key mods
  B.VtyEvent (Vty.EvMouseDown x y button _) -> gets stPopups >>= \case
    [] -> mouse x y button
    _ -> pure ()
  B.VtyEvent (Vty.EvPaste bytes) -> paste (Text.filter (/= '\r') (Text.decodeUtf8Lenient bytes))
  _ -> pure ()

answer :: Request -> Event ()
answer = \case
  Redraw -> refresh
  ShowDialog request title message buttons -> do
    say ("dialog " <> quoted 60 title <> " " <> quoted 60 message <> ": " <> Text.intercalate ", " (orOk buttons))
    pushPopup (DialogPopup request title message buttons 0)
  ShowSheet request title items -> do
    say ("sheet " <> quoted 60 title <> ": " <> Text.intercalate ", " items)
    pushPopup (SheetPopup request title items 0)
  Permit request granted -> do
    say (if granted then "permission granted" else "permission refused")
    context <- gets (fixedContext . stFixed)
    liftIO (safely (dispatchPermissionResult (acPermissionState context) request (if granted then 0 else 1)))
    refresh
  Notify key line -> do
    say ("notify " <> quoted 60 line)
    modify (\st -> st { stNotes = (key, line) : filter ((/= key) . fst) (stNotes st) })
    vty <- B.getVtyHandle
    liftIO (Vty.ringTerminalBell (Vty.outputIface vty))
  Unnotify key -> modify (\st -> st { stNotes = filter ((/= key) . fst) (stNotes st) })
  Status status -> do
    say ("status " <> quoted 60 status)
    modify (\st -> st { stStatus = if Text.null status then Nothing else Just status })
  HttpDone request code status headers body -> do
    say $ "http \x2192 " <> case code of
      0 -> Text.pack (show status) <> ", " <> Text.pack (show (BS.length body)) <> " bytes"
      _ -> fromMaybe "failed" headers
    context <- gets (fixedContext . stFixed)
    liftIO (safely (dispatchHttpResult (acHttpState context) request code status headers body))
    refresh
  PickFile -> do
    mobile <- gets mobileContext
    dir <- gets (fixedDir . stFixed)
    ask "Pick a file" "" $ \path -> do
      picked <- try (pick dir (Text.unpack path))
      case picked of
        Right file -> do
          logLine ("picked " <> Text.pack (pickedPath file))
          safely (onFilePicked mobile file)
        Left (e :: SomeException) -> logLine ("Couldn't pick " <> path <> ": " <> Text.pack (displayException e))
  PickPicture sides limit -> do
    mobile <- gets mobileContext
    ask "Pick a picture" "" $ \path ->
      squarePicture (Text.unpack path) sides limit >>= mapM_ (safely . onPicturePicked mobile)
  SaveFile path name -> do
    home <- liftIO getHomeDirectory
    downloads <- liftIO (doesDirectoryExist (home </> "Downloads"))
    let suggested = (if downloads then home </> "Downloads" else home) </> Text.unpack name
    pushPopup $ Prompt "Save as" (Text.pack suggested) (length suggested) $ \to -> do
      -- Only the user may read it, as it may hold secrets.
      forM_ to $ \target -> quietly $ do
        logLine ("saving " <> target)
        copyFile path (Text.unpack target)
        setFileMode (Text.unpack target) (ownerReadMode `unionFileModes` ownerWriteMode)
      -- The app's file goes either way.
      quietly (removeFile path)
  -- Terminals put it on the clipboard when they see this.
  Copy t -> do
    say ("copy " <> Text.pack (show (Text.length t)) <> " characters")
    liftIO $ quietly $ withFile "/dev/tty" WriteMode $ \tty ->
      BS.hPut tty ("\ESC]52;c;" <> Base64.encode (Text.encodeUtf8 t) <> "\a")
  Open target -> do
    say ("open " <> target)
    liftIO $ quietly $ void $ createProcess (proc "xdg-open" [Text.unpack target])
      { std_in = NoStream, std_out = UseHandle stderr, std_err = UseHandle stderr }
  where
    ask question start done = do
      say ("prompt " <> quoted 60 question)
      pushPopup $ Prompt question start (Text.length start) $ \case
        Just typed | not (Text.null (Text.strip typed)) -> done (Text.strip typed)
        _ -> pure ()

-- | Logs what goes wrong.
quietly :: IO () -> IO ()
quietly f = try f >>= \case
  Right () -> pure ()
  Left (e :: SomeException) -> logLine (Text.pack (displayException e))

-- | A copy of the picked file where the app may move or delete it, as
-- Android gives one.
pick :: FilePath -> FilePath -> IO PickedFile
pick dir path = do
  source <- makeAbsolute path
  now <- getPOSIXTime
  let into = dir </> "picked" </> show (round (now * 1000000) :: Integer)
      name = takeFileName source
      -- Paths stay ASCII, as Hatter promises.
      safe = map (\c -> if c < '\x80' && (isAlphaNum c || c `elem` ("._-" :: String)) then c else '_') name
  createDirectoryIfMissing True into
  copyFile source (into </> safe)
  size <- getFileSize (into </> safe)
  pure (PickedFile (into </> safe) (Text.pack name) size)

pushPopup :: Popup -> Event ()
pushPopup p = modify (\st -> st { stPopups = stPopups st ++ [p] })

popupKey :: Popup -> [Popup] -> Vty.Key -> [Vty.Modifier] -> Event ()
popupKey p rest key mods = case p of
  DialogPopup request title message buttons selected -> case key of
    Vty.KEnter -> say ("chose " <> quoted 60 (orOk buttons !! selected)) >> closeWith (dialogResult request (if null buttons then 3 else selected))
    Vty.KEsc -> say "dismissed" >> closeWith (dialogResult request 3)
    _ | Just n <- move -> modify (\st -> st { stPopups = DialogPopup request title message buttons (wrap (length buttons) (selected + n)) : rest })
    _ -> pure ()
  SheetPopup request title items selected -> case key of
    Vty.KEnter | not (null items) -> say ("chose " <> quoted 60 (items !! selected)) >> closeWith (sheetResult request selected)
    Vty.KEsc -> say "dismissed" >> closeWith (sheetResult request (-1))
    _ | Just n <- move -> modify (\st -> st { stPopups = SheetPopup request title items (wrap (length items) (selected + n)) : rest })
    _ -> pure ()
  Prompt question typed cursor done -> case key of
    Vty.KEnter -> say ("answered " <> quoted 60 typed) >> closeWith (liftIO (done (Just typed)))
    Vty.KEsc -> say "dismissed" >> closeWith (liftIO (done Nothing))
    _ | Just (typed', cursor') <- edit False key mods typed cursor ->
          modify (\st -> st { stPopups = Prompt question typed' cursor' done : rest })
    _ -> pure ()
  where
    move = case key of
      Vty.KDown -> Just 1
      Vty.KRight -> Just 1
      Vty.KChar '\t' -> Just 1
      Vty.KUp -> Just (-1)
      Vty.KLeft -> Just (-1)
      Vty.KBackTab -> Just (-1)
      _ -> Nothing
    wrap n i = if n <= 0 then 0 else i `mod` n
    closeWith :: Event () -> Event ()
    closeWith f = do
      modify (\st -> st { stPopups = rest })
      f
      refresh
    dialogResult :: CInt -> Int -> Event ()
    dialogResult request code = do
      context <- gets (fixedContext . stFixed)
      liftIO (safely (dispatchDialogResult (acDialogState context) request (fromIntegral code)))
    sheetResult :: CInt -> Int -> Event ()
    sheetResult request code = do
      context <- gets (fixedContext . stFixed)
      liftIO (safely (dispatchBottomSheetResult (acBottomSheetState context) request (fromIntegral code)))

-- | Editing keys for a line of text, or several, and the cursor in it.
edit :: Bool -> Vty.Key -> [Vty.Modifier] -> Text -> Int -> Maybe (Text, Int)
edit multiline key mods typed cursor = case (key, mods) of
  (Vty.KChar c, []) | c /= '\t' -> Just (insert (Text.singleton c))
  (Vty.KChar c, [Vty.MShift]) -> Just (insert (Text.singleton c))
  (Vty.KEnter, [Vty.MMeta]) | multiline -> Just (insert "\n")
  (Vty.KBS, _) | cursor > 0 -> Just (Text.take (cursor - 1) typed <> Text.drop cursor typed, cursor - 1)
  (Vty.KDel, _) -> Just (Text.take cursor typed <> Text.drop (cursor + 1) typed, cursor)
  (Vty.KChar 'd', [Vty.MCtrl]) -> Just (Text.take cursor typed <> Text.drop (cursor + 1) typed, cursor)
  (Vty.KLeft, []) -> Just (typed, max 0 (cursor - 1))
  (Vty.KRight, []) -> Just (typed, min (Text.length typed) (cursor + 1))
  (Vty.KHome, _) -> Just (typed, 0)
  (Vty.KChar 'a', [Vty.MCtrl]) -> Just (typed, 0)
  (Vty.KEnd, _) -> Just (typed, Text.length typed)
  (Vty.KChar 'e', [Vty.MCtrl]) -> Just (typed, Text.length typed)
  (Vty.KChar 'u', [Vty.MCtrl]) -> Just (Text.drop cursor typed, 0)
  (Vty.KChar 'k', [Vty.MCtrl]) -> Just (Text.take cursor typed, cursor)
  (Vty.KChar 'w', [Vty.MCtrl]) ->
    let before = Text.take cursor typed
        kept = Text.dropWhileEnd (not . isSpace) (Text.dropWhileEnd isSpace before)
    in Just (kept <> Text.drop cursor typed, Text.length kept)
  _ -> Nothing
  where
    insert t = (Text.take cursor typed <> t <> Text.drop cursor typed, cursor + Text.length t)

screenKey :: Vty.Key -> [Vty.Modifier] -> Event ()
screenKey key mods = do
  st <- B.get
  let target = focused (stFrame st) (stFocus st)
      here = find ((== stFocus st) . Just . focusPath) (frameFocus (stFrame st))
  case (key, mods, target) of
    (Vty.KChar 'q', [Vty.MCtrl], _) -> quit
    (Vty.KChar 'c', [Vty.MCtrl], _) -> quit
    (Vty.KChar 'l', [Vty.MCtrl], _) -> B.getVtyHandle >>= liftIO . Vty.refresh
    (Vty.KEsc, [], _) -> do
      handled <- liftIO (try (onBack (mobileContext st)))
      case handled of
        Right True -> say "back" >> refresh
        Right False -> say "back, but there's nowhere to go"
        Left (e :: SomeException) -> say ("Uncaught exception: " <> Text.pack (displayException e))
    (Vty.KChar '\t', [], _) -> step 1
    (Vty.KBackTab, _, _) -> step (-1)
    (Vty.KDown, [], _) -> step 1
    (Vty.KUp, [], _) -> step (-1)
    (Vty.KPageDown, [], _) -> page 1
    (Vty.KPageUp, [], _) -> page (-1)
    (Vty.KEnter, [], Just (Input _ _)) -> submit
    (Vty.KEnter, [], Just (Tap _ _)) -> mapM_ tap here
    (Vty.KChar ' ', [], Just (Tap _ _)) -> mapM_ tap here
    (Vty.KEnter, [Vty.MMeta], Just (Tap _ (Just hold))) -> mapM_ (\f -> press "hold" f hold) here
    (_, _, Just (Input change config))
      | Just (typed, cursor) <- edit (tiInputType config == InputMultiline) key mods (tiValue config) (stCursor st) -> do
          modify (\s -> s { stCursor = cursor })
          if typed == tiValue config then relayout else typedInto change typed
    (Vty.KLeft, [], _) -> step (-1)
    (Vty.KRight, [], _) -> step 1
    -- Typing goes to the first input there is.
    (Vty.KChar c, m, _) | null m || m == [Vty.MShift], c /= '\t' ->
      typing (\config cursor -> (tiValue config <> Text.singleton c, cursor + 1))
    _ -> pure ()

-- | Into the input, as if typed there.
paste :: Text -> Event ()
paste pasted = gets stPopups >>= \case
  Prompt question typed cursor done : rest ->
    let line = Text.takeWhile (/= '\n') pasted
    in modify (\st -> st { stPopups = Prompt question (Text.take cursor typed <> line <> Text.drop cursor typed) (cursor + Text.length line) done : rest })
  [] -> typing $ \config cursor ->
    let shown = if tiInputType config == InputMultiline then pasted else Text.replace "\n" " " pasted
    in (Text.take cursor (tiValue config) <> shown <> Text.drop cursor (tiValue config), cursor + Text.length shown)
  _ -> pure ()

-- | Types into the focused input, or else the first there is, at its end.
typing :: (TextInputConfig -> Int -> (Text, Int)) -> Event ()
typing f = do
  st <- B.get
  let inputs = [ (focusPath i, change, config) | i <- frameFocus (stFrame st), Input change config <- [focusTarget i] ]
      chosen' = case [ i | i@(path, _, _) <- inputs, Just path == stFocus st ] of
        i : _ -> Just (i, stCursor st)
        [] -> (\i@(_, _, config) -> (i, Text.length (tiValue config))) <$> listToMaybe inputs
  forM_ chosen' $ \((path, change, config), cursor) -> do
    let (typed, cursor') = f config (min (Text.length (tiValue config)) cursor)
    modify (\s -> s { stFocus = Just path, stCursor = cursor' })
    typedInto change typed

typedInto :: OnChange -> Text -> Event ()
typedInto change typed = do
  modify (\st -> st { stEdited = (, typed) <$> stFocus st })
  textChanged change typed
  refresh

textChanged :: OnChange -> Text -> Event ()
textChanged change typed = do
  actions <- gets (maActionState . fixedApp . stFixed)
  liftIO (lookupTextAction actions (onChangeId change) >>= mapM_ (safely . ($ typed)))

-- | Taps it, or holds it if it can only be held.
tap :: Focusable -> Event ()
tap f = case focusTarget f of
  Tap (Just action) _ -> press "tap" f action
  Tap Nothing (Just hold) -> press "hold" f hold
  _ -> pure ()

press :: Text -> Focusable -> Action -> Event ()
press verb f action = do
  frame <- gets stFrame
  say (verb <> " " <> quoted 40 (labelOf frame f))
  fire action

fire :: Action -> Event ()
fire action = do
  actions <- gets (maActionState . fixedApp . stFixed)
  liftIO (lookupAction actions (actionId action) >>= mapM_ safely)
  refresh

-- | Enter in an input taps what comes after it, like a form's button.
submit :: Event ()
submit = do
  st <- B.get
  let after = drop 1 (dropWhile ((/= stFocus st) . Just . focusPath) (frameFocus (stFrame st)))
  case [ (f, a) | f <- after, Tap (Just a) _ <- [focusTarget f] ] of
    (f, a) : _ -> press "tap" f a
    [] -> pure ()

step :: Int -> Event ()
step n = do
  st <- B.get
  let list = frameFocus (stFrame st)
  unless (null list) $ do
    let here = fromMaybe (if n > 0 then -1 else 0) (findIndex ((== stFocus st) . Just . focusPath) list)
        next = list !! ((here + n) `mod` length list)
    modify (\s -> s { stFocus = Just (focusPath next) })
    relayout
    reveal

-- | Scrolls the list the focus is in, or the biggest, a page.
page :: Int -> Event ()
page n = do
  st <- B.get
  let views = frameViewports (stFrame st)
      focusedView = do
        f <- find ((== stFocus st) . Just . focusPath) (frameFocus (stFrame st))
        (path, _, _) <- focusScroller f
        find ((== path) . viewPath) views
      area v = rectW (viewRect v) * rectH (viewRect v)
      biggest = if null views then Nothing else Just (maximumBy (comparing area) views)
  forM_ (maybe biggest Just focusedView) $ \v -> do
    setScroll v (viewOffset v + n * max 1 (rectH (viewRect v) - 1))
    relayout
    scrolled

mouse :: Int -> Int -> Vty.Button -> Event ()
mouse x y button = do
  st <- B.get
  let (_, height) = stSize st
      hit = listToMaybe (reverse [ f | f <- frameFocus (stFrame st), inside x y (focusVisible f) ])
      under = listToMaybe (reverse [ v | v <- frameViewports (stFrame st), inside x y (viewRect v) ])
  case button of
    Vty.BLeft
      | y >= height, (key, _) : _ <- stNotes st -> do
          modify (\s -> s { stNotes = drop 1 (stNotes s) })
          say "opened the notification"
          liftIO (safely (onNotificationOpened (mobileContext st) key))
          refresh
      | Just f <- hit -> do
          modify (\s -> s { stFocus = Just (focusPath f) })
          case focusTarget f of
            Tap _ _ -> tap f
            Input _ config -> do
              modify (\s -> s { stCursor = Text.length (tiValue config) })
              relayout
    Vty.BRight | Just f <- hit, Tap _ (Just hold) <- focusTarget f -> do
      modify (\s -> s { stFocus = Just (focusPath f) })
      press "hold" f hold
    Vty.BScrollDown | Just v <- under -> scrollBy v 3
    Vty.BScrollUp | Just v <- under -> scrollBy v (-3)
    _ -> pure ()
  where
    scrollBy v n = do
      setScroll v (viewOffset v + n)
      relayout
      scrolled

quit :: Event ()
quit = do
  mobile <- gets mobileContext
  say "quit"
  liftIO (mapM_ (safely . onLifecycle mobile) [Pause, Stop, Destroy])
  B.halt
