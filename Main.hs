{-# LANGUAGE PatternGuards #-}

module Main where

import qualified Distribution.Server as Server
import Distribution.Server (ListenOn(..), ServerConfig(..), Server)
import Distribution.Server.Framework.Feature
import Distribution.Server.Framework.BackupRestore (equalTarBall, importTar)
import Distribution.Server.Framework.BackupDump (exportTar)
import qualified Distribution.Server.Framework.BlobStorage as BlobStorage

import Distribution.Text
         ( display )
import Distribution.Simple.Utils
         ( topHandler, die )
import Distribution.Verbosity as Verbosity

import System.Environment
         ( getArgs, getProgName )
import System.Exit
         ( exitWith, ExitCode(..) )
import Control.Exception
         ( bracket, evaluate )
import System.Posix.Signals as Signal
         ( installHandler, Handler(Catch), userDefinedSignal1 )
import System.IO
import System.Directory
         ( createDirectory, createDirectoryIfMissing, doesDirectoryExist
         , Permissions(..), getPermissions )
import System.FilePath
         ( (</>) )
import Distribution.Simple.Command
import Distribution.Simple.Setup
         ( Flag(..), fromFlag, fromFlagOrDefault, flagToList, flagToMaybe )
import Data.List
         ( intersperse )
import Data.Traversable
         ( forM )
import Control.Monad
         ( void, unless, when, liftM )
import Control.Arrow
         ( second )
import qualified Data.ByteString.Lazy as BS
import qualified Text.Parsec as Parse

import Paths_hackage_server as Paths (version)

-------------------------------------------------------------------------------
-- Top level command handling
--

main :: IO ()
main = topHandler $ do
    hSetBuffering stdout LineBuffering
    args <- getArgs
    case commandsRun globalCommand commands args of
      CommandHelp   help  -> printHelp help
      CommandList   opts  -> printOptionsList opts
      CommandErrors errs  -> printErrors errs
      CommandReadyToGo (flags, commandParse) ->
        case commandParse of
          _ | fromFlag (flagVersion flags) -> printVersion
          CommandHelp      help    -> printHelp help
          CommandList      opts    -> printOptionsList opts
          CommandErrors    errs    -> printErrors errs
          CommandReadyToGo action  -> action

  where
    printHelp help = getProgName >>= putStr . help
    printOptionsList = putStr . unlines
    printErrors errs = do
      putStr (concat (intersperse "\n" errs))
      exitWith (ExitFailure 1)
    printVersion = putStrLn $ "hackage-server " ++ display version

    commands =
      [ runCommand     `commandAddActionNoArgs` runAction
      , initCommand    `commandAddActionNoArgs` initAction
      , backupCommand  `commandAddActionNoArgs` backupAction
      , restoreCommand `commandAddAction`       restoreAction
      , testBackupCommand `commandAddActionNoArgs` testBackupAction
      ]

    commandAddActionNoArgs cmd action =
      commandAddAction cmd $ \flags extraArgs -> do
        when (not (null extraArgs)) $
          die $ "'" ++ commandName cmd
             ++ "' does not take any extra arguments: " ++ unwords extraArgs
        action flags



info :: String -> IO ()
info msg = do
  pname <- getProgName
  putStrLn (pname ++ ": " ++ msg)
  hFlush stdout


-------------------------------------------------------------------------------
-- Global command
--

data GlobalFlags = GlobalFlags {
    flagVersion :: Flag Bool
  }

defaultGlobalFlags :: GlobalFlags
defaultGlobalFlags = GlobalFlags {
    flagVersion = Flag False
  }

globalCommand :: CommandUI GlobalFlags
globalCommand = CommandUI {
    commandName         = "",
    commandSynopsis     = "",
    commandUsage        = \_ ->
         "Hackage server: serves a collection of Haskell Cabal packages\n",
    commandDescription  = Just $ \pname ->
         "For more information about a command use\n"
      ++ "  " ++ pname ++ " COMMAND --help\n\n"
      ++ "Steps to create a new empty server instance:\n"
      ++ concat [ "  " ++ pname ++ " " ++ x ++ "\n"
                | x <- ["init", "run"]],
    commandDefaultFlags = defaultGlobalFlags,
    commandOptions      = \_ ->
      [option ['V'] ["version"]
         "Print version information"
         flagVersion (\v flags -> flags { flagVersion = v })
         (noArg (Flag True))
      ]
  }

-------------------------------------------------------------------------------
-- Run command
--

data RunFlags = RunFlags {
    flagVerbosity :: Flag Verbosity,
    flagPort      :: Flag String,
    flagIP        :: Flag String,
    flagHost      :: Flag String,
    flagStateDir  :: Flag FilePath,
    flagStaticDir :: Flag FilePath,
    flagTmpDir    :: Flag FilePath,
    flagTemp      :: Flag Bool,
    flagCacheDelay:: Flag String
  }

defaultRunFlags :: RunFlags
defaultRunFlags = RunFlags {
    flagVerbosity = Flag Verbosity.normal,
    flagPort      = NoFlag,
    flagIP        = NoFlag,
    flagHost      = NoFlag,
    flagStateDir  = NoFlag,
    flagStaticDir = NoFlag,
    flagTmpDir    = NoFlag,
    flagTemp      = Flag False,
    flagCacheDelay= NoFlag
  }

runCommand :: CommandUI RunFlags
runCommand = makeCommand name shortDesc longDesc defaultRunFlags options
  where
    name       = "run"
    shortDesc  = "Run an already-initialized Hackage server."
    longDesc   = Just $ \progname ->
                  "Note: the " ++ progname ++ " data lock prevents two "
               ++ "state-accessing modes from\nbeing run simultaneously.\n\n"
               ++ "On unix systems you can tell the server to checkpoint its "
               ++ "database state using:\n"
               ++ " $ kill -USR1 $the_pid\n"
               ++ "where $the_pid is the process id of the running server.\n"
    options _  =
      [ option "v" ["verbose"]
          "Control verbosity (n is 0--3, default verbosity level is 1)"
          flagVerbosity (\v flags -> flags { flagVerbosity = v })
          (optArg "n" (fmap Flag Verbosity.flagToVerbosity)
                (Flag Verbosity.verbose)
                (fmap (Just . showForCabal) . flagToList))
      , option [] ["port"]
          "Port number to serve on (default 8080)"
          flagPort (\v flags -> flags { flagPort = v })
          (reqArgFlag "PORT")
      , option [] ["ip"]
          "IPv4 address to listen on (default 0.0.0.0)"
          flagIP (\v flags -> flags { flagIP = v })
          (reqArgFlag "IP")
      , option [] ["host"]
          "Server's host name (defaults to machine name)"
          flagHost (\v flags -> flags { flagHost = v })
          (reqArgFlag "NAME")
      , option [] ["state-dir"]
          "Directory in which to store the persistent state of the server (default state/)"
          flagStateDir (\v flags -> flags { flagStateDir = v })
          (reqArgFlag "DIR")
      , option [] ["static-dir"]
          "Directory in which to find the html and other static files (default: cabal location)"
          flagStaticDir (\v flags -> flags { flagStaticDir = v })
          (reqArgFlag "DIR")
      , option [] ["tmp-dir"]
          "Temporary directory in which to store file uploads until they are moved to a permanent location."
          flagTmpDir (\v flags -> flags { flagTmpDir = v })
          (reqArgFlag "DIR")
      , option [] ["temp-run"]
          "Set up a temporary server while initializing state for maintenance restarts"
          flagTemp (\v flags -> flags { flagTemp = v })
          (noArg (Flag True))
      , option [] ["delay-cache-updates"]
          "Save time during bulk imports by delaying cache updates."
          flagCacheDelay (\v flags -> flags { flagCacheDelay = v })
          (reqArgFlag "SECONDS")
      ]

runAction :: RunFlags -> IO ()
runAction opts = do
    defaults <- Server.defaultServerConfig

    port <- checkPortOpt defaults (flagToMaybe (flagPort opts))
    ip   <- checkIPOpt   defaults (flagToMaybe (flagIP   opts))
    cacheDelay <- checkCacheDelay (confCacheDelay defaults) (flagToMaybe (flagCacheDelay opts))
    let verbosity = fromFlag (flagVerbosity opts)
        hostname  = fromFlagOrDefault (confHostName  defaults) (flagHost      opts)
        stateDir  = fromFlagOrDefault (confStateDir  defaults) (flagStateDir  opts)
        staticDir = fromFlagOrDefault (confStaticDir defaults) (flagStaticDir opts)
        tmpDir    = fromFlagOrDefault (confTmpDir    defaults) (flagTmpDir    opts)
        listenOn = (confListenOn defaults) {
                       loPortNum = port,
                       loIP      = ip
                   }
        config = defaults {
            confVerbosity = verbosity,
            confHostName  = hostname,
            confListenOn  = listenOn,
            confStateDir  = stateDir,
            confStaticDir = staticDir,
            confTmpDir    = tmpDir,
            confCacheDelay=cacheDelay
        }

    checkBlankServerState =<< Server.hasSavedState config
    checkStaticDir staticDir (flagStaticDir opts)
    checkTmpDir    tmpDir

    let useTempServer = fromFlag (flagTemp opts)
    withServer config useTempServer $ \server ->
      withCheckpointHandler server $ do
        info $ "Ready! Point your browser at http://" ++ hostname
            ++ if port == 80 then "/" else ":" ++ show port ++ "/"

        Server.run server

  where
    -- Option handling:
    --
    checkPortOpt defaults Nothing    = return (loPortNum (confListenOn defaults))
    checkPortOpt _        (Just str) = case reads str of
      [(n,"")]  | n >= 1 && n <= 65535
               -> return n
      _        -> fail $ "bad port number " ++ show str

    checkIPOpt defaults Nothing    = return (loIP (confListenOn defaults))
    checkIPOpt _        (Just str) =
      let pQuad = do ds <- Parse.many1 Parse.digit
                     let quad = read ds :: Integer
                     when (quad < 0 || quad > 255) $ fail "bad IP address"
                     return quad
          pIPv4 = do q1 <- pQuad
                     void $ Parse.char '.'
                     q2 <- pQuad
                     void $ Parse.char '.'
                     q3 <- pQuad
                     void $ Parse.char '.'
                     q4 <- pQuad
                     Parse.eof
                     return (q1, q2, q3, q4)
      in case Parse.parse pIPv4 str str of
         Left err -> fail (show err)
         Right _ -> return str

    checkCacheDelay def Nothing    = return def
    checkCacheDelay _   (Just str) = case reads str of
      [(n,"")]  | n >= 0 && n <= 3600
               -> return n
      _        -> fail $ "bad cache delay number " ++ show str


    -- Set a Unix signal handler for SIG USR1 to create a state checkpoint.
    -- Useage:
    -- > kill -USR1 $the_pid
    --
    withCheckpointHandler :: Server -> IO () -> IO ()
    withCheckpointHandler server action =
        bracket (setHandler handler) setHandler (\_ -> action)
      where
        handler = Signal.Catch $ do
          info "Writing checkpoint..."
          Server.checkpoint server
          info "Done"
        setHandler h =
          Signal.installHandler Signal.userDefinedSignal1 h Nothing

    checkBlankServerState  hasSavedState = when (not hasSavedState) . die $
            "There is no existing server state.\nYou can either import "
         ++ "existing data using the various import modes, or start with "
         ++ "an empty state using the new mode. Either way, we have to make "
         ++ "sure that there is at least one admin user account, otherwise "
         ++ "you'll not be able to administer your shiny new hackage server!\n"
         ++ "Use --help for more information."

-- Check that tmpDir exists and is readable & writable
checkTmpDir :: FilePath -> IO ()
checkTmpDir tmpDir = do
  exists <- doesDirectoryExist tmpDir
  when (not exists) $ fail $ "The temporary directory " ++ tmpDir ++ " does not exist. Create the directory or use --tmp-dir to specify an alternate location."
  perms <- getPermissions tmpDir
  when (not $ readable perms) $
    fail $ "The temporary directory " ++ tmpDir ++ " is not readable by the server. Fix the permissions or use --tmp-dir to specify an alternate location."
  when (not $ writable perms) $
    fail $ "The temporary directory " ++ tmpDir ++ " is not writable by the server. Fix the permissions or use --tmp-dir to specify an alternate location."

-- Check that staticDir exists and is readable
checkStaticDir :: FilePath -> Flag FilePath -> IO ()
checkStaticDir staticDir staticDirFlag = do
    exists <- doesDirectoryExist staticDir
    when (not exists) $
      case staticDirFlag of
        Flag _ -> die $ "The given static files directory " ++ staticDir
                     ++ " does not exist."
        -- Be helpful to people running from the build tree
        NoFlag -> die $ "It looks like you are running the server without "
                     ++ "installing it. That is fine but you will have to "
                     ++ "give the location of the static html files with the "
                     ++ "--static-dir flag."
    perms <- getPermissions staticDir
    when (not $ readable perms) $
      die $ "The static files directory " ++ staticDir
          ++ " exists but is not readable by the server."


-------------------------------------------------------------------------------
-- Init command
--

data InitFlags = InitFlags {
    flagInitAdmin     :: Flag String,
    flagInitStateDir  :: Flag FilePath,
    flagInitStaticDir :: Flag FilePath
  }

defaultInitFlags :: InitFlags
defaultInitFlags = InitFlags {
    flagInitAdmin     = NoFlag,
    flagInitStateDir  = NoFlag,
    flagInitStaticDir = NoFlag
  }

initCommand :: CommandUI InitFlags
initCommand = makeCommand name shortDesc longDesc defaultInitFlags options
  where
    name       = "init"
    shortDesc  = "Initialize the server state to a useful default."
    longDesc   = Just $ \_ ->
                 "Creates an empty package collection and one admininstrator "
              ++ "account so that you\ncan log in via the web interface and "
              ++ "bootstrap from there.\n"
    options _  =
      [ option [] ["admin"]
          "New server's administrator, name:password (default: admin:admin)"
          flagInitAdmin (\v flags -> flags { flagInitAdmin = v })
          (reqArgFlag "NAME:PASS")
      , option [] ["state-dir"]
          "Directory in which to store the persistent state of the server (default state/)"
          flagInitStateDir (\v flags -> flags { flagInitStateDir = v })
          (reqArgFlag "DIR")
      , option [] ["static-dir"]
          "Directory in which to find the html and other static files (default: cabal location)"
          flagInitStaticDir (\v flags -> flags { flagInitStaticDir = v })
          (reqArgFlag "DIR")
      ]

initAction :: InitFlags -> IO ()
initAction opts = do
    defaults <- Server.defaultServerConfig

    let stateDir  = fromFlagOrDefault (confStateDir defaults)  (flagInitStateDir opts)
        staticDir = fromFlagOrDefault (confStaticDir defaults) (flagInitStaticDir opts)
        config = defaults {
            confStateDir  = stateDir,
            confStaticDir = staticDir
        }
        parseAdmin adminStr = case break (==':') adminStr of
            (uname, ':':pass) -> Just (uname, pass)
            _                 -> Nothing

    admin <- case flagInitAdmin opts of
        NoFlag   -> return ("admin", "admin")
        Flag str -> case parseAdmin str of
            Just arg -> return arg
            Nothing  -> fail $ "Couldn't parse username:password in " ++ show str

    checkAccidentalDataLoss =<< Server.hasSavedState config
    checkStaticDir staticDir (flagInitStaticDir opts)

    withServer config False $ \server -> do
        info "Creating initial state..."
        Server.initState server admin
        createDirectory (stateDir </> "tmp")
        when (flagInitAdmin opts == NoFlag) $
          info $ "Using default administrator account "
              ++ "(user admin, passwd admin)"
        info "Done"


-------------------------------------------------------------------------------
-- Backup command
--

data BackupFlags = BackupFlags {
    flagBackup    :: Flag FilePath,
    flagBackupDir :: Flag FilePath
  }

defaultBackupFlags :: BackupFlags
defaultBackupFlags = BackupFlags {
    flagBackup    = NoFlag,
    flagBackupDir = NoFlag
  }

backupCommand :: CommandUI BackupFlags
backupCommand = makeCommand name shortDesc longDesc defaultBackupFlags options
  where
    name       = "backup"
    shortDesc  = "Create a backup tarball of the server's database."
    longDesc   = Just $ \_ ->
                 "Creates a tarball containing all of the data that the server "
              ++ "manages.\nThe purpose is for backup and for data integrity "
              ++ "across server upgrades.\nThe tarball contains files in "
              ++ "standard formats or simple text formats.\nThe backup can be "
              ++ "restored using the 'restore' command.\n"
    options _  =
      [ option ['o'] ["output"]
          "The path to write the backup tarball (default export.tar)"
          flagBackup (\v flags -> flags { flagBackup = v })
          (reqArgFlag "TARBALL")
      , option [] ["state-dir"]
          "Directory from which to read persistent state of the server (default state/)"
          flagBackupDir (\v flags -> flags { flagBackupDir = v })
          (reqArgFlag "DIR")
      ]

backupAction :: BackupFlags -> IO ()
backupAction opts = do
    defaults <- Server.defaultServerConfig

    let stateDir = fromFlagOrDefault (confStateDir defaults) (flagBackupDir opts)
        config = defaults { confStateDir = stateDir }
        exportPath = fromFlagOrDefault "export.tar" (flagBackup opts)

    withServer config False $ \server -> do
      let store = Server.serverBlobStore (Server.serverEnv server)
          state = Server.serverState server
      info "Preparing export tarball"
      tar <- exportTar store $ map (second abstractStateBackup) state
      info "Saving export tarball"
      BS.writeFile exportPath tar
      info "Done"


-------------------------------------------------------------------------------
-- Test backup command
--

data TestBackupFlags = TestBackupFlags {
    flagTestBackupDir     :: Flag FilePath,
    flagTestBackupTmpDir  :: Flag FilePath
  }

defaultTestBackupFlags :: TestBackupFlags
defaultTestBackupFlags = TestBackupFlags {
    flagTestBackupDir    = NoFlag,
    flagTestBackupTmpDir = NoFlag
  }

testBackupCommand :: CommandUI TestBackupFlags
testBackupCommand = makeCommand name shortDesc longDesc defaultTestBackupFlags options
  where
    name       = "test-backup"
    shortDesc  = "Test backup and restore of the server's database."
    longDesc   = Just $ \_ ->
                 "Checks that backing up and then restoring is the identity function on the"
              ++ "server state,\n and that restoring and then backing up is the identity function"
              ++ "on the backup tarball.\n"
    options _  =
      [ option [] ["state-dir"]
          "Directory from which to read persistent state of the server (default state/)"
          flagTestBackupDir (\v flags -> flags { flagTestBackupDir = v })
          (reqArgFlag "DIR")
      , option [] ["tmp-dir"]
          "Temporary directory in which to store temporary information generated by the test."
          flagTestBackupTmpDir (\v flags -> flags { flagTestBackupTmpDir = v })
          (reqArgFlag "DIR")
      ]

-- FIXME: the following acidic types are neither backed up nor tested:
--   PlatformPackages
--   PreferredVersions
--   CandidatePackages
--   IndexUsers
--   TarIndexMap

testBackupAction :: TestBackupFlags -> IO ()
testBackupAction opts = do
    defaults <- Server.defaultServerConfig

    let stateDir = fromFlagOrDefault (confStateDir defaults) (flagTestBackupDir    opts)
        tmpDir   = fromFlagOrDefault (stateDir </> "tmp")    (flagTestBackupTmpDir opts)
        config = defaults {
            confStateDir = stateDir,
            confTmpDir   = tmpDir
          }
        tmpStateDir = tmpDir </> "state"

    checkTmpDir tmpDir
    createDirectoryIfMissing True tmpStateDir

    withServer config False $ \server -> do
      let state = Server.serverState server
          store = Server.serverBlobStore (Server.serverEnv server)

      info "Preparing export tarball"
      tar <- exportTar store $ map (second abstractStateBackup) state
      -- It is EXTREMELY IMPORTANT that we force the tarball to be constructed
      -- now. If we wait until it is demanded in the next withServer context
      -- then the tar gets filled with entirely wrong files!
      evaluate (BS.length tar)

      -- Reset all the state components, then run the import against the cloned
      -- components and check that the states got restored.
      store' <- BlobStorage.open (tmpDir </> "blobs")
      (state', compares) <- liftM unzip . forM state $ \(name, st) -> do
                             (st', cmpSt) <- abstractStateReset st store' tmpStateDir
                             return ((name, st'), liftM (map (\err -> name ++ ": " ++ err)) cmpSt)
      let compareAll :: IO [String] ; compareAll = liftM concat (sequence compares)

      info "Parsing import tarball"
      res <- importTar tar $ map (second abstractStateRestore) state'
      maybe (return ()) fail res

      info "Checking snapshot"
      errs <- compareAll
      unless (null errs) $ do
        mapM_ info errs
      --   fail "Snapshot check failed!"

      info "Preparing second export tarball"
      tar' <- exportTar store' $ map (second abstractStateBackup) state'
      case tar `equalTarBall` tar' of
        [] -> info "Tarballs match"
        tar_eq_errs -> do
          mapM_ info tar_eq_errs
          BS.writeFile "export-before.tar" tar
          BS.writeFile "export-after.tar" tar'
          fail "Tarballs don't match! Written to export-before.tar and export-after.tar."

-------------------------------------------------------------------------------
-- Restore command
--

data RestoreFlags = RestoreFlags {
    flagRestore    :: Flag FilePath,
    flagRestoreDir :: Flag FilePath
  }

defaultRestoreFlags :: RestoreFlags
defaultRestoreFlags = RestoreFlags {
    flagRestore    = NoFlag,
    flagRestoreDir = NoFlag
  }

restoreCommand :: CommandUI RestoreFlags
restoreCommand = makeCommand name shortDesc longDesc defaultRestoreFlags options
  where
    name       = "restore"
    shortDesc  = "Restore server state from a backup tarball."
    longDesc   = Just $ \_ ->
                 "Note that this creates a new server state, so for safety "
              ++ "it requires that the\nserver not be initialised already.\n"
    options _  =
      [ option [] ["state-dir"]
        "Directory in which to store the persistent state of the server (default state/)"
        flagRestoreDir (\v flags -> flags { flagRestoreDir = v })
        (reqArgFlag "DIR")
      ]

restoreAction :: RestoreFlags -> [String] -> IO ()
restoreAction _ [] = die "No restore tarball given."
restoreAction opts [tarFile] = do
    defaults <- Server.defaultServerConfig

    let stateDir = fromFlagOrDefault (confStateDir defaults) (flagRestoreDir opts)
        config = defaults { confStateDir  = stateDir }

    checkAccidentalDataLoss =<< Server.hasSavedState config

    withServer config False $ \server -> do
        tar <- BS.readFile tarFile
        info "Parsing import tarball..."
        res <- importTar tar $ map (second abstractStateRestore) (Server.serverState server)
        case res of
            Just err -> fail err
            _ ->
                do createDirectory (stateDir </> "tmp")
                   info "Successfully imported."
restoreAction _ _ = die "There should be exactly one argument: the backup tarball."


-------------------------------------------------------------------------------
-- common action functions
--

withServer :: ServerConfig -> Bool -> (Server -> IO a) -> IO a
withServer config doTemp = bracket initialise shutdown
  where
    initialise = do
      mtemp <- case doTemp of
          True  -> do
            info "Setting up temp sever"
            fmap Just $ Server.setUpTemp config 1
          False -> return Nothing
      info "Initializing happstack-state..."
      server <- Server.initialise config
      info "Server data loaded into memory"
      void $ forM mtemp $ \temp -> do
        info "Tearing down temp server"
        Server.tearDownTemp temp
      return server

    shutdown server = do
      -- This only shuts down happstack-state and writes a checkpoint;
      -- the HTTP part takes care of itself
      info "Shutting down..."
      Server.shutdown server

-- Import utilities
checkAccidentalDataLoss :: Bool -> IO ()
checkAccidentalDataLoss hasSavedState =
    when hasSavedState . die $
        "The server already has an initialised database!!\n"
     ++ "If you really *really* intend to completely reset the "
     ++ "whole database you should remove the state/ directory."

-- option utility
reqArgFlag :: ArgPlaceHolder -> SFlags -> LFlags -> Description
           -> (a -> Flag String) -> (Flag String -> a -> a)
           -> OptDescr a
reqArgFlag ad = reqArg' ad Flag flagToList
