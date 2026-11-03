{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE ImportQualifiedPost #-}
-- | Opaque callback handles for the widget system.
--
-- Instead of embedding raw @IO ()@ closures inside widget configs,
-- the framework uses typed handles ('Action', 'OnChange') that
-- reference entries in a shared 'ActionState' registry.  Because
-- the handles are plain 'Int32' newtypes they derive 'Eq', which
-- lets 'Widget' derive 'Eq' naturally — enabling O(1) "skip if
-- unchanged" diff in the render engine.
--
-- Users create handles once at init time via the restricted 'ActionM'
-- monad, then embed them in widget configs.  The callback 'IntMap's
-- are never cleared during rendering, eliminating the atomicity gap
-- of the old clear-and-rebuild strategy.
module Hatter.Action
  ( -- * Handles
    Action(..)
  , OnChange(..)
  , OnScroll(..)
  , ListPosition(..)
    -- * Callback registry
  , ActionState(..)
    -- * Restricted construction monad
  , ActionM
  , createAction
  , createOnChange
  , createOnScroll
  , liftIO
    -- * Framework-internal
  , newActionState
  , runActionM
  , lookupAction
  , lookupTextAction
  , lookupScrollAction
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Reader (ReaderT(..))
import Data.IORef (IORef, newIORef, readIORef, modifyIORef')
import Data.Int (Int32)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.Text (Text)
import Unwitch.Convert.Int32 qualified as Int32

-- | An opaque handle to a click / tap callback.
-- Carries only an 'Int32' identifier, so it derives 'Eq' and 'Show'.
newtype Action = Action { actionId :: Int32 }
  deriving stock (Eq, Show)

-- | An opaque handle to a text-change callback.
-- Carries only an 'Int32' identifier, so it derives 'Eq' and 'Show'.
newtype OnChange = OnChange { onChangeId :: Int32 }
  deriving stock (Eq, Show)

-- | An opaque handle to a callback that hears where a list is.
newtype OnScroll = OnScroll { onScrollId :: Int32 }
  deriving stock (Eq, Show)

-- | What a scrolling list shows. The platforms report these by their
-- numbers, from 0. Near its start is within a screen of it, so what comes
-- before can be there before it is. A list near its start is reported again
-- when its items change, as what came in may not have taken it away.
data ListPosition
  = ListStart
    -- ^ Near its start.
  | ListMiddle
  | ListEnd
    -- ^ At its end, away from its start.
  | ListBoth
    -- ^ At its end and near its start, as a short list is.
  deriving stock (Eq, Show, Enum, Bounded)

-- | Mutable callback storage shared between 'ActionM' (creation)
-- and the render/dispatch engine (lookup).
data ActionState = ActionState
  { asCallbacks       :: IORef (IntMap (IO ()))
    -- ^ Click/tap callbacks keyed by handle ID.
  , asTextCallbacks   :: IORef (IntMap (Text -> IO ()))
    -- ^ Text-change callbacks keyed by handle ID.
  , asScrollCallbacks :: IORef (IntMap (ListPosition -> IO ()))
    -- ^ List position callbacks keyed by handle ID.
  , asNextId          :: IORef Int32
    -- ^ Monotonically increasing counter for the next handle ID.
  }

-- | Create a fresh empty 'ActionState'.
newActionState :: IO ActionState
newActionState = do
  callbacks       <- newIORef IntMap.empty
  textCallbacks   <- newIORef IntMap.empty
  scrollCallbacks <- newIORef IntMap.empty
  nextId          <- newIORef 0
  pure ActionState
    { asCallbacks       = callbacks
    , asTextCallbacks   = textCallbacks
    , asScrollCallbacks = scrollCallbacks
    , asNextId          = nextId
    }

-- | A restricted monad for creating callback handles.
-- The constructor is hidden so that users cannot construct arbitrary
-- 'ActionM' values — they must go through 'createAction' and
-- 'createOnChange'.
newtype ActionM a = ActionM (ActionState -> IO a)
  deriving (Functor, Applicative, Monad, MonadIO)
    via (ReaderT ActionState IO)

-- | Register a click/tap callback and return its opaque handle.
createAction :: IO () -> ActionM Action
createAction callback = ActionM $ \state -> do
  handleId <- readIORef (asNextId state)
  modifyIORef' (asCallbacks state) (IntMap.insert (Int32.toInt handleId) callback)
  modifyIORef' (asNextId state) (+ 1)
  pure (Action handleId)

-- | Register a text-change callback and return its opaque handle.
createOnChange :: (Text -> IO ()) -> ActionM OnChange
createOnChange callback = ActionM $ \state -> do
  handleId <- readIORef (asNextId state)
  modifyIORef' (asTextCallbacks state) (IntMap.insert (Int32.toInt handleId) callback)
  modifyIORef' (asNextId state) (+ 1)
  pure (OnChange handleId)

-- | Register a callback for where a list is, and return its opaque handle.
createOnScroll :: (ListPosition -> IO ()) -> ActionM OnScroll
createOnScroll callback = ActionM $ \state -> do
  handleId <- readIORef (asNextId state)
  modifyIORef' (asScrollCallbacks state) (IntMap.insert (Int32.toInt handleId) callback)
  modifyIORef' (asNextId state) (+ 1)
  pure (OnScroll handleId)

-- | Run an 'ActionM' computation against a given 'ActionState'.
runActionM :: ActionState -> ActionM a -> IO a
runActionM state (ActionM f) = f state

-- | Look up a click/tap callback by handle ID.
-- Returns 'Nothing' if the ID is not registered.
lookupAction :: ActionState -> Int32 -> IO (Maybe (IO ()))
lookupAction state handleId = do
  callbacks <- readIORef (asCallbacks state)
  pure (IntMap.lookup (Int32.toInt handleId) callbacks)

-- | Look up a text-change callback by handle ID.
-- Returns 'Nothing' if the ID is not registered.
lookupTextAction :: ActionState -> Int32 -> IO (Maybe (Text -> IO ()))
lookupTextAction state handleId = do
  callbacks <- readIORef (asTextCallbacks state)
  pure (IntMap.lookup (Int32.toInt handleId) callbacks)

-- | Look up a list position callback by handle ID.
-- Returns 'Nothing' if the ID is not registered.
lookupScrollAction :: ActionState -> Int32 -> IO (Maybe (ListPosition -> IO ()))
lookupScrollAction state handleId = do
  callbacks <- readIORef (asScrollCallbacks state)
  pure (IntMap.lookup (Int32.toInt handleId) callbacks)
