{-# LANGUAGE DeriveDataTypeable, GeneralizedNewtypeDeriving, ScopedTypeVariables #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Server.BlobStorage
-- Copyright   :  Duncan Coutts <duncan@haskell.org>
--
-- Maintainer  :  Duncan Coutts <duncan@haskell.org>
-- Stability   :  alpha
-- Portability :  portable
--
-- Persistent storage for blobs of data.
--
module Distribution.Server.Framework.BlobStorage (
    BlobStorage,
    BlobId,
    blobMd5,
    open,
    add,
    addWith,
    consumeFile,
    consumeFileWith,
    fetch,
    filepath,
  ) where

import Distribution.Server.Framework.MemSize

import qualified Data.ByteString.Lazy as BS
import Data.ByteString.Lazy (ByteString)
import Data.Digest.Pure.MD5 (MD5Digest, md5)
import Data.Typeable (Typeable)
import Data.Serialize
import System.FilePath ((</>))
import Control.Exception (handle, throwIO, evaluate, bracket)
import Control.Monad
import Data.SafeCopy
import System.Directory
import System.IO

-- | An id for a blob. The content of the blob is stable.
--
newtype BlobId = BlobId MD5Digest
  deriving (Eq, Ord, Show, Serialize, Typeable)

blobMd5 :: BlobId -> String
blobMd5 (BlobId digest) = show digest

instance SafeCopy BlobId where
  putCopy = contain . put
  getCopy = contain get

instance MemSize BlobId where
  memSize _ = 7 --TODO: pureMD5 package wastes 5 words!

-- | A persistent blob storage area. Blobs can be added and retrieved but
-- not removed or modified.
--
newtype BlobStorage = BlobStorage FilePath -- ^ location of the store

filepath :: BlobStorage -> BlobId -> FilePath
filepath (BlobStorage storeDir) (BlobId hash)
    = storeDir </> take 2 str </> str
    where str = show hash

incomingDir :: BlobStorage -> FilePath
incomingDir (BlobStorage storeDir) = storeDir </> "incoming"

-- | Add a blob into the store. The result is a 'BlobId' that can be used
-- later with 'fetch' to retrieve the blob content.
--
-- * This operation is idempotent. That is, adding the same content again
--   gives the same 'BlobId'.
--
add :: BlobStorage -> ByteString -> IO BlobId
add store content =
  withIncoming store content $ \_ blobId -> return (blobId, True)

-- | Like 'add' but we get another chance to make another pass over the input
-- 'ByteString'.
--
-- What happens is that we stream the input into a temp file in an incoming
-- area. Then we can make a second pass over it to do some validation or
-- processing. If the validator decides to reject then we rollback and the
-- blob is not entered into the store. If it accepts then the blob is added
-- and the 'BlobId' is returned.
--
addWith :: BlobStorage -> ByteString
        -> (ByteString -> IO (Either error result))
        -> IO (Either error (result, BlobId))
addWith store content check =
  withIncoming store content $ \file blobId -> do
    content' <- BS.readFile file
    result <- check content'
    case result of
      Left  err -> return (Left  err,          False)
      Right res -> return (Right (res, blobId), True)

-- | Similar to 'add' but by /moving/ a file into the blob store. So this
-- is a destructive operation. Since it works by renaming the file, the input
-- file must live in the same file system as the blob store. 
--
consumeFile :: BlobStorage -> FilePath -> IO BlobId
consumeFile store filePath =
  withIncomingFile store filePath $ \_ blobId -> return (blobId, True)

consumeFileWith :: BlobStorage -> FilePath
                -> (ByteString -> IO (Either error result))
                -> IO (Either error (result, BlobId))
consumeFileWith store filePath check =
  withIncomingFile store filePath $ \file blobId -> do
    content' <- BS.readFile file
    result <- check content'
    case result of
      Left  err -> return (Left  err,          False)
      Right res -> return (Right (res, blobId), True)

hBlobId :: Handle -> IO BlobId
hBlobId hnd = evaluate . BlobId . md5 =<< BS.hGetContents hnd

fileBlobId :: FilePath -> IO BlobId
fileBlobId file = bracket (openBinaryFile file ReadMode) hClose hBlobId

withIncoming :: BlobStorage -> ByteString
              -> (FilePath -> BlobId -> IO (a, Bool))
              -> IO a
withIncoming store content action = do
    (file, hnd) <- openBinaryTempFile (incomingDir store) "new"
    handleExceptions file hnd $ do
        -- TODO: calculate the md5 and write to the temp file in one pass:
        BS.hPut hnd content
        hSeek hnd AbsoluteSeek 0
        blobId <- hBlobId hnd
        hClose hnd
        withIncoming' store file blobId action
  where
    handleExceptions tmpFile tmpHandle =
      handle $ \err -> do
        hClose tmpHandle
        removeFile tmpFile
        throwIO (err :: IOError)

withIncomingFile :: BlobStorage
                 -> FilePath
                 -> (FilePath -> BlobId -> IO (a, Bool))
                 -> IO a
withIncomingFile store file action =
    do blobId <- fileBlobId file
       withIncoming' store file blobId action

withIncoming' :: BlobStorage -> FilePath -> BlobId -> (FilePath -> BlobId -> IO (a, Bool)) -> IO a
withIncoming' store file blobId action = do
        -- open a new Handle since the old one is closed by hGetContents
        (res, commit) <- action file blobId
        if commit
            --TODO: if the target already exists then there is no need to overwrite
            -- it since it will have the same content. Checking and then renaming
            -- would give a race condition but that's ok since they have the same
            -- content.
            then renameFile file (filepath store blobId)
            else removeFile file
        return res


-- | Retrieve a blob from the store given its 'BlobId'.
--
-- * The content corresponding to a given 'BlobId' never changes.
--
-- * The blob must exist in the store or it is an error.
--
fetch :: BlobStorage -> BlobId -> IO ByteString
fetch store blobid = BS.readFile (filepath store blobid)

-- | Opens an existing or new blob storage area.
--
open :: FilePath -> IO BlobStorage
open storeDir = do
    let store   = BlobStorage storeDir
        chars   = ['0' .. '9'] ++ ['a' .. 'f']
        subdirs = incomingDir store
                : [storeDir </> [x, y] | x <- chars, y <- chars]

    exists <- doesDirectoryExist storeDir
    if not exists
      then do
        createDirectory storeDir
        forM_ subdirs createDirectory
      else
        forM_ subdirs $ \d -> do
          subdirExists <- doesDirectoryExist d
          unless subdirExists $
            fail $ "Store directory \""
                ++ storeDir
                ++ "\" exists but \""
                ++ d
                ++ "\" does not"
    return store