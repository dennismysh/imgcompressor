{-# LANGUAGE NoRebindableSyntax #-}
{-# OPTIONS_GHC -fno-warn-missing-import-lists #-}
{-# OPTIONS_GHC -w #-}
module PackageInfo_sigil_hs (
    name,
    version,
    synopsis,
    copyright,
    homepage,
  ) where

import Data.Version (Version(..))
import Prelude

name :: String
name = "sigil_hs"
version :: Version
version = Version [0,2,0,0] []

synopsis :: String
synopsis = "Sigil image codec \8212 Haskell reference implementation"
copyright :: String
copyright = ""
homepage :: String
homepage = ""
