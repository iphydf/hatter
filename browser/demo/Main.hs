{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings   #-}
-- | A Hatter app for trying the browser platform: a counter, a text field,
-- and a list kept at its end as notes come in. The notes are kept in the
-- app's files, so they are there again after a reload.
module Main (main) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Hatter (MobileApp (..), createAction, createOnChange, loggingMobileContext, newActionState, runActionM)
import Hatter.Browser (runBrowser)
import Hatter.FilesDir (getAppFilesDir)
import Hatter.Widget

foreign export javascript "start" start :: IO ()

start :: IO ()
start = runBrowser demo

-- | The page starts the app with 'start'.
main :: IO ()
main = pure ()

demo :: IO MobileApp
demo = do
  actions <- newActionState
  count <- newIORef (0 :: Int)
  draft <- newIORef Text.empty
  file <- (<> "/notes") <$> getAppFilesDir
  notes <- newIORef . either (const []) (Text.lines . Text.decodeUtf8Lenient)
    =<< (try (BS.readFile file) :: IO (Either IOException BS.ByteString))
  let save = BS.writeFile file . Text.encodeUtf8 . Text.unlines =<< readIORef notes
  (more, less, add, typed) <- runActionM actions $ (,,,)
    <$> createAction (modifyIORef' count (+ 1))
    <*> createAction (modifyIORef' count (subtract 1))
    <*> createAction (readIORef draft >>= \note -> modifyIORef' notes (<> [note]) >> save >> writeIORef draft Text.empty)
    <*> createOnChange (writeIORef draft)
  let view n note written = column
        [ Styled defaultStyle { wsPadding = Just 16 } (text ("Count: " <> Text.pack (show n)))
        , row [button "+" more, button "-" less]
        , TextInput TextInputConfig
            { tiInputType = InputText
            , tiHint = "A note"
            , tiValue = note
            , tiOnChange = typed
            , tiFontConfig = Nothing
            , tiTextColor = Nothing
            , tiAutoFocus = True
            }
        , button "Add" add
        , Styled defaultStyle { wsWeight = Just 1, wsKeepAtEnd = Just True }
            (LazyColumn [keyedItem i (Styled defaultStyle { wsPadding = Just 8 } (text line)) | (i, line) <- zip [0 ..] written])
        ]
  pure MobileApp
    { maContext = loggingMobileContext
    , maView = \_ -> view <$> readIORef count <*> readIORef draft <*> readIORef notes
    , maActionState = actions
    }
