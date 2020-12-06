{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE CPP #-}
module HieDb.Utils where

import qualified Data.Tree

import Prelude hiding (mod)

import Compat.HieBin
import Compat.HieTypes
import qualified Compat.HieTypes as HieTypes
import Compat.HieUtils
import Name
import Module
import NameCache
import UniqSupply
import SrcLoc
import DynFlags
import SysTools

import qualified Data.Map as M

import qualified FastString as FS

import System.Directory
import System.FilePath

import Control.Arrow ( (&&&) )
import Data.Bifunctor ( bimap )
import Data.List (find)
import Control.Monad.IO.Class
import qualified Data.Array as A

import Data.Char
import Data.Int
import Data.Maybe
import Data.Monoid
import Data.IORef

import HieDb.Types
import Database.SQLite.Simple

addTypeRef :: HieDb -> FilePath -> A.Array TypeIndex HieTypeFlat -> A.Array TypeIndex (Maybe Int64) -> RealSrcSpan -> TypeIndex -> IO ()
addTypeRef (getConn -> conn) hf arr ixs sp = go 0
  where
    file = FS.unpackFS $ srcSpanFile sp
    sl = srcSpanStartLine sp
    sc = srcSpanStartCol sp
    el = srcSpanEndLine sp
    ec = srcSpanEndCol sp
    go :: TypeIndex -> Int -> IO ()
    go d i = do
      case ixs A.! i of
        Nothing -> pure ()
        Just occ -> do
          let ref = TypeRef occ hf d file sl sc el ec
          execute conn "INSERT INTO typerefs VALUES (?,?,?,?,?,?,?,?)" ref
      let next = go (d+1)
      case arr A.! i of
        HTyVarTy _ -> pure ()
#if __GLASGOW_HASKELL__ >= 808
        HAppTy x (HieArgs xs) -> mapM_ next (x:map snd xs)
#else
        HAppTy x y -> mapM_ next [x,y]
#endif
        HTyConApp _ (HieArgs xs) -> mapM_ (next . snd) xs
        HForAllTy ((_ , a),_) b -> mapM_ next [a,b]
        HFunTy a b -> mapM_ next [a,b]
        HQualTy a b -> mapM_ next [a,b]
        HLitTy _ -> pure ()
        HCastTy a -> next a
        HCoercionTy -> pure ()

makeNc :: IO NameCache
makeNc = do
  uniq_supply <- mkSplitUniqSupply 'z'
  return $ initNameCache uniq_supply []

-- | Recursively search for .hie and .hie-boot files in given directory
getHieFilesIn :: FilePath -> IO [FilePath]
getHieFilesIn path = do
  isFile <- doesFileExist path
  if isFile && ("hie" `isExtensionOf` path || "hie-boot" `isExtensionOf` path) then do
      path' <- canonicalizePath path
      return [path']
  else do
    isDir <- doesDirectoryExist path
    if isDir then do
      cnts <- listDirectory path
      withCurrentDirectory path $ foldMap getHieFilesIn cnts
    else
      return []

withHieFile :: (NameCacheMonad m, MonadIO m)
            => FilePath
            -> (HieFile -> m a)
            -> m a
withHieFile path act = do
  ncu <- getNcUpdater
  hiefile <- liftIO $ readHieFile ncu path
  act (hie_file_result hiefile)

tryAll :: Monad m => (a -> m (Either b c)) -> [a] -> m (Maybe c)
tryAll _ [] = return Nothing
tryAll f (x:xs) = do
  eres <- f x
  case eres of
    Right res -> return (Just res)
    Left _ -> tryAll f xs

-- | Given the path to a HieFile, it tries to find the SrcSpan of an External name in
-- it by loading it and then looking for the name in NameCache
findDefInFile :: OccName -> Module -> FilePath -> IO (Either HieDbErr (RealSrcSpan,Module))
findDefInFile occ mdl file = do
  ncr <- newIORef =<< makeNc
  _ <- runDbM ncr $ withHieFile file (const $ return ())
  nc <- readIORef ncr
  return $ case lookupOrigNameCache (nsNames nc) mdl occ of
    Just name -> case nameSrcSpan name of
      RealSrcSpan sp -> Right (sp, mdl)
      UnhelpfulSpan msg -> Left $ NameUnhelpfulSpan name (FS.unpackFS msg)
    Nothing -> Left $ NameNotFound occ (Just $ moduleName mdl) (Just $ moduleUnitId mdl)

pointCommand :: HieFile -> (Int, Int) -> Maybe (Int, Int) -> (HieAST TypeIndex -> a) -> [a]
pointCommand hf (sl,sc) mep k =
    catMaybes $ M.elems $ flip M.mapWithKey (getAsts $ hie_asts hf) $ \fs ast ->
      k <$> selectSmallestContaining (sp fs) ast
 where
   sloc fs = mkRealSrcLoc fs sl sc
   eloc fs = case mep of
     Nothing -> sloc fs
     Just (el,ec) -> mkRealSrcLoc fs el ec
   sp fs = mkRealSrcSpan (sloc fs) (eloc fs)

dynFlagsForPrinting :: LibDir -> IO DynFlags
dynFlagsForPrinting (LibDir libdir) = do
  systemSettings <- initSysTools
#if __GLASGOW_HASKELL__ >= 808
                    libdir
#else
                    (Just libdir)
#endif
#if __GLASGOW_HASKELL__ >= 810
  return $ defaultDynFlags systemSettings $ LlvmConfig [] []
#else
  return $ defaultDynFlags systemSettings ([], [])
#endif

isCons :: String -> Bool
isCons (':':_) = True
isCons (x:_) | isUpper x = True
isCons _ = False

genRefsAndDecls :: FilePath -> Module -> M.Map Identifier [(Span, IdentifierDetails a)] -> ([RefRow],[DeclRow])
genRefsAndDecls path smdl refmap = genRows $ flat $ M.toList refmap
  where
    flat = concatMap (\(a,xs) -> map (a,) xs)
    genRows = foldMap go
    go = bimap maybeToList maybeToList . (goRef &&& goDec)

    goRef (Right name, (sp,_))
      | Just mod <- nameModule_maybe name = Just $
          RefRow path occ (moduleName mod) (moduleUnitId mod) file sl sc el ec
          where
            occ = nameOccName name
            file = FS.unpackFS $ srcSpanFile sp
            sl = srcSpanStartLine sp
            sc = srcSpanStartCol sp
            el = srcSpanEndLine sp
            ec = srcSpanEndCol sp
    goRef _ = Nothing

    goDec (Right name,(_,dets))
      | Just mod <- nameModule_maybe name
      , mod == smdl
      , occ  <- nameOccName name
      , info <- identInfo dets
      , Just sp <- getBindSpan info
      , is_root <- isRoot info
      , file <- FS.unpackFS $ srcSpanFile sp
      , sl   <- srcSpanStartLine sp
      , sc   <- srcSpanStartCol sp
      , el   <- srcSpanEndLine sp
      , ec   <- srcSpanEndCol sp
      = Just $ DeclRow path occ file sl sc el ec is_root
    goDec _ = Nothing

    isRoot = any (\case
      ValBind InstanceBind _ _ -> True
      Decl _ _ -> True
      _ -> False)

    getBindSpan = getFirst . foldMap (First . goDecl)
    goDecl (ValBind _ _ sp) = sp
    goDecl (PatternBind _ _ sp) = sp
    goDecl (Decl _ sp) = sp
    goDecl (RecField _ sp) = sp
    goDecl _ = Nothing

genDefRow :: FilePath -> Module -> M.Map Identifier [(Span, IdentifierDetails a)] -> [DefRow]
genDefRow path smod refmap = genRows $ M.toList refmap
  where
    genRows = mapMaybe go
    getSpan name dets
      | RealSrcSpan sp <- nameSrcSpan name = Just sp
      | otherwise = do
          (sp, _dets) <- find defSpan dets
          pure sp

    defSpan = any isDef . identInfo . snd
    isDef (ValBind RegularBind _ _) = True
    isDef PatternBind{}             = True
    isDef Decl{}                    = True
    isDef _                         = False

    go (Right name,dets)
      | Just mod <- nameModule_maybe name
      , mod == smod
      , occ  <- nameOccName name
      , Just sp <- getSpan name dets
      , file <- FS.unpackFS $ srcSpanFile sp
      , sl   <- srcSpanStartLine sp
      , sc   <- srcSpanStartCol sp
      , el   <- srcSpanEndLine sp
      , ec   <- srcSpanEndCol sp
      = Just $ DefRow path occ file sl sc el ec
    go _ = Nothing

identifierTree :: HieTypes.HieAST a -> Data.Tree.Tree ( HieTypes.HieAST a )
identifierTree HieTypes.Node{ nodeInfo, nodeSpan, nodeChildren } =
  Data.Tree.Node
    { rootLabel = HieTypes.Node{ nodeInfo, nodeSpan, nodeChildren = mempty }
    , subForest = map identifierTree nodeChildren
    }
