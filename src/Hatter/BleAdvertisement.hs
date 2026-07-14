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
  , BleAdvertisementWithErrors(..)
  , UUID
  , ManufacturerId(..)
  , AdvertisementParseError(..)
  , AdvertisementParseErrors(..)
  , AdStructureOffset(..)
  , AdStructureTruncation(..)
  , ServiceDataTruncation(..)
  , ManufacturerDataTruncation(..)
  , emptyBleAdvertisement
  , parseBleAdvertisement
  , serviceDataForUuid
  ) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty(..))
import Data.UUID.Types (UUID)
import Data.UUID.Types qualified as UUID
import Data.Word (Word8, Word16, Word32)
import Unwitch.Convert.Word8 qualified as Word8

-- | The advertisement fields a scan result carries beyond name,
-- address and RSSI. Service data is keyed by the full 128-bit 'UUID'
-- (16- and 32-bit UUIDs are expanded with the Bluetooth base UUID);
-- comparisons are on the binary value, so platform case differences
-- cannot matter. Manufacturer data is keyed by the 16-bit company
-- identifier. Entries keep their advertisement order.
data BleAdvertisement = BleAdvertisement
  { advServiceData :: [(UUID, ByteString)]
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

-- | One malformed AD structure: what failed, why, and where. Every
-- constructor wraps its own record, so the fields are reachable with
-- total record accessors.
data AdvertisementParseError
  = -- | A structure declares more bytes than the advertisement still
    -- holds, so it (and anything after it) cannot be framed.
    AdStructureTruncated AdStructureTruncation
  | -- | A service data structure too short to hold the UUID its AD
    -- type promises.
    ServiceDataUuidTruncated ServiceDataTruncation
  | -- | A manufacturer data structure too short to hold the 2-byte
    -- company identifier.
    ManufacturerDataTooShort ManufacturerDataTruncation
  deriving (Show, Eq)

-- | Details of a structure that runs past the advertisement's end.
data AdStructureTruncation = AdStructureTruncation
  { truncationOffset :: AdStructureOffset
    -- ^ Where the structure starts.
  , truncationDeclaredLength :: Int
    -- ^ Length the structure declares.
  , truncationRemainingBytes :: Int
    -- ^ Bytes actually remaining after the length byte.
  } deriving (Show, Eq)

-- | Details of a service data structure shorter than its UUID.
data ServiceDataTruncation = ServiceDataTruncation
  { serviceDataOffset :: AdStructureOffset
    -- ^ Where the structure starts.
  , serviceDataAdType :: Word8
    -- ^ The AD type (0x16, 0x20 or 0x21).
  , serviceDataUuidWidth :: Int
    -- ^ UUID width in bytes that AD type requires.
  , serviceDataPayloadLength :: Int
    -- ^ Bytes the structure actually carries after the type.
  } deriving (Show, Eq)

-- | Details of a manufacturer data structure shorter than the
-- company identifier.
data ManufacturerDataTruncation = ManufacturerDataTruncation
  { manufacturerDataOffset :: AdStructureOffset
    -- ^ Where the structure starts.
  , manufacturerDataPayloadLength :: Int
    -- ^ Bytes the structure actually carries after the type.
  } deriving (Show, Eq)

-- | Every defect found in one advertisement, in structure order.
newtype AdvertisementParseErrors = AdvertisementParseErrors
  { unAdvertisementParseErrors :: NonEmpty AdvertisementParseError }
  deriving (Show, Eq)

-- | A parse that found defects, without discarding the salvage: AD
-- structures are independent, so the partial advertisement carries
-- every structure that still parsed. It is only empty when the very
-- first structure was truncated or every structure was defective.
data BleAdvertisementWithErrors = BleAdvertisementWithErrors
  { partialAdvertisement :: BleAdvertisement
  , advertisementParseErrors :: AdvertisementParseErrors
  } deriving (Show, Eq)

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
-- the field. The Left still carries the salvaged partial
-- advertisement ('BleAdvertisementWithErrors'): the link layer's CRC
-- already dropped radio corruption, so a defect here is a firmware
-- quirk in one structure and the well-formed rest remains
-- trustworthy (a beacon with one garbled structure must not lose its
-- valid service data). The scan dispatch in "Hatter.Ble" logs the
-- defects and still delivers the scan result, so a garbled
-- advertisement never hides the device that sent it.
parseBleAdvertisement :: ByteString -> Either BleAdvertisementWithErrors BleAdvertisement
parseBleAdvertisement bytes =
  case parseAdStructuresFrom (AdStructureOffset 0) bytes of
    (advertisement, []) -> Right advertisement
    (advertisement, firstDefect : moreDefects) ->
      Left (BleAdvertisementWithErrors advertisement
        (AdvertisementParseErrors (firstDefect :| moreDefects)))

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
            , [AdStructureTruncated (AdStructureTruncation offset structureLength
                (BS.length afterLength))]
            )
        | otherwise ->
            let (structure, remainder) = BS.splitAt structureLength afterLength
                (restAdvertisement, restDefects) =
                  parseAdStructuresFrom (nextStructureOffset offset structureLength)
                    remainder
            in case BS.uncons structure of
              -- Unreachable: structureLength >= 1 (the zero branch
              -- above) with enough bytes remaining (the truncation
              -- branch above), so the structure has its type byte.
              Nothing -> (restAdvertisement, restDefects)
              Just (adType, payload) ->
                case addAdStructure offset adType payload restAdvertisement of
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
-- UUID is reported with the widths involved; the check IS
-- 'uuidFromLittleEndian' declining the short slice, so there is
-- exactly one place deciding what a valid UUID is.
addServiceData
  :: AdStructureOffset
  -> Word8
  -> Int
  -> ByteString
  -> BleAdvertisement
  -> Either AdvertisementParseError BleAdvertisement
addServiceData offset adType uuidWidth payload advertisement =
  let (uuidBytes, dataBytes) = BS.splitAt uuidWidth payload
  in case uuidFromLittleEndian uuidWidth uuidBytes of
    Nothing -> Left (ServiceDataUuidTruncated
      (ServiceDataTruncation offset adType uuidWidth (BS.length payload)))
    Just uuid -> Right advertisement { advServiceData =
      (uuid, dataBytes) : advServiceData advertisement }

-- | Prepend one manufacturer data entry: little-endian company
-- identifier, then the payload. A structure too short to hold the
-- company identifier is reported with its actual size.
addManufacturerData
  :: AdStructureOffset
  -> ByteString
  -> BleAdvertisement
  -> Either AdvertisementParseError BleAdvertisement
addManufacturerData offset payload advertisement =
  case (BS.indexMaybe payload 0, BS.indexMaybe payload 1) of
    (Just lowByte, Just highByte) ->
      let companyId = Word8.toWord16 highByte * 256 + Word8.toWord16 lowByte
          dataBytes = BS.drop 2 payload
      in Right advertisement { advManufacturerData =
           (ManufacturerId companyId, dataBytes)
             : advManufacturerData advertisement }
    (Just _, Nothing) -> Left (ManufacturerDataTooShort
      (ManufacturerDataTruncation offset (BS.length payload)))
    (Nothing, Just _) -> Left (ManufacturerDataTooShort
      (ManufacturerDataTruncation offset (BS.length payload)))
    (Nothing, Nothing) -> Left (ManufacturerDataTooShort
      (ManufacturerDataTruncation offset (BS.length payload)))

-- | The offset of the structure after the current one: past the
-- length byte and the bytes it declares.
nextStructureOffset :: AdStructureOffset -> Int -> AdStructureOffset
nextStructureOffset (AdStructureOffset offset) structureLength =
  AdStructureOffset (offset + 1 + structureLength)

-- | Look up a service data payload by its service 'UUID'. Constants
-- are best built with the total 'UUID.fromWords' (e.g. KKM's 0x2080
-- is @fromWords 0x00002080 0x00001000 0x80000080 0x5F9B34FB@);
-- runtime strings parse via 'UUID.fromText'.
serviceDataForUuid :: UUID -> BleAdvertisement -> Maybe ByteString
serviceDataForUuid uuid advertisement =
  lookup uuid (advServiceData advertisement)

-- | Words 2 to 4 of the Bluetooth base UUID
-- (@xxxxxxxx-0000-1000-8000-00805F9B34FB@), which 16- and 32-bit
-- UUIDs are an alias into.
bluetoothBaseUuidWord2 :: Word32
bluetoothBaseUuidWord2 = 0x00001000

bluetoothBaseUuidWord3 :: Word32
bluetoothBaseUuidWord3 = 0x80000080

bluetoothBaseUuidWord4 :: Word32
bluetoothBaseUuidWord4 = 0x5F9B34FB

-- | The 'UUID' of an advertisement's service data structure, from
-- the declared byte width and the little-endian on-air slice.
-- Nothing when the slice does not have exactly the declared width,
-- or the width is not one of the on-air widths (2, 4 or 16): the
-- declared width MUST be checked against the slice, not inferred
-- from it, or a 128-bit structure truncated down to two bytes would
-- pass as a valid 16-bit UUID. This is how 'addServiceData' detects
-- a structure too short for its UUID.
uuidFromLittleEndian :: Int -> ByteString -> Maybe UUID
uuidFromLittleEndian declaredWidth uuidBytes =
  let bigEndian = BS.reverse uuidBytes
  in if BS.length bigEndian /= declaredWidth
    then Nothing
    else if declaredWidth == 16
      then uuidFromBigEndianBytes bigEndian
      else if declaredWidth == 2 || declaredWidth == 4
        then fmap
          (\value -> UUID.fromWords value
            bluetoothBaseUuidWord2
            bluetoothBaseUuidWord3
            bluetoothBaseUuidWord4)
          (word32BigEndianAt
            (BS.replicate (4 - declaredWidth) 0x00 <> bigEndian) 0)
        else Nothing

-- | Build a 'UUID' from its 16 big-endian bytes; Nothing when fewer
-- bytes are available.
uuidFromBigEndianBytes :: ByteString -> Maybe UUID
uuidFromBigEndianBytes bigEndian = UUID.fromWords
  <$> word32BigEndianAt bigEndian 0
  <*> word32BigEndianAt bigEndian 4
  <*> word32BigEndianAt bigEndian 8
  <*> word32BigEndianAt bigEndian 12

-- | Big-endian 32-bit word starting at the given offset; Nothing
-- when the four bytes are not all present.
word32BigEndianAt :: ByteString -> Int -> Maybe Word32
word32BigEndianAt bytes offset = do
  byte0 <- BS.indexMaybe bytes offset
  byte1 <- BS.indexMaybe bytes (offset + 1)
  byte2 <- BS.indexMaybe bytes (offset + 2)
  byte3 <- BS.indexMaybe bytes (offset + 3)
  pure (Word8.toWord32 byte0 `shiftL` 24
    .|. Word8.toWord32 byte1 `shiftL` 16
    .|. Word8.toWord32 byte2 `shiftL` 8
    .|. Word8.toWord32 byte3)
