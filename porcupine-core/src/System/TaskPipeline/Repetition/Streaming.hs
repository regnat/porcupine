{-# LANGUAGE Arrows            #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module System.TaskPipeline.Repetition.Streaming
  ( STask, ISTask, OSTask
  , mappingOverStream
  , mappingOverStream_
  , repeatedlyWriteData
  , repeatedlyLoadData
  , repeatedlyLoadData'
  , listToStreamTask, runStreamTask, streamToListTask
  , Typeable
  ) where

import           Control.Arrow
import           Control.Category
import           Control.Lens                            hiding ((:>), (.=))
import           Control.Monad
import           Data.Locations
import           Katip
import           Prelude                                 hiding (id, (.))
import           Streaming                               (Of (..), Stream)
import qualified Streaming.Prelude                       as S
import           System.TaskPipeline.PTask
import           System.TaskPipeline.PTask.Internal
import           System.TaskPipeline.Repetition.Internal
import           System.TaskPipeline.VirtualFileAccess


-- * Type aliases for tasks over streams

-- | An PTask mapping a action over a Stream, transforming @a@'s into
-- @b@'s. Each element in the stream should be associated to an identifier.
type STask m i a b r =
  PTask m
        (Stream (Of (i, a)) m r)
        (Stream (Of (i, b)) m r)

-- | An 'PTask' that consumes an Input Stream and just returns its result.
type ISTask m i a r =
  PTask m
        (Stream (Of (i, a)) m r)
        r

-- | An 'PTask' that emits an Output Stream.
type OSTask m i a b =
  PTask m
        a
        (Stream (Of (i, b)) m ())

-- * Running tasks over streams

-- | Turns a task into something that will be repeated once per each item in its
-- input. This is done by transforming VirtualFile accessed by the tasks to add
-- a 'RepetitionKey' to it, indicating that its final file name should be
-- modified by adding an identifier to it just before reading it or writing it.
-- So each loop actually accesses different locations in the end.
--
-- Calls to 'mappingOverStream' can be nested, this way the underlying VirtualFiles
-- will have one 'RepetitionKey' per loop (from outermost loop to innermost).
mappingOverStream
  :: (CanRunPTask m, Show i)
  => LocVariable       -- ^ A variable name, used as a key to indicate which
                       -- repetition we're at. Used in the logger context and
                       -- exposed in the yaml file for each VirtualFile that
                       -- will be repeated by this task
  -> Maybe Verbosity   -- ^ The minimal vebosity level at which to display the
                       -- logger context. (Nothing if we don't want to add
                       -- context)
  -> PTask m a b       -- ^ The base task X to repeat
  -> STask m i a b r   -- ^ A task that will repeat X it for each input. Each
                       -- input is associated to a identifier that will be
                       -- appended to every Loc mapped to every leaf in the
                       -- LocationTree given to X.
mappingOverStream repetitionKey mbVerb =
    over ptaskRunnable mappingRunnableOverStream
  . makeRepeatable (RepInfo repetitionKey mbVerb)

-- | IMPORTANT: That requires the RunnablePTask to be repeatable. See
-- 'makeRepeatable'.
mappingRunnableOverStream
  :: (CanRunPTask m)
  => RunnablePTask m a b
  -> RunnablePTask m
       (Stream (Of a) m r)
       (Stream (Of b) m r)
mappingRunnableOverStream runnable =
  withRunnableState $ \state inputStream -> do
    firstElem <- S.next inputStream
    case firstElem of
      Left r -> return (return r)  -- Empty input stream
      Right (firstInput, inputStream') -> do
        firstResult <- go state firstInput
        return $
          firstResult `S.cons` S.mapM (go state) inputStream'
  where
    go = execRunnablePTask runnable
         -- NOTE: We "cheat" here: we run the funflow layer of the inner
         -- task. We should find a way not to have to do that, but when using
         -- Streaming (which delays effects in a monad) it's really problematic.

-- | See 'mappingOverStream'. Just runs the resulting stream and returns its end
-- result.
mappingOverStream_
  :: (CanRunPTask m, Show i)
  => LocVariable
  -> Maybe Verbosity
  -> PTask m a b
  -> ISTask m i a r
mappingOverStream_ k v t =
  mappingOverStream k v t >>> runStreamTask

-- | Writes to the same virtual file each element in the input stream, but
-- changing each time the value associated to a repetition key (so the physical
-- file will be different each time). Returns the result of the input stream.
repeatedlyWriteData
  :: (CanRunPTask m, Typeable a, Typeable b, Show i)
  => LocVariable
  -> VirtualFile a b -- ^ Use as a 'DataSink'
  -> ISTask m i a r
repeatedlyWriteData rkey vf =
  mappingOverStream_ rkey (Just V1) $ writeData vf

-- | Reads from the same virtual file for each index in the input stream, but
-- changing each time the value associated to a repetition key (so the physical
-- file will be different each time).
repeatedlyLoadData
  :: (CanRunPTask m, Typeable a, Typeable b, Show i)
  => LocVariable
  -> VirtualFile a b -- ^ Used as a 'DataSource'
  -> OSTask m i (Stream (Of i) m r) b
repeatedlyLoadData rkey vf =
  arr (fmap (const ()) . S.map (,()))
  >>>
  mappingOverStream rkey (Just V1) (loadData vf)

-- | Like 'repeatedlyLoadData', except the stream of indices to read is obtained
-- from a list whose elements can be Shown.
repeatedlyLoadData'
  :: (CanRunPTask m, Typeable a, Typeable b, Show i)
  => LocVariable
  -> VirtualFile a b -- ^ Used as a 'DataSource'
  -> OSTask m i [i] b
repeatedlyLoadData' rkey vf =
  arr S.each >>> repeatedlyLoadData rkey vf


-- * Helper functions to create and run streams

-- | Runs the input stream, forgets all its elements and just returns its result
runStreamTask :: (KatipContext m)
              => PTask m
                       (Stream (Of t) m r)
                       r
runStreamTask = unsafeLiftToPTask S.effects

-- | An 'PTask' converting a list to a stream
listToStreamTask :: (Monad m)
                 => PTask m
                          [t]
                          (Stream (Of t) m ())
listToStreamTask = arr S.each

-- | An 'PTask' converting an input stream to a list. WARNING: It can cause
-- space leaks if the list is too big, as the output list will be eagerly
-- evaluated. This function is provided only for compatibility with existing
-- tasks expecting lists. Please consider switching to processing streams
-- directly. See 'S.toList' for more details.
streamToListTask :: (KatipContext m)
                 => PTask m
                          (Stream (Of t) m r)
                          [t]
streamToListTask = unsafeLiftToPTask (S.toList_ . fmap (const ()))
