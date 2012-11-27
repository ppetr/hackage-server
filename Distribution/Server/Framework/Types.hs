module Distribution.Server.Framework.Types where

import Distribution.Server.Framework.BlobStorage (BlobStorage)

import Happstack.Server
import qualified Network.URI as URI

-- | The internal server environment as used by 'HackageFeature's.
--
-- It contains various bits of static information (and handles of
-- server-global objects) that are needed by the implementations of
-- some 'HackageFeature's.
--
data ServerEnv = ServerEnv {

    -- | The location of the server's static files
    serverStaticDir :: FilePath,

    -- | The location of the server's state directory. This is where the
    -- server's persistent state is kept, e.g. using ACID state.
    serverStateDir  :: FilePath,

    -- | The blob store is a specialised provider of persistent state for
    -- larger relatively-static blobs of data (e.g. uploaded tarballs).
    serverBlobStore :: BlobStorage,

    -- | The temporary directory the server has been configured to use.
    -- Use it for temp files such as when validating uploads.
    serverTmpDir    :: FilePath,

    -- | The base URI of the server, just the hostname (and perhaps port).
    -- Use this if you need to construct absolute URIs pointing to the
    -- current server (e.g. as required in RSS feeds).
    serverHostURI   :: URI.URIAuth,

    -- | A tunable parameter for cache policy. Setting this parameter high
    -- during bulk imports can very significantly improve performance. During
    -- normal operation it probably doesn't help much.
    
    -- By delaying cache updates we can sometimes save some effort: caches are
    -- based on a bit of changing state and if that state is updated more
    -- frequently than the time taken to update the cache, then we don't have
    -- to do as many cache updates as we do state updates. By artificially
    -- increasing the time taken to update the cache we can push this further.
    serverCacheDelay :: Int
}

type DynamicPath = [(String, String)]

type ServerResponse = DynamicPath -> ServerPart Response

