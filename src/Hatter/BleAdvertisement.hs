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
  , AdvertisementParseError(..)
  , AdvertisementParseErrors(..)
  , AdStructureOffset(..)
  , emptyBleAdvertisement
  , parseBleAdvertisement
  , serviceDataForUuid
  ) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty(..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.UUID.Types (UUID)
import Data.UUID.Types qualified as UUID
import Data.Word (Word8, Word16, Word32)
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

-- | Byte offset of an AD structure's length byte within the raw
-- advertisement: every parse error carries one, so a defect points
-- at the exact spot in the bytes.
newtype AdStructureOffset = AdStructureOffset { unAdStructureOffset :: Int }
  deriving (Show, Eq)

-- | One malformed AD structure: what failed, why, and where.
data AdvertisementParseError
  = -- | A structure declares more bytes than the advertisement still
    -- holds, so it (and anything after it) cannot be framed.
    AdStructureTruncated
      AdStructureOffset -- ^ Where the structure starts.
      Int -- ^ Length the structure declares.
      Int -- ^ Bytes actually remaining after the length byte.
  | -- | A service data structure too short to hold the UUID its AD
    -- type promises.
    ServiceDataUuidTruncated
      AdStructureOffset -- ^ Where the structure starts.
      Word8 -- ^ The AD type (0x16, 0x20 or 0x21).
      Int   -- ^ UUID width in bytes that AD type requires.
      Int   -- ^ Bytes the structure actually carries after the type.
  | -- | A manufacturer data structure too short to hold the 2-byte
    -- company identifier.
    ManufacturerDataTooShort
      AdStructureOffset -- ^ Where the structure starts.
      Int -- ^ Bytes the structure actually carries after the type.
  deriving (Show, Eq)

-- | Every defect found in one advertisement, in structure order.
newtype AdvertisementParseErrors = AdvertisementParseErrors
  { unAdvertisementParseErrors :: NonEmpty AdvertisementParseError }
  deriving (Show, Eq)

-- | An advertisement carrying no service or manufacturer data (also
-- what desktop's stubbed scan and payload-less advertisements parse
-- to).
emptyBleAdvertisement :: BleAdvertisement
emptyBleAdvertisement = BleAdvertisement
  { advServiceData = []
  , advManufacturerData = []
  }

-- | Parse raw AD structures. A zero length byte ends the data
-- cleanly: it is the value Android's @ScanRecord.getBytes()@ pads
-- the fixed advertisement buffer with, not a defect.
--
-- Decision: malformed structures fail the parse with every defect
-- found, in the signature, instead of being silently dropped: per
-- <https://jappie.me/failing-in-haskell.html failing in Haskell> we
-- want to know what fails, why and where (each error carries its
-- byte offset and the sizes involved), and the bytes come off the
-- air from arbitrary third-party devices, so defects WILL occur in
-- the field. The scan dispatch in "Hatter.Ble" logs the defects and
-- still delivers the scan result, so a garbled advertisement never
-- hides the device that sent it.
parseBleAdvertisement :: ByteString -> Either AdvertisementParseErrors BleAdvertisement
parseBleAdvertisement bytes =
  case parseAdStructuresFrom (AdStructureOffset 0) bytes of
    (advertisement, []) -> Right advertisement
    (_, firstDefect : moreDefects) ->
      Left (AdvertisementParseErrors (firstDefect :| moreDefects))

-- | Walk the AD structures, accumulating both the parsed entries and
-- every defect, with the byte offset threaded through for the error
-- reports. A truncated structure ends the walk (framing is lost); a
-- defect inside a well-framed structure skips only that structure.
parseAdStructuresFrom
  :: AdStructureOffset -> ByteString -> (BleAdvertisement, [AdvertisementParseError])
parseAdStructuresFrom offset bytes =
  case BS.uncons bytes of
    Nothing -> (emptyBleAdvertisement, [])
    Just (lengthByte, afterLength) ->
      let structureLength = Word8.toInt lengthByte
      in if
        -- Zero length is the padding terminator. The check also
        -- guards the recursion: a zero-length structure would drop
        -- zero bytes and loop here forever.
        | lengthByte == 0 -> (emptyBleAdvertisement, [])
        | BS.length afterLength < structureLength ->
            ( emptyBleAdvertisement
            , [AdStructureTruncated offset structureLength (BS.length afterLength)]
            )
        | otherwise ->
            -- In bounds: structureLength >= 1 was just established.
            let adType = BS.index afterLength 0
                payload = BS.take (structureLength - 1) (BS.drop 1 afterLength)
                (restAdvertisement, restDefects) =
                  parseAdStructuresFrom (nextStructureOffset offset structureLength)
                    (BS.drop structureLength afterLength)
            in case addAdStructure offset adType payload restAdvertisement of
              Right grown -> (grown, restDefects)
              Left defect -> (restAdvertisement, defect : restDefects)

-- | Fold one AD structure into the advertisement parsed from the
-- bytes after it, or say why it cannot be. Only the payload-bearing
-- types are kept: service data at each UUID width (0x16, 0x20, 0x21)
-- and manufacturer data (0xFF). Other AD types are legitimate
-- structures this module does not surface (names, flags,
-- service-class UUID lists), not defects: the platforms already
-- deliver the name and the rest carries no payload.
addAdStructure
  :: AdStructureOffset
  -> Word8
  -> ByteString
  -> BleAdvertisement
  -> Either AdvertisementParseError BleAdvertisement
addAdStructure offset adType payload advertisement = if
  | adType == 0x16 -> addServiceData offset adType 2 payload advertisement
  | adType == 0x20 -> addServiceData offset adType 4 payload advertisement
  | adType == 0x21 -> addServiceData offset adType 16 payload advertisement
  | adType == 0xFF -> addManufacturerData offset payload advertisement
  | otherwise -> Right advertisement

-- | Prepend one service data entry: a little-endian UUID of the given
-- byte width, then the payload. A structure too short to hold its
-- UUID is reported with the widths involved.
addServiceData
  :: AdStructureOffset
  -> Word8
  -> Int
  -> ByteString
  -> BleAdvertisement
  -> Either AdvertisementParseError BleAdvertisement
addServiceData offset adType uuidWidth payload advertisement =
  if BS.length payload < uuidWidth
    then Left (ServiceDataUuidTruncated offset adType uuidWidth (BS.length payload))
    else
      let (uuidBytes, dataBytes) = BS.splitAt uuidWidth payload
      in Right advertisement { advServiceData =
           (normalizedUuidFromLittleEndian uuidBytes, dataBytes)
             : advServiceData advertisement }

-- | Prepend one manufacturer data entry: little-endian company
-- identifier, then the payload. A structure too short to hold the
-- company identifier is reported with its actual size.
addManufacturerData
  :: AdStructureOffset
  -> ByteString
  -> BleAdvertisement
  -> Either AdvertisementParseError BleAdvertisement
addManufacturerData offset payload advertisement =
  if BS.length payload < 2
    then Left (ManufacturerDataTooShort offset (BS.length payload))
    else
      let companyId = Word8.toWord16 (BS.index payload 1) * 256
            + Word8.toWord16 (BS.index payload 0)
          dataBytes = BS.drop 2 payload
      in Right advertisement { advManufacturerData =
           (ManufacturerId companyId, dataBytes)
             : advManufacturerData advertisement }

-- | The offset of the structure after the current one: past the
-- length byte and the bytes it declares.
nextStructureOffset :: AdStructureOffset -> Int -> AdStructureOffset
nextStructureOffset (AdStructureOffset offset) structureLength =
  AdStructureOffset (offset + 1 + structureLength)

-- | Look up a service data payload by UUID text
-- (case-insensitively). Accepts the same 128-bit form used across
-- "Hatter.Ble", e.g. @"00002080-0000-1000-8000-00805F9B34FB"@.
serviceDataForUuid :: Text -> BleAdvertisement -> Maybe ByteString
serviceDataForUuid uuid advertisement =
  lookup (NormalizedBleUuid (Text.toLower uuid)) (advServiceData advertisement)

-- | Words 2 to 4 of the Bluetooth base UUID
-- (@xxxxxxxx-0000-1000-8000-00805F9B34FB@), which 16- and 32-bit
-- UUIDs are an alias into.
bluetoothBaseUuidWord2 :: Word32
bluetoothBaseUuidWord2 = 0x00001000

bluetoothBaseUuidWord3 :: Word32
bluetoothBaseUuidWord3 = 0x80000080

bluetoothBaseUuidWord4 :: Word32
bluetoothBaseUuidWord4 = 0x5F9B34FB

-- | Render an advertisement UUID (2, 4 or 16 bytes little-endian on
-- air) as a full 128-bit 'NormalizedBleUuid'; 'UUID.toText' renders
-- the canonical lowercase form.
normalizedUuidFromLittleEndian :: ByteString -> NormalizedBleUuid
normalizedUuidFromLittleEndian uuidBytes =
  let bigEndian = BS.reverse uuidBytes
  in NormalizedBleUuid (UUID.toText (if BS.length bigEndian == 16
    then uuidFromBigEndianBytes bigEndian
    else UUID.fromWords
      (word32BigEndianAt (BS.replicate (4 - BS.length bigEndian) 0x00 <> bigEndian) 0)
      bluetoothBaseUuidWord2
      bluetoothBaseUuidWord3
      bluetoothBaseUuidWord4))

-- | Build a 'UUID' from its 16 big-endian bytes.
uuidFromBigEndianBytes :: ByteString -> UUID
uuidFromBigEndianBytes bigEndian = UUID.fromWords
  (word32BigEndianAt bigEndian 0)
  (word32BigEndianAt bigEndian 4)
  (word32BigEndianAt bigEndian 8)
  (word32BigEndianAt bigEndian 12)

-- | Big-endian 32-bit word starting at the given offset (bounds
-- already checked by callers).
word32BigEndianAt :: ByteString -> Int -> Word32
word32BigEndianAt bytes offset =
  Word8.toWord32 (BS.index bytes offset) `shiftL` 24
    .|. Word8.toWord32 (BS.index bytes (offset + 1)) `shiftL` 16
    .|. Word8.toWord32 (BS.index bytes (offset + 2)) `shiftL` 8
    .|. Word8.toWord32 (BS.index bytes (offset + 3))
