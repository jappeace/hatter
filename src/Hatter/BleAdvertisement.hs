{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Advertisement payloads carried by BLE scan results (issue #238):
-- service data and manufacturer data, the two fields devices use to
-- broadcast identity and state without a connection (Eddystone frames
-- live in service data, iBeacon in manufacturer data, KKM beacons in
-- both).
--
-- The scan callback delivers the advertisement's raw AD structures
-- (@length : type : payload@, Bluetooth Core Specification Supplement
-- part A). Android hands them over exactly as received
-- (@ScanRecord.getBytes()@); iOS re-encodes CoreBluetooth's parsed
-- dictionary into the same format (see @BleBridgeIOS.m@), so this
-- parser is the single decoding path for both platforms.
module Hatter.BleAdvertisement
  ( BleAdvertisement(..)
  , NormalizedBleUuid(..)
  , ManufacturerId(..)
  , emptyBleAdvertisement
  , parseBleAdvertisement
  , serviceDataForUuid
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (intToDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word8, Word16)
import Unwitch.Convert.Word8 qualified as Word8

-- | A UUID string normalized to lowercase for comparisons.  UUIDs are
-- case-insensitive per the Bluetooth spec, but the platforms disagree
-- on the case they report (Android lowercase, iOS uppercase), so raw
-- strings must never be compared directly.  Constructed via
-- 'Hatter.Ble.normalizeBleServiceUuid' \/
-- 'Hatter.Ble.normalizeBleCharacteristicUuid', or lowercase by
-- construction in 'parseBleAdvertisement'; deliberately no 'IsString'
-- instance, a literal would bypass the normalization.
--
-- Decision: case-insensitivity is a dedicated normalized newtype
-- built only through smart constructors.  Alternatives considered:
-- lowercasing ad hoc at each comparison site (error-prone, exactly
-- how the original subscribe\/notify mismatch bug happened), and a
-- case-insensitive 'Ord' on the raw UUID newtypes (invisible at use
-- sites and surprising for anyone sorting or printing them).  A type
-- that cannot exist un-normalized makes the mistake unrepresentable.
newtype NormalizedBleUuid = NormalizedBleUuid { unNormalizedBleUuid :: Text }
  deriving (Show, Eq, Ord)

-- | The advertisement fields a scan result carries beyond name,
-- address and RSSI. Service data is keyed by the full 128-bit
-- 'NormalizedBleUuid' (16- and 32-bit UUIDs are expanded with the
-- Bluetooth base UUID); manufacturer data is keyed by the 16-bit
-- company identifier. Entries keep their advertisement order.
data BleAdvertisement = BleAdvertisement
  { advServiceData :: [(NormalizedBleUuid, ByteString)]
  , advManufacturerData :: [(ManufacturerId, ByteString)]
  } deriving (Show, Eq)

-- | A Bluetooth SIG company identifier, e.g. 0x004C (Apple) or
-- 0x0A53 (KKM).
newtype ManufacturerId = ManufacturerId { unManufacturerId :: Word16 }
  deriving (Show, Eq, Ord)

-- | An advertisement carrying no service or manufacturer data (also
-- what desktop's stubbed scan and payload-less advertisements parse
-- to).
emptyBleAdvertisement :: BleAdvertisement
emptyBleAdvertisement = BleAdvertisement
  { advServiceData = []
  , advManufacturerData = []
  }

-- | Parse raw AD structures. A zero length byte ends the data
-- (Android's @ScanRecord.getBytes()@ zero-pads to the fixed
-- advertisement buffer size); a structure whose length exceeds the
-- remaining bytes is dropped along with everything after it.
--
-- Decision: tolerate malformed input instead of failing. The bytes
-- come straight off the air from arbitrary third-party devices, so a
-- garbled advertisement must degrade to "no payload", never take the
-- app down or suppress the scan result carrying it.
parseBleAdvertisement :: ByteString -> BleAdvertisement
parseBleAdvertisement bytes =
  case BS.uncons bytes of
    Nothing -> emptyBleAdvertisement
    Just (lengthByte, afterLength) ->
      let structureLength = Word8.toInt lengthByte
      -- The zero check also guards the recursion: a zero-length
      -- structure would drop zero bytes and loop here forever.
      in if lengthByte == 0 || BS.length afterLength < structureLength
        then emptyBleAdvertisement
        else
          let structure = BS.take structureLength afterLength
              parsedRest = parseBleAdvertisement (BS.drop structureLength afterLength)
          in case BS.uncons structure of
            Nothing -> parsedRest
            Just (adType, payload) -> addAdStructure adType payload parsedRest

-- | Fold one AD structure into the advertisement parsed from the
-- bytes after it. Only the payload-bearing types are kept: service
-- data at each UUID width (0x16, 0x20, 0x21) and manufacturer data
-- (0xFF). Names, flags and service-class UUID lists are dropped; the
-- platforms already surface the name, and the UUID lists carry no
-- payload.
addAdStructure :: Word8 -> ByteString -> BleAdvertisement -> BleAdvertisement
addAdStructure adType payload advertisement = if
  | adType == 0x16 -> addServiceData 2 payload advertisement
  | adType == 0x20 -> addServiceData 4 payload advertisement
  | adType == 0x21 -> addServiceData 16 payload advertisement
  | adType == 0xFF -> addManufacturerData payload advertisement
  | otherwise -> advertisement

-- | Prepend one service data entry: a little-endian UUID of the given
-- byte width, then the payload. Too short to hold its UUID means a
-- malformed structure, which is skipped (see 'parseBleAdvertisement'
-- on tolerating air garbage).
addServiceData :: Int -> ByteString -> BleAdvertisement -> BleAdvertisement
addServiceData uuidWidth payload advertisement =
  if BS.length payload < uuidWidth
    then advertisement
    else
      let (uuidBytes, dataBytes) = BS.splitAt uuidWidth payload
      in advertisement { advServiceData =
                 (normalizedUuidFromLittleEndian uuidBytes, dataBytes)
                   : advServiceData advertisement }

-- | Prepend one manufacturer data entry: little-endian company
-- identifier, then the payload.
addManufacturerData :: ByteString -> BleAdvertisement -> BleAdvertisement
addManufacturerData payload advertisement =
  if BS.length payload < 2
    then advertisement
    else
      let companyId = Word8.toWord16 (BS.index payload 1) * 256
            + Word8.toWord16 (BS.index payload 0)
          dataBytes = BS.drop 2 payload
      in advertisement { advManufacturerData =
                 (ManufacturerId companyId, dataBytes)
                   : advManufacturerData advertisement }

-- | Look up a service data payload by UUID text
-- (case-insensitively). Accepts the same 128-bit form used across
-- "Hatter.Ble", e.g. @"00002080-0000-1000-8000-00805F9B34FB"@.
serviceDataForUuid :: Text -> BleAdvertisement -> Maybe ByteString
serviceDataForUuid uuid advertisement =
  lookup (NormalizedBleUuid (Text.toLower uuid)) (advServiceData advertisement)

-- | The last 12 bytes of the Bluetooth base UUID
-- (@xxxxxxxx-0000-1000-8000-00805F9B34FB@), which 16- and 32-bit
-- UUIDs are an alias into.
bluetoothBaseUuidTail :: ByteString
bluetoothBaseUuidTail = BS.pack
  [0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB]

-- | Render an advertisement UUID (2, 4 or 16 bytes little-endian on
-- air) as a full 128-bit 'NormalizedBleUuid' (the hex rendering is
-- lowercase by construction).
normalizedUuidFromLittleEndian :: ByteString -> NormalizedBleUuid
normalizedUuidFromLittleEndian uuidBytes =
  let bigEndian = BS.reverse uuidBytes
      full = if BS.length bigEndian == 16
        then bigEndian
        else BS.replicate (4 - BS.length bigEndian) 0x00
          <> bigEndian
          <> bluetoothBaseUuidTail
  in NormalizedBleUuid (formatUuid128 full)

-- | Format 16 big-endian bytes as @xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@.
formatUuid128 :: ByteString -> Text
formatUuid128 bigEndian =
  let hexText = Text.pack (concatMap hexByte (BS.unpack bigEndian))
  in Text.intercalate "-"
    [ Text.take 8 hexText
    , Text.take 4 (Text.drop 8 hexText)
    , Text.take 4 (Text.drop 12 hexText)
    , Text.take 4 (Text.drop 16 hexText)
    , Text.drop 20 hexText
    ]

-- | Two lowercase hex digits for one byte.
hexByte :: Word8 -> String
hexByte byte =
  let (high, low) = Word8.toInt byte `divMod` 16
  in [intToDigit high, intToDigit low]
