{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
module Main
where

import Control.Monad.Reader (ask)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (newIORef, IORef, writeIORef, readIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Tuple (swap)
import Foreign.Ptr (Ptr)
import Graphics.Wayland.Server (DisplayServer, displayInitShm)
import System.IO

import Text.XkbCommon.InternalTypes (Keysym(..))
import Text.XkbCommon.KeysymList

import Graphics.Wayland.WlRoots.Backend (Backend)
import Graphics.Wayland.WlRoots.Compositor (compositorCreate)
import Graphics.Wayland.WlRoots.DeviceManager (managerCreate)
import Graphics.Wayland.WlRoots.Input.Keyboard (WlrModifier(..), modifiersToField)
import Graphics.Wayland.WlRoots.OutputLayout (createOutputLayout)
import Graphics.Wayland.WlRoots.Render.Gles2 (rendererCreate)
import Graphics.Wayland.WlRoots.Screenshooter (screenshooterCreate)
--import Graphics.Wayland.WlRoots.Shell
--    ( WlrShell
--    , --shellCreate
--    )

import Compositor
import Input (inputCreate)
import Layout (reLayout)
--import Layout.Full (Full (..))
import Layout.Tall (Tall (..))
import Output (handleOutputAdd)
import Shared (CompHooks (..), ignoreHooks, launchCompositor)
import View (View)
import ViewSet (Workspace(..), contains, addView, rmView, Layout (..), moveRight, moveLeft)
import Waymonad
    ( WayState
    , WayStateRef
    , LayoutCacheRef
    , get
    , modify
    , runLayoutCache
    , runWayState
    , BindingMap
    , KeyBinding
    )
import WayUtil (modifyCurrentWS, setWorkspace, spawn)
import XWayland (xwayShellCreate)
import XdgShell (xdgShellCreate)

import qualified Data.Map.Strict as M

insertView
    :: Ord a
    => LayoutCacheRef
    -> IORef Int
    -> IORef [(a, Int)]
    -> View
    -> WayState a ()
insertView cacheRef currentOut wsMapping view = do
    mapping <- liftIO $ readIORef wsMapping
    current <- liftIO $ readIORef currentOut
    case M.lookup current . M.fromList $ map swap mapping of
        Nothing -> liftIO $ hPutStrLn stderr "Couldn't lookup workspace for current output"
        Just ws -> do
            modify $ M.adjust (addView Nothing view) ws
            reLayout cacheRef ws mapping

removeView
    :: (Ord a, Show a)
    => LayoutCacheRef
    -> IORef [(a, Int)]
    -> View
    -> WayState a ()
removeView cacheRef wsMapping view = do
    mapping <- liftIO $ readIORef wsMapping
    wsL <- filter (fromMaybe False . fmap (contains view) . wsViews . snd) . M.toList <$> get

    case wsL of
        [(ws, _)] -> do
            modify $ M.adjust (rmView view) ws
            reLayout cacheRef ws mapping
        xs -> liftIO $ do
            hPutStrLn stderr "Found a view in a number of workspaces that's not 1!"
            hPutStrLn stderr $ show $ map fst xs

bindings :: [(([WlrModifier], Keysym), KeyBinding Text)]
bindings =
    [ (([modi], keysym_j), modifyCurrentWS moveRight)
    , (([modi], keysym_k), modifyCurrentWS moveLeft)
    , (([modi], keysym_1), setWorkspace "1")
    , (([modi], keysym_2), setWorkspace "2")
    , (([modi], keysym_3), setWorkspace "3")
    , (([modi], keysym_4), setWorkspace "4")
    , (([modi], keysym_5), setWorkspace "5")
    , (([modi], keysym_6), setWorkspace "6")
    , (([modi], keysym_7), setWorkspace "7")
    , (([modi], keysym_8), setWorkspace "8")
    , (([modi], keysym_9), setWorkspace "9")
    , (([modi], keysym_0), setWorkspace "0")
    , (([modi], keysym_Return), spawn "weston-terminal")
    ]
    where modi = Alt

makeBindingMap :: Ord a => [(([WlrModifier], Keysym), KeyBinding a)] -> BindingMap a
makeBindingMap = M.fromList .
    map (\((mods, Keysym sym), fun) -> ((modifiersToField mods, sym), fun))

makeCompositor
    :: (Ord a, Show a)
    => DisplayServer
    -> Ptr Backend
    -> LayoutCacheRef
    -> IORef [(a, Int)]
    -> IORef Int
    -> [(([WlrModifier], Keysym), KeyBinding a)]
    -> WayState a Compositor
makeCompositor display backend ref mappings currentOut keyBinds = do
    let addFun = insertView ref currentOut mappings
    let delFun = removeView ref mappings
    renderer <- liftIO $ rendererCreate backend
    void $ liftIO $ displayInitShm display
    comp <- liftIO $ compositorCreate display renderer
    devManager <- liftIO $ managerCreate display
--    shell <- liftIO $ shellCreate display
    xdgShell <- xdgShellCreate display   addFun delFun
    xway <- xwayShellCreate display comp addFun delFun
    layout <- liftIO $ createOutputLayout
    stateRef <- ask
    input <- runLayoutCache (inputCreate display layout backend currentOut mappings stateRef (makeBindingMap keyBinds)) ref
    shooter <- liftIO $ screenshooterCreate display renderer
    pure $ Compositor
        { compDisplay = display
        , compRenderer = renderer
        , compCompositor = comp
        , compShell = undefined -- shell
        , compXdg = xdgShell
        , compManager = devManager
        , compXWayland = xway
        , compBackend = backend
        , compLayout = layout
        , compInput = input
        , compScreenshooter = shooter
        }

workspaces :: [Text]
workspaces = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]


defaultMap :: Ord a => [a] -> IO (WayStateRef a)
defaultMap xs = newIORef $ M.fromList $
    map (, Workspace (Layout Tall) Nothing) xs

realMain :: IO ()
realMain = do
    stateRef  <- defaultMap workspaces
    layoutRef <- newIORef mempty
    dpRef <- newIORef undefined
    compRef <- newIORef undefined
    mapRef <- newIORef []
    currentRef <- newIORef 0
    launchCompositor ignoreHooks
        { displayHook = writeIORef dpRef
        , backendPreHook = \backend -> do
            dsp <- readIORef dpRef
            writeIORef compRef =<< runWayState (makeCompositor dsp backend layoutRef mapRef currentRef bindings) stateRef
          , outputAddHook = handleOutputAdd compRef layoutRef workspaces mapRef currentRef
        }
    pure ()

main :: IO ()
main = realMain