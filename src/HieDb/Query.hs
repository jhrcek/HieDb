{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
module HieDb.Query where

import           Algebra.Graph.AdjacencyMap (AdjacencyMap, edges, vertexSet, vertices, overlay)
import           Algebra.Graph.AdjacencyMap.Algorithm (dfs)
import           Algebra.Graph.Export.Dot hiding ((:=))
import qualified Algebra.Graph.Export.Dot as G

import           GHC
import           Compat.HieTypes
import           Module
import           Name

import           System.Directory
import           System.FilePath

import           Control.Monad (foldM, forM_)
import           Control.Monad.IO.Class

import           Data.List (foldl', intercalate)
import           Data.List.NonEmpty (NonEmpty(..))
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as T
import           Data.IORef

import Database.SQLite.Simple

import           HieDb.Dump (sourceCode)
import           HieDb.Types
import           HieDb.Utils
import           HieDb.Create
import qualified HieDb.Html as Html

getAllIndexedMods :: HieDb -> IO [HieModuleRow]
getAllIndexedMods (getConn -> conn) = query_ conn "SELECT * FROM mods"

resolveUnitId :: HieDb -> ModuleName -> IO (Either HieDbErr UnitId)
resolveUnitId (getConn -> conn) mn = do
  luid <- query conn "SELECT mods.mod,mods.unit,mods.is_boot,mods.hs_src,mods.is_real,mods.time FROM mods WHERE mod = ? and is_boot = 0" (Only mn)
  case luid of
    [] -> return $ Left $ NotIndexed mn Nothing
    [x] -> return $ Right $ modInfoUnit x
    (x:xs) -> return $ Left $ AmbiguousUnitId $ x :| xs

search :: HieDb -> Bool -> OccName -> Maybe ModuleName -> Maybe UnitId -> [FilePath] -> IO [Res RefRow]
search (getConn -> conn) isReal occ mn uid exclude =
  queryNamed conn thisQuery ([":occ" := occ, ":mod" := mn, ":unit" := uid, ":real" := isReal] ++ excludedFields)
  where
    excludedFields = zipWith (\n f -> (":exclude" <> T.pack (show n)) := f) [1 :: Int ..] exclude
    thisQuery =
      "SELECT refs.*,mods.mod,mods.unit,mods.is_boot,mods.hs_src,mods.is_real,mods.time \
      \FROM refs JOIN mods USING (hieFile) \
      \WHERE refs.occ = :occ AND (:mod IS NULL OR refs.mod = :mod) AND (:unit is NULL OR refs.unit = :unit) AND ( (NOT :real) OR (mods.is_real AND mods.hs_src IS NOT NULL))"
      <> " AND mods.hs_src NOT IN (" <> Query (T.intercalate "," (map (\(l := _) -> l) excludedFields)) <> ")"

lookupHieFile :: HieDb -> ModuleName -> UnitId -> IO (Maybe HieModuleRow)
lookupHieFile (getConn -> conn) mn uid = do
  files <- query conn "SELECT * FROM mods WHERE mod = ? AND unit = ? AND is_boot = 0" (mn, uid)
  case files of
    [] -> return Nothing
    [x] -> return $ Just x
    xs ->
      error $ "DB invariant violated, (mod,unit) in mods not unique: "
            ++ show (moduleNameString mn, uid) ++ ". Entries: "
            ++ intercalate ", " (map hieModuleHieFile xs)

lookupHieFileFromSource :: HieDb -> FilePath -> IO (Maybe HieModuleRow)
lookupHieFileFromSource (getConn -> conn) fp = do
  files <- query conn "SELECT * FROM mods WHERE hs_src = ?" (Only fp)
  case files of
    [] -> return Nothing
    [x] -> return $ Just x
    xs ->
      error $ "DB invariant violated, hs_src in mods not unique: "
            ++ show fp ++ ". Entries: "
            ++ intercalate ", " (map (show . toRow) xs)

findTypeRefs :: HieDb -> OccName -> ModuleName -> UnitId -> IO [Res TypeRef]
findTypeRefs (getConn -> conn) occ mn uid
  = query conn  "SELECT typerefs.*, mods.mod,mods.unit,mods.is_boot,mods.hs_src,mods.is_real,mods.time \
                \FROM typerefs JOIN mods ON typerefs.hieFile = mods.hieFile \
                              \JOIN typenames ON typerefs.id = typenames.id \
                \WHERE typenames.name = ? AND typenames.mod = ? AND typenames.unit = ? AND mods.is_real \
                       \ORDER BY typerefs.depth ASC"
                (occ,mn,uid)

findDef :: HieDb -> OccName -> Maybe ModuleName -> Maybe UnitId -> IO [Res DefRow]
findDef conn occ mn uid
  = queryNamed (getConn conn) "SELECT defs.*, mods.mod,mods.unit,mods.is_boot,mods.hs_src,mods.is_real,mods.time \
                              \FROM defs JOIN mods USING (hieFile) \
                              \WHERE occ = :occ AND (:mod IS NULL OR mod = :mod) AND (:unit IS NULL OR unit = :unit)"
                              [":occ" := occ,":mod" := mn, ":unit" := uid]

findOneDef :: HieDb -> OccName -> Maybe ModuleName -> Maybe UnitId -> IO (Either HieDbErr (Res DefRow))
findOneDef conn occ mn muid = wrap <$> findDef conn occ mn muid
  where
    wrap [x]    = Right x
    wrap []     = Left $ NameNotFound occ mn muid
    wrap (x:xs) = Left $ AmbiguousUnitId (defUnit x :| map defUnit xs)
    defUnit (_:.i) = i

searchDef :: HieDb -> String -> IO [Res DefRow]
searchDef conn cs
  = query (getConn conn) "SELECT defs.*,mods.mod,mods.unit,mods.is_boot,mods.hs_src,mods.is_real,mods.time \
                         \FROM defs JOIN mods USING (hieFile) \
                         \WHERE occ LIKE ? \
                         \LIMIT 200" (Only $ '_':cs++"%")

withTarget
  :: HieDb
  -> Either FilePath (ModuleName, Maybe UnitId)
  -> (HieFile -> a)
  -> IO (Either HieDbErr a)
withTarget conn (Left x') f = do
  x <- canonicalizePath x'
  nc <- newIORef =<< makeNc
  runDbM nc $ do
    addRefsFrom conn x
    Right <$> withHieFile x (return . f)
withTarget conn (Right (mn, muid)) f = do
  euid <- maybe (resolveUnitId conn mn) (return . Right) muid
  case euid of
    Left err -> return $ Left err
    Right uid -> do
      mFile <- lookupHieFile conn mn uid
      case mFile of
        Nothing -> return $ Left (NotIndexed mn $ Just uid)
        Just x -> do
          nc <- newIORef =<< makeNc
          runDbM nc $ do
            file <- liftIO $ canonicalizePath (hieModuleHieFile x)
            addRefsFrom conn file
            Right <$> withHieFile file (return . f)

type Vertex = (String, String, String, Int, Int, Int, Int)

declRefs :: HieDb -> IO ()
declRefs db = do
  graph <- getGraph db
  writeFile
    "refs.dot"
    ( export
        ( ( defaultStyle ( \( _, hie, occ, _, _, _, _ ) -> hie <> ":" <> occ ) )
          { vertexAttributes = \( mod', _, v : occ, _, _, _, _ ) ->
              [ "label" G.:= ( mod' <> "." <> occ )
              , "fillcolor" G.:= case v of 'v' -> "red"; 't' -> "blue" ; _ -> "black" ]
          }
        )
        graph
    )

getGraph :: HieDb -> IO (AdjacencyMap Vertex)
getGraph (getConn -> conn) = do
  es <-
    query_ conn "SELECT  mods.mod,    decls.hieFile,    decls.occ,    decls.sl,    decls.sc,    decls.el,    decls.ec, \
                       \rmods.mod, ref_decl.hieFile, ref_decl.occ, ref_decl.sl, ref_decl.sc, ref_decl.el, ref_decl.ec \
                \FROM decls JOIN refs              ON refs.hieFile  = decls.hieFile \
                           \JOIN mods              ON mods.hieFile  = decls.hieFile \
                           \JOIN mods  AS rmods    ON rmods.mod = refs.mod AND rmods.unit = refs.unit AND rmods.is_boot = 0 \
                           \JOIN decls AS ref_decl ON ref_decl.hieFile = rmods.hieFile AND ref_decl.occ = refs.occ \
                \WHERE ((refs.sl > decls.sl) OR (refs.sl = decls.sl AND refs.sc >  decls.sc)) \
                  \AND ((refs.el < decls.el) OR (refs.el = decls.el AND refs.ec <= decls.ec))"
  vs <-
    query_ conn "SELECT mods.mod, decls.hieFile, decls.occ, decls.sl, decls.sc, decls.el, decls.ec \
                   \FROM decls JOIN mods USING (hieFile)"
  return $ overlay ( vertices vs ) ( edges ( map (\( x :. y ) -> ( x, y )) es ) )

getVertices :: HieDb -> [Symbol] -> IO [Vertex]
getVertices (getConn -> conn) ss = Set.toList <$> foldM f Set.empty ss
  where
    f :: Set Vertex -> Symbol -> IO (Set Vertex)
    f vs s = foldl' (flip Set.insert) vs <$> one s

    one :: Symbol -> IO [Vertex]
    one s = do
      let n = toNsChar (occNameSpace $ symName s) : occNameString (symName s)
          m = moduleNameString $ moduleName $ symModule s
          u = unitIdString (moduleUnitId $ symModule s)
      query conn "SELECT mods.mod, decls.hieFile, decls.occ, decls.sl, decls.sc, decls.el, decls.ec \
                 \FROM decls JOIN mods USING (hieFile) \
                 \WHERE ( decls.occ = ? AND mods.mod = ? AND mods.unit = ? ) " (n, m, u)

getReachable :: HieDb -> [Symbol] -> IO [Vertex]
getReachable db symbols = fst <$> getReachableUnreachable db symbols

getUnreachable :: HieDb -> [Symbol] -> IO [Vertex]
getUnreachable db symbols = snd <$> getReachableUnreachable db symbols

html :: (NameCacheMonad m, MonadIO m) => HieDb -> [Symbol] -> m ()
html db symbols = do
    m <- liftIO $ getAnnotations db symbols
    forM_ (Map.toList m) $ \(fp, (mod', sps)) -> do
        code <- sourceCode fp
        let fp' = replaceExtension fp "html"
        liftIO $ putStrLn $ moduleNameString mod' ++ ": " ++ fp'
        liftIO $ Html.generate fp' mod' code $ Set.toList sps

getAnnotations :: HieDb -> [Symbol] -> IO (Map FilePath (ModuleName, Set Html.Span))
getAnnotations db symbols = do
    (rs, us) <- getReachableUnreachable db symbols
    let m1 = foldl' (f Html.Reachable)   Map.empty rs
        m2 = foldl' (f Html.Unreachable) m1        us
    return m2
  where
    f :: Html.Color 
      -> Map FilePath (ModuleName, Set Html.Span) 
      -> Vertex 
      -> Map FilePath (ModuleName, Set Html.Span)
    f c m v =
        let (fp, mod', sp) = g c v
        in  Map.insertWith h fp (mod', Set.singleton sp) m

    g :: Html.Color -> Vertex -> (FilePath, ModuleName, Html.Span)
    g c (mod', fp, _, sl, sc, el, ec) = (fp, mkModuleName mod', Html.Span
        { Html.spStartLine   = sl
        , Html.spStartColumn = sc
        , Html.spEndLine     = el
        , Html.spEndColumn   = ec
        , Html.spColor       = c
        })

    h :: (ModuleName, Set Html.Span)
      -> (ModuleName, Set Html.Span)
      -> (ModuleName, Set Html.Span)
    h (m, sps) (_, sps') = (m, sps <> sps')

getReachableUnreachable :: HieDb -> [Symbol] -> IO ([Vertex], [Vertex])
getReachableUnreachable db symbols = do
  vs <- getVertices db symbols
  graph  <- getGraph db
  let (xs, ys) = splitByReachability graph vs
  return (Set.toList xs, Set.toList ys)

splitByReachability :: Ord a => AdjacencyMap a -> [a] -> (Set a, Set a)
splitByReachability m vs = let s = Set.fromList (dfs vs m) in (s, vertexSet m Set.\\ s)
