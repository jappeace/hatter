{-# LANGUAGE OverloadedStrings #-}
module HaskellMobile.I18n
  ( Key(..)
  , Translations
  , parseTranslationFile
  , translate
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import HaskellMobile.Locale (Locale(..))
import Toml (parse, Table'(MkTable), Value, forgetTableAnns)
import Toml qualified

-- | Translation key (matches TOML keys). Newtype for type safety.
newtype Key = Key { unKey :: Text }
  deriving (Show, Eq, Ord)

-- | Map from locale to its translation table.
type Translations = Map Locale (Map Key Text)

-- | Parse TOML content into a flat key-value translation map.
--
-- Expects flat TOML: @key = \"translated string\"@.
-- Non-string values are rejected with an error message.
parseTranslationFile :: Text -> Either String (Map Key Text)
parseTranslationFile content =
  case parse content of
    Left parseError -> Left parseError
    Right posTable ->
      let MkTable entries = forgetTableAnns posTable
      in  extractStrings (Map.toList entries)

-- | Look up a translation key with fallback chain:
--
--   1. Exact locale match (e.g., @\"nl-NL\"@)
--   2. Language-only match (e.g., @\"nl\"@)
--   3. 'Nothing'
translate :: Translations -> Locale -> Key -> Maybe Text
translate translations locale key =
  case lookupKey translations locale key of
    Just foundText -> Just foundText
    Nothing        -> lookupKey translations (locale { locRegion = Nothing }) key

-- Internal helpers

lookupKey :: Translations -> Locale -> Key -> Maybe Text
lookupKey translations locale key =
  Map.lookup locale translations >>= Map.lookup key

-- | Extract only string values from a TOML table, rejecting non-strings.
extractStrings :: [(Text, ((), Value))] -> Either String (Map Key Text)
extractStrings = go Map.empty
  where
    go :: Map Key Text -> [(Text, ((), Value))] -> Either String (Map Key Text)
    go accumulator [] = Right accumulator
    go accumulator ((tomlKey, ((), value)) : rest) =
      case value of
        Toml.Text textValue ->
          go (Map.insert (Key tomlKey) textValue accumulator) rest
        _ ->
          Left ("non-string value for key: " ++ show tomlKey)
