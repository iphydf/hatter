-- | Hatter's Qt Quick platform, for Linux, macOS and Windows.
--
-- An app's program is its @Main@ module with the same
-- @main :: IO (Ptr AppContext)@ as on Android, built with @-no-hs-main@
-- against this package: its C @main@ starts Qt and the app, and shows the
-- app in a window.
module Hatter.Qt
  ( setResources
  ) where

import Foreign.C.String (CString, withCString)

foreign import ccall "hatter_qt_set_resources" c_setResources :: CString -> IO ()

-- | Where the app's icons are: its Android vector drawables, @\<name\>.xml@,
-- as an 'ImageResource' names them. Before the app shows any.
setResources :: FilePath -> IO ()
setResources dir = withCString dir c_setResources
