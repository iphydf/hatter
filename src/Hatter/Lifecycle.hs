{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
module Hatter.Lifecycle
  ( LifecycleEvent(..)
  , lifecycleFromInt
  , lifecycleToInt
  , MobileContext(..)
  , CallButton(..)
  , PickedFile(..)
  , defaultMobileContext
  , loggingMobileContext
  , platformLog
  , newMobileContext
  , freeMobileContext
  )
where

import Control.Exception (SomeException)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text, pack, unpack)
import Data.Word (Word64)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt(..))
import Foreign.StablePtr (StablePtr, newStablePtr, freeStablePtr)

-- | Lifecycle events that can be received from the host platform.
-- Maps to Android Activity lifecycle and iOS ScenePhase transitions.
data LifecycleEvent
  = Create
  | Start
  | Resume
  | Pause
  | Stop
  | Destroy
  | LowMemory
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | Convert a C int to a 'LifecycleEvent'. Returns 'Nothing' for unknown codes.
lifecycleFromInt :: CInt -> Maybe LifecycleEvent
lifecycleFromInt 0 = Just Create
lifecycleFromInt 1 = Just Start
lifecycleFromInt 2 = Just Resume
lifecycleFromInt 3 = Just Pause
lifecycleFromInt 4 = Just Stop
lifecycleFromInt 5 = Just Destroy
lifecycleFromInt 6 = Just LowMemory
lifecycleFromInt _ = Nothing

-- | Convert a 'LifecycleEvent' to its C int code (0--6).
lifecycleToInt :: LifecycleEvent -> CInt
lifecycleToInt Create    = 0
lifecycleToInt Start     = 1
lifecycleToInt Resume    = 2
lifecycleToInt Pause     = 3
lifecycleToInt Stop      = 4
lifecycleToInt Destroy   = 5
lifecycleToInt LowMemory = 6

-- | Opaque context holding user-defined callbacks for mobile platform events.
-- Passed through the C FFI as a 'StablePtr', so each platform bridge
-- (or test) owns its own independent context — no global mutable state.
data MobileContext = MobileContext
  { onLifecycle :: LifecycleEvent -> IO ()
  , onError     :: SomeException -> IO ()
  , onBack      :: IO Bool
    -- ^ The user pressed Back. 'True' if the app handled it, after
    -- which it renders again. 'False' leaves it to the platform.
  , onNotificationOpened :: Text -> IO ()
    -- ^ The user tapped the notification with this key, which opened
    -- the app. It renders again after.
  , onCallButton :: Text -> CallButton -> IO ()
    -- ^ The user pressed a button of the ringing notification with this
    -- key. Answering opens the app, which renders again after.
  , onFilePicked :: PickedFile -> IO ()
    -- ^ The user picked a file, after 'Hatter.pickFile'. It renders again
    -- after.
  , onPicturePicked :: ByteString -> IO ()
    -- ^ The user picked a picture, after 'Hatter.pickPicture', as a square
    -- PNG. It renders again after.
  , onRendered :: Word64 -> IO ()
    -- ^ A render took this many nanoseconds, from asking for the view to
    -- the platform having it.
  }

-- | A button of a ringing notification, or of the call going on.
data CallButton = Answer | Decline | End
  deriving (Show, Eq)

-- | A copy of a file the user picked, which the app may move or delete.
data PickedFile = PickedFile
  { pickedPath :: FilePath
    -- ^ ASCII, whatever the file is called.
  , pickedName :: Text
  , pickedSize :: Integer
  } deriving (Show, Eq)

-- | A no-op context. Suitable as a default when no callbacks are needed.
-- Logs errors via 'platformLog' by default so they are not silently swallowed.
defaultMobileContext :: MobileContext
defaultMobileContext = MobileContext
  { onLifecycle = \_ -> pure ()
  , onError     = \exc -> platformLog ("Error: " <> pack (show exc))
  , onBack      = pure False
  , onNotificationOpened = \_ -> pure ()
  , onCallButton = \_ _ -> pure ()
  , onFilePicked = \_ -> pure ()
  , onPicturePicked = \_ -> pure ()
  , onRendered = \_ -> pure ()
  }

foreign import ccall "hatterLog" c_hatterLog :: CString -> IO ()

-- | Log a message using the platform-appropriate mechanism:
-- Android logcat, Apple os_log, or stderr on desktop.
platformLog :: Text -> IO ()
platformLog msg = withCString (unpack msg) c_hatterLog

-- | A context that logs every lifecycle event via 'platformLog'.
loggingMobileContext :: MobileContext
loggingMobileContext = MobileContext
  { onLifecycle = \event -> platformLog ("Lifecycle: " <> pack (show event))
  , onError     = \exc -> platformLog ("Error: " <> pack (show exc))
  , onBack      = pure False
  , onNotificationOpened = \key -> platformLog ("Notification opened: " <> key)
  , onCallButton = \key button -> platformLog ("Call button " <> pack (show button) <> ": " <> key)
  , onFilePicked = \picked -> platformLog ("File picked: " <> pickedName picked)
  , onPicturePicked = \png -> platformLog ("Picture picked: " <> pack (show (BS.length png)) <> " bytes")
  , onRendered = \_ -> pure ()
  }

-- | Pin a 'MobileContext' on the GHC heap and return a 'StablePtr' to it.
-- The caller must eventually call 'freeMobileContext' to release the pointer.
newMobileContext :: MobileContext -> IO (StablePtr MobileContext)
newMobileContext = newStablePtr

-- | Release a 'StablePtr' previously created by 'newMobileContext'.
freeMobileContext :: StablePtr MobileContext -> IO ()
freeMobileContext = freeStablePtr
