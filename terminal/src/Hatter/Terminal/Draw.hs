{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Paints a laid out frame into character cells, and those into an image
-- for vty. Pictures are drawn with half blocks, two pixels to a cell.
module Hatter.Terminal.Draw
  ( Colours (..)
  , coloursFor
  , Pictures
  , newPictures
  , paint
  ) where

import Codec.Picture (DynamicImage, Image (..), PixelRGBA8 (..), convertRGBA8, decodeImage, pixelAt, readImage)
import Control.Exception (SomeException, evaluate, try)
import Control.Monad (forM_, when)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (groupBy)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Vector qualified as V
import Data.Vector.Mutable qualified as MV
import Data.Word (Word8)
import Graphics.Vty qualified as Vty
import Hatter.Widget (Color (..), ImageSource (..), ScaleType (..))
import System.FilePath (takeFileName)

import Hatter.Terminal.Layout

-- | What the terminal shows where the app doesn't say.
data Colours = Colours
  { coloursText       :: Color
  , coloursBackground :: Color
  } deriving (Eq, Show)

coloursFor :: Bool -> Colours
coloursFor dark
  | dark = Colours (Color 0xe2 0xe2 0xe9 0xff) (Color 0x11 0x13 0x18 0xff)
  | otherwise = Colours (Color 0x1a 0x1c 0x20 0xff) (Color 0xf9 0xf9 0xff 0xff)

data Cell = Cell
  { cellChar   :: !Char
  , cellAfter  :: !Bool
    -- ^ The right half of a wide character.
  , cellFg     :: !Color
  , cellBg     :: !Color
  , cellBold   :: !Bool
  , cellDim    :: !Bool
  , cellUnder  :: !Bool
  , cellItalic :: !Bool
  } deriving (Eq)

-- | Pictures decoded and scaled to a size in pixels, as they are shown.
newtype Pictures = Pictures (IORef (Map (Either FilePath ByteString, Int, Int, Int) (Maybe (V.Vector Color))))

newPictures :: IO Pictures
newPictures = Pictures <$> newIORef Map.empty

paint :: Colours -> Pictures -> Int -> Int -> [Op] -> IO Vty.Image
paint colours pictures width height ops = do
  let blank = Cell ' ' False (coloursText colours) (coloursBackground colours) False False False False
  canvas <- MV.replicate (width * height) blank
  let at x y = y * width + x
      onCanvas x y = x >= 0 && y >= 0 && x < width && y < height
      cells (Rect rx ry rw rh) = [ (x, y) | y <- [max 0 ry .. min height (ry + rh) - 1], x <- [max 0 rx .. min width (rx + rw) - 1] ]
      modify x y f = when (onCanvas x y) (MV.modify canvas f (at x y))
  forM_ ops $ \case
    Fill rect colour -> forM_ (cells rect) $ \(x, y) -> modify x y $ \c ->
      if colorAlpha colour == 0xff
        then blank { cellBg = colour }
        else c { cellFg = blend colour (cellFg c), cellBg = blend colour (cellBg c) }
    Write x0 y t look -> do
      let go _ [] = pure ()
          go x (ch : rest) = do
            let w = charWidth ch
            when (w > 0) $ do
              modify x y $ \c -> c
                { cellChar = ch, cellAfter = False
                , cellFg = maybe (coloursText colours) (`blend` cellBg c) (lookColor look)
                , cellBold = lookBold look, cellDim = lookDim look, cellUnder = lookUnderline look
                , cellItalic = lookItalic look }
              when (w == 2) $ modify (x + 1) y $ \c -> c { cellChar = ' ', cellAfter = True }
            go (x + w) rest
      go x0 (Text.unpack t)
    Picture rect clip source scaleType corners -> do
      shown <- fmap (rounded corners (rectW rect) (rectH rect * 2)) <$> picture pictures source scaleType (rectW rect) (rectH rect * 2)
      case shown of
        Just pixels -> forM_ (cells clip) $ \(x, y) -> do
          let px = x - rectX rect
              py = (y - rectY rect) * 2
              top = pixels V.! (py * rectW rect + px)
              bottom = pixels V.! ((py + 1) * rectW rect + px)
          modify x y $ \c ->
            let bg = blend bottom (cellBg c)
            in c { cellChar = '\x2580', cellAfter = False, cellFg = blend top bg, cellBg = bg
                 , cellBold = False, cellDim = False, cellUnder = False, cellItalic = False }
        Nothing -> do
          let name = case source of
                ImageFile path -> Text.pack (takeFileName path)
                _              -> "picture"
          forM_ (zip [max (rectX clip) (rectX rect) ..] (Text.unpack (Text.take (rectW clip) name))) $ \(x, ch) ->
            when (inside x (rectY clip) clip) $ modify x (rectY clip) $ \c -> c { cellChar = ch, cellAfter = False, cellDim = True }
    Highlight rect -> forM_ (cells rect) $ \(x, y) -> modify x y $ \c ->
      c { cellBg = blend (coloursText colours) { colorAlpha = 0x40 } (cellBg c) }
  frozen <- V.freeze canvas
  pure $ Vty.vertCat
    [ Vty.horizCat (map run' (groupBy sameLook (filter (not . cellAfter) (V.toList (V.slice (y * width) width frozen)))))
    | y <- [0 .. height - 1] ]
  where
    sameLook a b = cellFg a == cellFg b && cellBg a == cellBg b && cellBold a == cellBold b
      && cellDim a == cellDim b && cellUnder a == cellUnder b && cellItalic a == cellItalic b
    run' cs@(c : _) = Vty.string (attr c) (map cellChar cs)
    run' [] = Vty.emptyImage
    attr c = foldr ($) Vty.defAttr
      [ (`Vty.withForeColor` rgb (cellFg c))
      , (`Vty.withBackColor` rgb (cellBg c))
      , if cellBold c then (`Vty.withStyle` Vty.bold) else id
      , if cellDim c then (`Vty.withStyle` Vty.dim) else id
      , if cellUnder c then (`Vty.withStyle` Vty.underline) else id
      , if cellItalic c then (`Vty.withStyle` Vty.italic) else id ]
    rgb (Color r g b _) = Vty.linearColor r g b

-- | Clears the pixels outside rounded corners.
rounded :: (Double, Double) -> Int -> Int -> V.Vector Color -> V.Vector Color
rounded (rx0, ry0) w h
  | rx <= 0 || ry <= 0 = id
  | otherwise = V.imap $ \i c ->
      let (y, x) = i `divMod` w
          dx = corner rx (fromIntegral w) (fromIntegral x + 0.5)
          dy = corner ry (fromIntegral h) (fromIntegral y + 0.5)
      in if (dx / rx) ^ (2 :: Int) + (dy / ry) ^ (2 :: Int) > 1 then Color 0 0 0 0 else c
  where
    rx = min rx0 (fromIntegral w / 2)
    ry = min ry0 (fromIntegral h / 2)
    -- How far into a corner's curve, along one side.
    corner r size at = maximum [0, r - at, at - (size - r)]

-- | A colour over another.
blend :: Color -> Color -> Color
blend (Color r g b a) (Color r' g' b' _) = Color (mix r r') (mix g g') (mix b b') 0xff
  where
    mix :: Word8 -> Word8 -> Word8
    mix x y = fromIntegral ((fromIntegral x * alpha + fromIntegral y * (255 - alpha)) `div` 255 :: Int)
    alpha = fromIntegral a :: Int

picture :: Pictures -> ImageSource -> ScaleType -> Int -> Int -> IO (Maybe (V.Vector Color))
picture (Pictures cache) source scaleType w h
  | w <= 0 || h <= 0 = pure Nothing
  | otherwise = case source of
      ImageFile path -> cached (Left path) (readImage path)
      ImageData bytes -> cached (Right bytes) (pure (decodeImage bytes))
      _ -> pure Nothing
  where
    cached key load = do
      let k = (key, kind, w, h)
          kind = case scaleType of
            ScaleFit  -> 0
            ScaleFill -> 1
            ScaleNone -> 2 :: Int
      Map.lookup k <$> readIORef cache >>= \case
        Just shown -> pure shown
        Nothing -> do
          decoded <- try (load >>= either (const (pure Nothing)) (fmap Just . evaluate . scaled scaleType w h))
          let shown = either (\(_ :: SomeException) -> Nothing) id decoded
          -- Forget them all now and then, rather than keep every size shown.
          atomicModifyIORef' cache (\m -> (Map.insert k shown (if Map.size m > 256 then Map.empty else m), ()))
          pure shown

-- | A picture scaled to a size, cut to fill it or shown whole in it.
scaled :: ScaleType -> Int -> Int -> DynamicImage -> V.Vector Color
scaled scaleType w h dynamic = V.force $ V.generate (w * h) $ \i ->
  let (y, x) = i `divMod` w
      sx = (fromIntegral x - offX) / scale
      sy = (fromIntegral y - offY) / scale
  in if sx < 0 || sy < 0 || sx >= sw || sy >= sh then Color 0 0 0 0 else average sx sy
  where
    image = convertRGBA8 dynamic
    sw = fromIntegral (imageWidth image) :: Double
    sh = fromIntegral (imageHeight image)
    fx = fromIntegral w / sw
    fy = fromIntegral h / sh
    scale = case scaleType of
      ScaleFill -> max fx fy
      ScaleFit  -> min fx fy
      ScaleNone -> 1
    offX = (fromIntegral w - sw * scale) / 2
    offY = (fromIntegral h - sh * scale) / 2
    -- A few samples over the pixels a cell half covers.
    step = 1 / scale
    average sx sy =
      let points = [ (min (imageWidth image - 1) (floor (sx + step * dx)), min (imageHeight image - 1) (floor (sy + step * dy)))
                   | dx <- [0.125, 0.375, 0.625, 0.875 :: Double], dy <- [0.125, 0.375, 0.625, 0.875] ]
          pixels = [ pixelAt image px py | (px, py) <- points ]
          n = length pixels
          channel f = fromIntegral (sum (map (fromIntegral . f) pixels :: [Int]) `div` n)
      in Color (channel (\(PixelRGBA8 r _ _ _) -> r)) (channel (\(PixelRGBA8 _ g _ _) -> g))
               (channel (\(PixelRGBA8 _ _ b _) -> b)) (channel (\(PixelRGBA8 _ _ _ a) -> a))
