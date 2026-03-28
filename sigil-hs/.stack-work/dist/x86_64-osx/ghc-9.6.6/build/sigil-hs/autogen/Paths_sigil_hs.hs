{-# LANGUAGE CPP #-}
{-# LANGUAGE NoRebindableSyntax #-}
#if __GLASGOW_HASKELL__ >= 810
{-# OPTIONS_GHC -Wno-prepositive-qualified-module #-}
#endif
{-# OPTIONS_GHC -fno-warn-missing-import-lists #-}
{-# OPTIONS_GHC -w #-}
module Paths_sigil_hs (
    version,
    getBinDir, getLibDir, getDynLibDir, getDataDir, getLibexecDir,
    getDataFileName, getSysconfDir
  ) where


import qualified Control.Exception as Exception
import qualified Data.List as List
import Data.Version (Version(..))
import System.Environment (getEnv)
import Prelude


#if defined(VERSION_base)

#if MIN_VERSION_base(4,0,0)
catchIO :: IO a -> (Exception.IOException -> IO a) -> IO a
#else
catchIO :: IO a -> (Exception.Exception -> IO a) -> IO a
#endif

#else
catchIO :: IO a -> (Exception.IOException -> IO a) -> IO a
#endif
catchIO = Exception.catch

version :: Version
version = Version [0,2,0,0] []

getDataFileName :: FilePath -> IO FilePath
getDataFileName name = do
  dir <- getDataDir
  return (dir `joinFileName` name)

getBinDir, getLibDir, getDynLibDir, getDataDir, getLibexecDir, getSysconfDir :: IO FilePath




bindir, libdir, dynlibdir, datadir, libexecdir, sysconfdir :: FilePath
bindir     = "/Users/dennis/programming projects/imgcompressor/sigil-hs/.stack-work/install/x86_64-osx/a45f360f33cb8974d4454cd45fed3f1d94973137487f27ff963810900d2a7567/9.6.6/bin"
libdir     = "/Users/dennis/programming projects/imgcompressor/sigil-hs/.stack-work/install/x86_64-osx/a45f360f33cb8974d4454cd45fed3f1d94973137487f27ff963810900d2a7567/9.6.6/lib/x86_64-osx-ghc-9.6.6/sigil-hs-0.2.0.0-DbbxvHgRuGR9JI3O0Pz8Vn-sigil-hs"
dynlibdir  = "/Users/dennis/programming projects/imgcompressor/sigil-hs/.stack-work/install/x86_64-osx/a45f360f33cb8974d4454cd45fed3f1d94973137487f27ff963810900d2a7567/9.6.6/lib/x86_64-osx-ghc-9.6.6"
datadir    = "/Users/dennis/programming projects/imgcompressor/sigil-hs/.stack-work/install/x86_64-osx/a45f360f33cb8974d4454cd45fed3f1d94973137487f27ff963810900d2a7567/9.6.6/share/x86_64-osx-ghc-9.6.6/sigil-hs-0.2.0.0"
libexecdir = "/Users/dennis/programming projects/imgcompressor/sigil-hs/.stack-work/install/x86_64-osx/a45f360f33cb8974d4454cd45fed3f1d94973137487f27ff963810900d2a7567/9.6.6/libexec/x86_64-osx-ghc-9.6.6/sigil-hs-0.2.0.0"
sysconfdir = "/Users/dennis/programming projects/imgcompressor/sigil-hs/.stack-work/install/x86_64-osx/a45f360f33cb8974d4454cd45fed3f1d94973137487f27ff963810900d2a7567/9.6.6/etc"

getBinDir     = catchIO (getEnv "sigil_hs_bindir")     (\_ -> return bindir)
getLibDir     = catchIO (getEnv "sigil_hs_libdir")     (\_ -> return libdir)
getDynLibDir  = catchIO (getEnv "sigil_hs_dynlibdir")  (\_ -> return dynlibdir)
getDataDir    = catchIO (getEnv "sigil_hs_datadir")    (\_ -> return datadir)
getLibexecDir = catchIO (getEnv "sigil_hs_libexecdir") (\_ -> return libexecdir)
getSysconfDir = catchIO (getEnv "sigil_hs_sysconfdir") (\_ -> return sysconfdir)



joinFileName :: String -> String -> FilePath
joinFileName ""  fname = fname
joinFileName "." fname = fname
joinFileName dir ""    = dir
joinFileName dir fname
  | isPathSeparator (List.last dir) = dir ++ fname
  | otherwise                       = dir ++ pathSeparator : fname

pathSeparator :: Char
pathSeparator = '/'

isPathSeparator :: Char -> Bool
isPathSeparator c = c == '/'
