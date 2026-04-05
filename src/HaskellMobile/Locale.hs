{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
module HaskellMobile.Locale
  ( Locale(..)
  , LocaleFailure(..)
  , getSystemLocale
  , parseLocale
  , localeToText
  , haskellLogLocale
  ) where

import Data.Char (isAlpha, isDigit, toLower, toUpper)
import Data.Text (Text)
import Data.Text qualified as Text
import Foreign.C.String (CString, peekCString)
import HaskellMobile.Lifecycle (platformLog)

-- | A parsed BCP-47 locale tag with language and optional region.
data Locale = Locale
  { locLanguage :: Text       -- ^ ISO 639-1 language code: @\"en\"@, @\"nl\"@, @\"zh\"@
  , locRegion   :: Maybe Text -- ^ ISO 3166-1 region code: @\"US\"@, @\"NL\"@, @\"CN\"@
  } deriving (Show, Eq, Ord)

-- | Reasons a locale tag may fail to parse.
data LocaleFailure
  = EmptyLocaleTag
  | InvalidLanguageCode Text
  | InvalidRegionCode Text
  | MalformedLocaleTag Text
  deriving (Show, Eq)

foreign import ccall "getSystemLocale" c_getSystemLocale :: IO CString

-- | Query the system locale from the host platform.
--
-- * Android: @Locale.getDefault().toLanguageTag()@ (cached at JNI_OnLoad)
-- * iOS: @NSLocale.currentLocale@ (queried at bridge setup)
-- * Desktop: @LANG@ environment variable, defaults to @\"en\"@
getSystemLocale :: IO Text
getSystemLocale = do
  cstr <- c_getSystemLocale
  Text.pack <$> peekCString cstr

-- | Parse a BCP-47 locale tag like @\"en\"@, @\"en-US\"@, @\"nl-NL\"@.
--
-- Splits on @\'-\'@ or @\'_\'@, validates language (2--3 lowercase alpha)
-- and optional region (2 uppercase alpha or 3 digits).
-- Language is normalised to lowercase, region to uppercase.
parseLocale :: Text -> Either LocaleFailure Locale
parseLocale tag
  | Text.null tag = Left EmptyLocaleTag
  | otherwise =
      case splitLocaleTag tag of
        [rawLang] ->
          case validateLanguage rawLang of
            Left failure -> Left failure
            Right lang   -> Right (Locale lang Nothing)
        [rawLang, rawRegion] ->
          case validateLanguage rawLang of
            Left failure -> Left failure
            Right lang   ->
              case validateRegion rawRegion of
                Left failure -> Left failure
                Right region -> Right (Locale lang (Just region))
        _ -> Left (MalformedLocaleTag tag)

-- | Render a 'Locale' back to its BCP-47 text form.
localeToText :: Locale -> Text
localeToText (Locale lang Nothing)       = lang
localeToText (Locale lang (Just region)) = lang <> "-" <> region

-- | Log the detected system locale. Called from platform bridges during init.
haskellLogLocale :: IO ()
haskellLogLocale = do
  raw <- getSystemLocale
  platformLog ("Locale raw: " <> raw)
  case parseLocale raw of
    Right locale  -> platformLog ("Locale parsed: " <> localeToText locale)
    Left failure  -> platformLog ("Locale parse failed: " <> Text.pack (show failure))

foreign export ccall haskellLogLocale :: IO ()

-- Internal helpers

-- | Split a locale tag on @\'-\'@ or @\'_\'@ into at most 2 parts
-- (language and optional region). Extra segments are dropped to keep
-- the result simple — we only care about language + region.
splitLocaleTag :: Text -> [Text]
splitLocaleTag input =
  let parts = Text.split (\c -> c == '-' || c == '_') input
  in  take 2 (filter (not . Text.null) parts)

-- | Validate and normalise a language code (2--3 lowercase alpha).
validateLanguage :: Text -> Either LocaleFailure Text
validateLanguage raw
  | len < 2 || len > 3    = Left (InvalidLanguageCode raw)
  | not (Text.all isAlpha raw) = Left (InvalidLanguageCode raw)
  | otherwise              = Right (Text.map toLower raw)
  where
    len :: Int
    len = Text.length raw

-- | Validate and normalise a region code.
-- Accepts 2 alpha characters (normalised to uppercase) or 3 digits.
validateRegion :: Text -> Either LocaleFailure Text
validateRegion raw
  | Text.length raw == 2 && Text.all isAlpha raw =
      Right (Text.map toUpper raw)
  | Text.length raw == 3 && Text.all isDigit raw =
      Right raw
  | otherwise = Left (InvalidRegionCode raw)
