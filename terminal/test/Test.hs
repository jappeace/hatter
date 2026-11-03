{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings   #-}
module Main (main) where

import Codec.Picture (Image, PixelRGB8 (..), PixelYCbCr8, encodeJpeg, encodePng, generateImage)
import Codec.Picture.Types (convertImage)
import Control.Exception (bracket_)
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import GHC.IO.Encoding (getFileSystemEncoding, getForeignEncoding, mkTextEncoding, setFileSystemEncoding,
                        setForeignEncoding)
import Hatter.Action (Action (..), OnChange (..))
import Hatter.FilesDir (getAppFilesDir)
import Hatter.Terminal.Layout
import Hatter.Terminal.Platform (pictureSize, setFilesDir)
import Hatter.Widget
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main = defaultMain $ testGroup "terminal" [layoutTests, pictureTests, filesTests]

-- | The test suite's heap is capped, so a picture decoded whole fails them.
pictureTests :: TestTree
pictureTests = testGroup "pictures"
  -- 4937 bytes saying they are 100000 by 100000 pixels, as a friend may send.
  [ testCase "reads a picture's size without decoding it" $
      pictureSize "test/bomb.png" >>= (@?= Just (100000, 100000))
  , testCase "reads the size of PNGs and JPEGs" $ withSystemTempDirectory "pictures" $ \dir -> do
      let picture = generateImage (\x y -> PixelRGB8 (fromIntegral x) (fromIntegral y) 0) 30 20
      LBS.writeFile (dir </> "a.png") (encodePng picture)
      LBS.writeFile (dir </> "a.jpg") (encodeJpeg (convertImage picture :: Image PixelYCbCr8))
      mapM (pictureSize . (dir </>)) ["a.png", "a.jpg"] >>= (@?= [Just (30, 20), Just (30, 20)])
  ]

filesTests :: TestTree
filesTests = testGroup "files"
  [ testCase "keeps its files where it's told in the C locale too" $ do
      -- What the environment gives there for "/tmp/café".
      let dir = "/tmp/caf\56515\56489"
      (setFilesDir dir >> getAppFilesDir) `inCLocale` (@?= dir)
  ]
  where
    -- GHC's encodings in the C locale: what it can't encode, C's strings
    -- leave out, and its paths keep as the bytes they were.
    inCLocale action check = do
      ascii <- mkTextEncoding "ASCII//IGNORE"
      roundtrip <- mkTextEncoding "ASCII//ROUNDTRIP"
      (strings, paths) <- (,) <$> getForeignEncoding <*> getFileSystemEncoding
      check =<< bracket_ (setForeignEncoding ascii >> setFileSystemEncoding roundtrip)
                         (setForeignEncoding strings >> setFileSystemEncoding paths) action

layoutTests :: TestTree
layoutTests = testGroup "layout"
  [ testCase "wraps text at spaces" $
      map snd (breakLines 10 "the quick brown fox jumps") @?= ["the quick", "brown fox", "jumps"]
  , testCase "keeps a word that ends the line on it" $
      map snd (breakLines 9 "the quick brown") @?= ["the quick", "brown"]
  , testCase "puts the cursor after a wrapped space" $
      cursorAt (breakLines 10 "the quick brown") 10 @?= (1, 0)
  , testCase "gives a weighted child what the others leave" $
      written (frame 20 3 (row [text "ab", grow (text "x"), text "cd"]))
        @?= [(0, 0, "ab"), (2, 0, "x"), (18, 0, "cd")]
  , testCase "centres a child across its row" $
      written (frame 20 3 (styled (\s -> s { wsHeight = Just 72 }) (row [middle (text "a")])))
        @?= [(0, 1, "a")]
  , testCase "puts a stack's aligned child in its corner" $
      written (frame 10 4 (stack [text "a", styled (\s -> s { wsAlignSelf = Just SelfEnd }) (text "b")]))
        @?= [(0, 0, "a"), (9, 3, "b")]
  , testCase "can't reach what a later stack child covers" $
      map focusPath (frameFocus (frame 10 4 (stack
        [ Tappable (Action 1) (text "under")
        , styled (\s -> s { wsBackgroundColor = Just (Color 0 0 0 255) }) (Tappable (Action 2) (text "over")) ])))
        @?= [[1]]
  , testCase "keeps a chat at its end" $
      written (frame 5 2 (styled (\s -> s { wsKeepAtEnd = Just True }) (scrollColumn (map (text . Text.pack . show) [1 .. 5 :: Int]))))
        @?= [(0, 0, "4"), (0, 1, "5")]
  , testCase "keeps what shows of a chat when rows come before it" $ do
      let chat from = styled (\s -> s { wsKeepAtEnd = Just True }) (scrollColumn (map (text . Text.pack . show) [from .. 5 :: Int]))
          away = (inputs 5 2) { inScroll = const (Just (FromEnd 1)) }
      written (layout away (chat 1)) @?= [(0, 0, "3"), (0, 1, "4")]
      written (layout away (chat 0)) @?= [(0, 0, "3"), (0, 1, "4")]
  , testCase "scrolls as the terminal says" $
      written (layout (inputs 5 2) { inScroll = const (Just (FromStart 1)) } (scrollColumn (map (text . Text.pack . show) [1 .. 5 :: Int])))
        @?= [(0, 0, "2"), (0, 1, "3")]
  , testCase "puts the cursor in the focused input" $
      frameCursor (layout (inputs 10 1) { inFocus = Just [], inCursor = 2 } (TextInput (field "abc")))
        @?= Just (2, 0)
  , testCase "ends text cut short with an ellipsis" $
      written (frame 8 2 (styled (\s -> s { wsMaxLines = Just 1 }) (text "the quick brown fox")))
        @?= [(0, 0, "the qui\x2026")]
  , testCase "only pads with rows when there's no background" $
      written (frame 10 5 (column
        [ styled (\s -> s { wsPadding = Just 14 }) (text "a")
        , styled (\s -> s { wsPadding = Just 14, wsBackgroundColor = Just (Color 0 0 0 255) }) (text "b") ]))
        @?= [(2, 1, "a"), (2, 3, "b")]
  , testCase "underlines an empty input the whole width" $
      [ (t, lookUnderline l) | Write _ _ t l <- frameOps (frame 4 1 (TextInput (field ""))) ]
        @?= [("    ", True)]
  , testCase "can tap a button" $
      map focusTarget (frameFocus (frame 20 1 (button "OK" (Action 3))))
        @?= [Tap (Just (Action 3)) Nothing]
  , testCase "orders what can be focused as it is drawn" $
      map focusPath (frameFocus (frame 20 5 (column [Tappable (Action 1) (text "a"), row [TextInput (field ""), Tappable (Action 2) (text "b")]])))
        @?= [[0], [0, 1], [1, 1]]
  ]

inputs :: Int -> Int -> Inputs
inputs w h = Inputs defaultScale w h (const Nothing) Nothing 0 (const Nothing)

frame :: Int -> Int -> Widget -> Frame
frame w h = layout (inputs w h)

written :: Frame -> [(Int, Int, Text.Text)]
written f = [ (x, y, t) | Write x y t _ <- frameOps f ]

styled :: (WidgetStyle -> WidgetStyle) -> Widget -> Widget
styled f = Styled (f defaultStyle)

grow, middle :: Widget -> Widget
grow = styled (\s -> s { wsWeight = Just 1 })
middle = styled (\s -> s { wsAlignSelf = Just SelfCenter })

field :: Text.Text -> TextInputConfig
field value = TextInputConfig InputText "" value (OnChange 0) Nothing Nothing False
