{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeSynonymInstances #-}
module Waymonad
    ( get
    , modify

    , WayStateRef
    , WayState
    , runWayState
    , runWayState'

    , LayoutCacheRef
    , LayoutCache
    , runLayoutCache

    , viewBelow

    , KeyBinding
    , BindingMap

    , WayBindingState (..)
    , runWayBinding
    )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (ReaderT(..), MonadReader(..))
import Data.IORef (IORef, modifyIORef, readIORef)
import Data.Map (Map)
import Data.Word (Word32)
import Foreign.Ptr (Ptr)

import Graphics.Wayland.WlRoots.Box (Point, WlrBox)
import Graphics.Wayland.WlRoots.Seat (WlrSeat)

import View (View)
import qualified ViewSet as VS

import Data.IntMap (IntMap)
import qualified Data.IntMap as IM


-- All of this makes for a fake `Monad State` in IO
-- We need this because we run into callbacks *a lot*.
-- We have to preserve/modify state around those, which cannot be
-- done with the normal StateT (since we exit our Monad-Stack all the time)
-- but we are in IO, which can be abused with this trick.
-- It should all be hidden in the high level apis, low level APIs will
-- require the get and runWayState around callbacks that are IO
type WayStateRef a = IORef (VS.ViewSet a)

type LayoutCacheRef = IORef (IntMap [(View, WlrBox)])

newtype LayoutCache a = LayoutCache (ReaderT (LayoutCacheRef) IO a)
    deriving (Functor, Applicative, Monad, MonadIO, MonadReader LayoutCacheRef)

newtype WayState a b = WayState (ReaderT (WayStateRef a) IO b)
    deriving (Functor, Applicative, Monad, MonadIO, MonadReader (WayStateRef a))

get :: (MonadReader (IORef a) m, MonadIO m) => m a
get = liftIO . readIORef =<< ask

modify :: (MonadReader (IORef a) m, MonadIO m) => (a -> a) -> m ()
modify fun = do
    ref <- ask
    liftIO $ modifyIORef ref fun

runWayState :: MonadIO m =>  WayState a b -> WayStateRef a -> m b
runWayState (WayState m) ref = liftIO $ runReaderT m ref

runWayState' :: MonadIO m => WayStateRef a -> WayState a b -> m b
runWayState' ref act = runWayState act ref

runLayoutCache :: MonadIO m => LayoutCache a -> LayoutCacheRef -> m a
runLayoutCache (LayoutCache m) ref = liftIO $ runReaderT m ref

viewBelow :: Point -> Int -> LayoutCache (Maybe View)
viewBelow point ws = do
    fullCache <- get
    case IM.lookup ws fullCache of
        Nothing -> pure Nothing
        Just x -> liftIO $ VS.viewBelow point x

data WayBindingState a = WayBindingState
    { wayBindingCache :: LayoutCacheRef
    , wayBindingState :: WayStateRef a
    , wayBindingCurrent :: IORef Int
    , wayBindingMapping :: IORef [(a, Int)]
    , wayBindingSeat :: Ptr WlrSeat
    }

newtype WayBinding a b = WayBinding (ReaderT (WayBindingState a) IO b)
    deriving (Functor, Applicative, Monad, MonadIO, MonadReader (WayBindingState a))

runWayBinding :: MonadIO m => WayBindingState a -> WayBinding a b -> m b
runWayBinding val (WayBinding act) = liftIO $ runReaderT act val

type KeyBinding a = WayBinding a ()
type BindingMap a = Map (Word32, Int) (KeyBinding a)