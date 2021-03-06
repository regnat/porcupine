{-# LANGUAGE Arrows                     #-}
{-# LANGUAGE ConstrainedClassMethods    #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PartialTypeSignatures      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# OPTIONS_GHC -Wall #-}

-- | This module provides some utilities for when the pipeline needs to access
-- several files organized in layers for each location in the 'LocationTree'
module System.TaskPipeline.VirtualFileAccess
  ( -- * Reexports
    module Data.Locations.LogAndErrors

    -- * High-level API
  , loadData
  , loadDataStream
  , tryLoadDataStream
  , writeData
  , writeDataStream

    -- * Lower-level API
  , EffectSeq(..), EffectSeqFromList(..)
  , SingletonES(..), ListES(..), StreamES(..)
  , AccessToPerform(..)
  , DataAccessor(..)
  , VFNodeAccessType(..)
  , accessVirtualFile'
  , getVFileDataAccessor
  , getLocsMappedTo

    -- * Internal API
  , accessVirtualFile
  , withVFileInternalAccessFunction
  , withFolderDataAccessNodes
  ) where

import           Prelude                            hiding (id, (.))

import           Control.Lens
import           Control.Monad                      (forM)
import           Control.Monad.Trans
import qualified Data.Foldable                      as F
import qualified Data.HashMap.Strict                as HM
import           Data.Locations
import           Data.Locations.LogAndErrors
import           Data.Monoid
import           Data.Representable
import qualified Data.Text                          as T
import           Data.Typeable
import           Streaming                          (Of (..), Stream)
import qualified Streaming.Prelude                  as S
import           System.TaskPipeline.PTask
import           System.TaskPipeline.PTask.Internal
import           System.TaskPipeline.ResourceTree


-- | Uses only the read part of a 'VirtualFile'. It is therefore considered as a
-- pure 'DataSource'. For practical reasons the task input is () rather than
-- Void.
loadData
  :: (LogThrow m, Typeable a, Typeable b)
  => VirtualFile a b -- ^ Use as a 'DataSource'
  -> PTask m () b  -- ^ The resulting task
loadData vf =
      arr (\_ -> SingletonES $ return ([] :: [Int], error "loadData: THIS IS VOID"))
  >>> accessVirtualFile (DoRead id) [] vf
  >>> unsafeLiftToPTask (fmap snd . getSingletonFromES)

-- | Loads a stream of repeated occurences of a VirtualFile, from a stream of
-- indices. The process is lazy: the data will actually be read when the
-- resulting stream is consumed.
loadDataStream :: forall idx m a b r.
                  (Show idx, LogThrow m, Typeable a, Typeable b)
               => LocVariable
               -> VirtualFile a b -- ^ Used as a 'DataSource'
               -> PTask m (Stream (Of idx) m r) (Stream (Of (idx, b)) m r)
loadDataStream lv vf =
      arr (StreamES . S.map (,error "loadDataStream: THIS IS VOID"))
  >>> accessVirtualFile' (DoRead id) lv vf
  >>> arr streamFromES

-- | Like 'loadDataStream', but won't stop on a failure on a single file
tryLoadDataStream :: (Exception e, Show idx, LogCatch m, Typeable a, Typeable b)
                  => LocVariable
                  -> VirtualFile a b -- ^ Used as a 'DataSource'
                  -> PTask m (Stream (Of idx) m r) (Stream (Of (idx, Either e b)) m r)
tryLoadDataStream lv vf =
       arr (StreamES . S.map (,error "loadDataStream: THIS IS VOID"))
  >>> accessVirtualFile' (DoRead try) lv vf
  >>> arr streamFromES

-- | Uses only the write part of a 'VirtualFile'. It is therefore considered as
-- a pure 'DataSink'.
writeData
  :: (LogThrow m, Typeable a, Typeable b)
  => VirtualFile a b  -- ^ Used as a 'DataSink'
  -> PTask m a ()
writeData vf =
      arr (SingletonES . return . ([] :: [Int],))
  >>> accessVirtualFile (DoWrite id) [] vf
  >>> unsafeLiftToPTask runES

-- | The simplest way to consume a stream of data inside a pipeline. Just write
-- it to repeated occurences of a VirtualFile. See
-- System.TaskPipeline.Repetition.Fold for more complex ways to consume a
-- Stream.
writeDataStream :: (Show idx, LogThrow m, Typeable a, Typeable b)
                => LocVariable
                -> VirtualFile a b -- ^ Used as a 'DataSink'
                -> PTask m (Stream (Of (idx, a)) m r) r
writeDataStream lv vf =
      arr StreamES
  >>> accessVirtualFile' (DoWrite id) lv vf
  >>> unsafeLiftToPTask runES

-- | Gets a DataAccessor for the VirtualFile, ie. doesn't read or write it
-- immediately but gets a function that will make it possible
getVFileDataAccessor
  :: (LogThrow m, Typeable a, Typeable b)
  => [VFNodeAccessType] -- ^ The accesses that will be performed on the DataAccessor
  -> VirtualFile a b
  -> PTask m () (DataAccessor m a b)
getVFileDataAccessor accesses vfile = withVFileInternalAccessFunction accesses vfile
  (\mkAccessor _ -> return $ mkAccessor mempty)


-- | Gives a wrapper that should be used when the actual read or write is
-- performed.
data AccessToPerform m b b'
  = DoWrite (m () -> m b')
  | DoRead (m b -> m b')
  | DoWriteAndRead (m b -> m b')

-- | A unique value, computed from a action in @m@
newtype SingletonES m a = SingletonES { getSingletonFromES :: m a }

-- | Just a wrapper around [m a]
newtype ListES m a = ListES { getListFromES :: [m a] }

-- | Just a wrapper around Stream, with arguments reordered
newtype StreamES r m a = StreamES { getStreamFromES :: Stream (Of a) m r }

-- | Some class around Stream (Of a) m () and [m a].
class EffectSeq seq where
  type ESResult seq :: *
  mapES :: (Monad m) => (a -> b) -> seq m a -> seq m b
  mapESM :: (Monad m) => (a -> m b) -> seq m a -> seq m b
  streamFromES :: (Monad m) => seq m a -> Stream (Of a) m (ESResult seq)
  runES :: (Monad m) => seq m a -> m (ESResult seq)

instance EffectSeq SingletonES where
  type ESResult SingletonES = ()
  mapES f = SingletonES . fmap f . getSingletonFromES
  mapESM f = SingletonES . (>>= f) . getSingletonFromES
  streamFromES (SingletonES act) = lift act >>= S.yield
  runES (SingletonES act) = act >> return ()

instance EffectSeq ListES where
  type ESResult ListES = ()
  mapES f = ListES . map (f <$>) . getListFromES
  mapESM f = ListES . map (>>= f) . getListFromES
  streamFromES = mapM_ (\act -> lift act >>= S.yield) . getListFromES
  runES = sequence_ . getListFromES

instance EffectSeq (StreamES r) where
  type ESResult (StreamES r) = r
  mapES f = StreamES . S.map f . getStreamFromES
  mapESM f = StreamES . S.mapM f . getStreamFromES
  streamFromES = getStreamFromES
  runES = S.effects . getStreamFromES

class (EffectSeq seq) => EffectSeqFromList seq where
  esFromList :: (Monad m, ESResult seq ~ ()) => [a] -> seq m a

instance EffectSeqFromList ListES where
  esFromList = ListES . map return

instance EffectSeqFromList (StreamES r) where
  esFromList = StreamES . S.each

-- | Like 'accessVirtualFile', but uses only one repetition variable
accessVirtualFile' :: forall seq idx m a b b'.
                      (Show idx, LogThrow m, Typeable a, Typeable b
                      ,EffectSeq seq)
                   => AccessToPerform m b b'
                   -> LocVariable
                   -> VirtualFile a b -- ^ Used as a 'DataSource'
                   -> PTask m (seq m (idx, a)) (seq m (idx, b'))
accessVirtualFile' access repIndex vf =
      arr (mapES $ \(i, a) -> ([i], a))
  >>> accessVirtualFile access [repIndex] vf
  >>> arr (mapES $ \(i, r) -> (head i, r))

toAccessTypes :: AccessToPerform m b b' -> [VFNodeAccessType]
toAccessTypes ac = case ac of
  DoWriteAndRead{} -> [ATWrite,ATRead]
  DoWrite{}        -> [ATWrite]
  DoRead{}         -> [ATRead]

-- | When building the pipeline, stores into the location tree the way to read
-- or write the required resource. When running the pipeline, access the
-- instances of this ressource corresponding to the values of some repetition
-- indices.
accessVirtualFile
  :: forall m a b b' seq idx.
     (LogThrow m, Typeable a, Typeable b, Show idx
     ,EffectSeq seq)
  => AccessToPerform m b b'
  -> [LocVariable]  -- ^ The list of repetition indices. Can be empty if the
                    -- file isn't meant to be repeated
  -> VirtualFile a b  -- ^ The VirtualFile to access
  -> PTask m (seq m ([idx], a)) (seq m ([idx], b'))  -- ^ The resulting task reads a stream of indices and
                        -- input values and returns a stream of the same indices
                        -- associated to their outputs.
accessVirtualFile accessToDo repIndices vfile =
  withVFileInternalAccessFunction (toAccessTypes accessToDo) vfile' $
    \accessFn inputStream ->
      return $ mapESM (runOnce accessFn) inputStream
  where
    runOnce :: (LocVariableMap -> DataAccessor m a b) -> ([idx], a) -> m ([idx], b')
    runOnce accessFn (ixVals, input) = do
      (ixVals,) <$> case accessToDo of
        DoWrite wrap        -> wrap $ daPerformWrite da input
        DoRead wrap         -> wrap $ daPerformRead da
        DoWriteAndRead wrap -> wrap $ daPerformWrite da input >> daPerformRead da
      where
        da = accessFn lvMap
        lvMap = HM.fromList $ zip repIndices $ map show ixVals
    vfile' = case repIndices of
      [] -> vfile
      _  -> vfile & over (vfileSerials.serialsRepetitionKeys) (repIndices++)

-- | Executes as a task a function that needs to access the content of the
-- DataAccessNode of a VirtualFile.
withVFileInternalAccessFunction
  :: forall m i o a b.
     (LogThrow m, Typeable a, Typeable b)
  => [VFNodeAccessType]  -- ^ The accesses that will be performed on it
  -> VirtualFile a b  -- ^ The VirtualFile to access
  -> ((LocVariableMap -> DataAccessor m a b) -> i -> m o)
         -- ^ The action to run. It will be a function to access the
         -- VirtualFile. The LocVariableMap can just be empty if the VirtualFile
         -- isn't meant to be repeated
  -> PTask m i o
withVFileInternalAccessFunction accessesToDo vfile f =
  withFolderDataAccessNodes path (Identity fname) $
    \(Identity n) input -> case n of
      DataAccessNode _ (action :: LocVariableMap -> DataAccessor m a' b') ->
        case (eqT :: Maybe (a :~: a'), eqT :: Maybe (b :~: b')) of
          (Just Refl, Just Refl)
            -> f action input
          _ -> err "input or output types don't match"
      _ -> err "no access action is present in the tree"
  where
    path = init $ vfile ^. vfileOriginalPath
    fname = file (last $ vfile ^. vfileOriginalPath) $ VirtualFileNode accessesToDo vfile
    err s = throwWithPrefix $
      "withVFileInternalAccessFunction (" ++ showVFileOriginalPath vfile ++ "): " ++ s

-- | Wraps in a task a function that needs to access some items present in a
-- subfolder of the 'LocationTree' and mark these accesses as done.
withFolderDataAccessNodes
  :: (LogThrow m, Traversable t)
  => [LocationTreePathItem]              -- ^ Path to folder in 'LocationTree'
  -> t (LTPIAndSubtree VirtualFileNode)  -- ^ Items of interest in the subfolder
  -> (t (DataAccessNode m) -> i -> m o)  -- ^ What to run with these items
  -> PTask m i o                         -- ^ The resulting PTask
withFolderDataAccessNodes path filesToAccess accessFn =
  makePTask tree runAccess
  where
    tree = foldr (\pathItem subtree -> folderNode [ pathItem :/ subtree ])
                 (folderNode $ F.toList filesToAccess) path
    runAccess rscTree input = do
      let mbSubtree = rscTree ^? atSubfolderRec path
      subtree <- case mbSubtree of
        Just s -> return s
        Nothing -> throwWithPrefix $
          "path '" ++ show path ++ "' not found in the LocationTree"
      nodeTags <- forM filesToAccess $ \(filePathItem :/ _) -> do
        case subtree ^? atSubfolder filePathItem . locTreeNodeTag of
          Nothing -> throwWithPrefix $
            "path '" ++ show filePathItem ++ "' not found in the LocationTree"
          Just tag -> return tag
      accessFn nodeTags input

-- | Returns the locs mapped to some path in the location tree. It *doesn't*
-- expose this path as a requirement (hence the result list may be empty, as no
-- mapping might exist). SHOULD NOT BE USED UNLESS loadData/writeData cannot do
-- what you want.
getLocsMappedTo :: (LogThrow m)
                => [LocationTreePathItem] -> PTask m () [Loc]
getLocsMappedTo path = runnableWithoutReqs $ withRunnableState $
                         \state _ -> getLocs $ state^.ptrsDataAccessTree
  where
    onErr (Left s) = throwWithPrefix $
      "getLocsMappedTo (" ++ T.unpack (toTextRepr (LTP path)) ++ "): " ++ s
    onErr (Right x) = return x
    getLocs tree =
      case tree ^? (atSubfolderRec path . locTreeNodeTag) of
        -- NOTE: Will fail on repeated folders (because here we can only access
        -- the final locations -- with variables spliced in -- in the case of
        -- nodes with a data access function, not intermediary folders).
        Just (MbDataAccessNode locsWithVars (First mbAccess)) -> case mbAccess of
          Just (SomeDataAccess fn) -> onErr $ daLocsAccessed $ fn mempty
          Nothing -> onErr $ traverse terminateLocWithVars locsWithVars
        _ -> return []
