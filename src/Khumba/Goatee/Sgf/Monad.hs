-- | A monad for working with a game tree.
module Khumba.Goatee.Sgf.Monad (
  -- * The Go monad
  GoT
  , GoM
  , runGoT
  , runGo
  , evalGoT
  , evalGo
  , execGoT
  , execGo
  , getCursor
    -- * Navigation
  , Step(..)
  , goUp
  , goDown
  , goToRoot
  , goToGameInfoNode
    -- * Remembering positions
  , pushPosition
  , popPosition
  , dropPosition
    -- * Properties
  , getProperties
  , modifyProperties
  , deleteProperties
    -- ** Property modification
  , modifyGameInfo
  , modifyComment
    -- * Children
  , addChild
    -- * Event handling
  , Event
  , on
  , fire
    -- * Events
  , childAddedEvent
  , ChildAddedHandler
  , gameInfoChangedEvent
  , GameInfoChangedHandler
  , navigationEvent
  , NavigationHandler
  , propertiesChangedEvent
  , PropertiesChangedHandler
  ) where

import Control.Monad
import Control.Monad.Identity (Identity, runIdentity)
import Control.Monad.Trans
import Control.Monad.Writer.Class
import Control.Applicative
import qualified Control.Monad.State as State
import Control.Monad.State (StateT)
import Data.List (mapAccumL, nub)
import Data.Maybe
import Khumba.Goatee.Common
import Khumba.Goatee.Sgf.Board
import Khumba.Goatee.Sgf.Property
import Khumba.Goatee.Sgf.Tree hiding (addChild)
import Khumba.Goatee.Sgf.Types

-- | The internal state of a Go monad transformer.  @go@ is the type of
-- Go monad or transformer (instance of 'GoMonad').
data GoState go = GoState { stateCursor :: Cursor
                            -- ^ The current position in the game tree.
                          , statePathStack :: PathStack
                            -- ^ The current path stack.

                          -- Event handlers.
                          , stateChildAddedHandlers :: [ChildAddedHandler go]
                            -- ^ Handlers for 'childAddedEvent'.
                          , stateGameInfoChangedHandlers :: [GameInfoChangedHandler go]
                            -- ^ Handlers for 'gameInfoChangedEvent'.
                          , stateNavigationHandlers :: [NavigationHandler go]
                            -- ^ Handlers for 'navigationEvent'.
                          , statePropertiesChangedHandlers :: [PropertiesChangedHandler go]
                            -- ^ Handlers for 'propertiesChangedEvent'.
                          }

-- | A path stack is a record of previous places visited in a game tree.  It is
-- encoded a list of paths (steps) to each previous memorized position.
--
-- The positions saved in calls to 'pushPosition' correspond to entries in the
-- outer list here, with the first sublist representing the last call.  The
-- sublist contains the steps in order that will trace the path back to the
-- saved position.
type PathStack = [[Step]]

-- | A simplified constructor function for 'GoState'.
initialState :: Cursor -> GoState m
initialState cursor = GoState { stateCursor = cursor
                              , statePathStack = []
                              , stateChildAddedHandlers = []
                              , stateGameInfoChangedHandlers = []
                              , stateNavigationHandlers = []
                              , statePropertiesChangedHandlers = []
                              }

-- | A single step along a game tree.  Either up or down.
data Step = GoUp Int
            -- ^ Represents a step up from a child with the given index.
          | GoDown Int
            -- ^ Represents a step down to the child with the given index.
          deriving (Eq, Show)

-- | Reverses a step, such that taking a step then it's reverse will leave you
-- where you started.
reverseStep step = case step of
  GoUp index -> GoDown index
  GoDown index -> GoUp index

-- | Takes a 'Step' from a 'Cursor', returning a new 'Cursor'.
takeStep :: Step -> Cursor -> Cursor
takeStep (GoUp _) cursor = fromMaybe (error $ "takeStep: Can't go up from " ++ show cursor ++ ".") $
                           cursorParent cursor
takeStep (GoDown index) cursor = cursorChild cursor index

-- | Internal function.  Takes a 'Step' in the Go monad.  Updates the path stack
-- accordingly.
takeStepM :: Monad m => Step -> (PathStack -> PathStack) -> GoT m ()
takeStepM step = case step of
  GoUp _ -> goUp'
  GoDown index -> goDown' index

-- | A monad (transformer) for navigating and mutating 'Cursor's, and
-- remembering previous locations.  See 'GoT' and 'GoM'.
--
-- The monad supports handlers for events raised during actions it takes, such
-- as navigating through the tree and modifying nodes.
class Monad go => MonadGo go where
  -- | Returns the current cursor.
  getCursor :: go Cursor

  -- | Navigates up the tree.  It must be valid to do so, otherwise 'fail' is
  -- called.  Fires a 'navigationEvent' after moving.
  goUp :: go ()

  -- | Navigates down the tree to the child with the given index.  The child
  -- must exist.  Fires a 'navigationEvent' after moving.
  goDown :: Int -> go ()

  -- | Navigates up to the root of the tree.  Fires 'navigationEvent's for each
  -- step.
  goToRoot :: go ()

  -- | Navigates up the tree to the node containing game info properties, if
  -- any.  Returns true if a game info node was found.
  goToGameInfoNode :: Bool
                      -- ^ When no node with game info is found, then if false,
                      -- return to the original node, otherwise finish at the
                      -- root node.
                   -> go Bool

  -- | Pushes the current location in the game tree onto an internal position
  -- stack, such that 'popPosition' is capable of navigating back to the same
  -- position, even if the game tree has been modified (though the old position
  -- must still exist in the tree to return to it).
  pushPosition :: go ()

  -- | Returns to the last position pushed onto the internal position stack via
  -- 'pushPosition'.  This action must be balanced by a 'pushPosition'.
  popPosition :: go ()

  -- | Drops the last position pushed onto the internal stack by 'pushPosition'
  -- off of the stack.  This action must be balanced by a 'pushPosition'.
  dropPosition :: go ()

  -- | Returns the set of properties on the current node.
  getProperties :: go [Property]
  getProperties = liftM (nodeProperties . cursorNode) getCursor

  -- | Modifies the set of properties on the current node.
  --
  -- The given function must end on the same node on which it started.
  modifyProperties :: ([Property] -> go [Property]) -> go ()

  -- | Deletes properties from the current node for which the predicate returns
  -- true.
  deleteProperties :: (Property -> Bool) -> go ()

  -- | Mutates the game info for the current path, returning the new info.  If
  -- the current node or one of its ancestors has game info properties, then
  -- that node is modified.  Otherwise, properties are inserted on the root
  -- node.
  modifyGameInfo :: (GameInfo -> GameInfo) -> go GameInfo

  -- | Mutates the comment attached to the current node according to the given
  -- function.  The input string will be empty if the current node either has a
  -- property @C[]@ or doesn't have a comment property.  Returning an empty
  -- string removes any existing comment node.
  modifyComment :: (String -> String) -> go ()

  -- | Adds a child node to the current node at the given index, shifting all
  -- existing children at and after the index to the right.  The index must in
  -- the range @[0, numberOfChildren]@.  Fires a 'childAddedEvent' after the
  -- child is added.
  addChild :: Int -> Node -> go ()

  -- | Registers a new event handler for a given event type.
  on :: Event go h -> h -> go ()

-- | The regular monad transformer for 'MonadGo'.
newtype GoT m a = GoT { goState :: StateT (GoState (GoT m)) m a }

-- | The regular monad for 'MonadGo'.
type GoM = GoT Identity

instance Monad m => Functor (GoT m) where
  fmap = liftM

instance Monad m => Applicative (GoT m) where
  pure = return
  (<*>) = ap

instance Monad m => Monad (GoT m) where
  return x = GoT $ return x
  m >>= f = GoT $ goState . f =<< goState m
  fail = lift . fail

instance MonadTrans GoT where
  lift = GoT . lift

instance MonadIO m => MonadIO (GoT m) where
  liftIO = lift . liftIO

instance MonadWriter w m => MonadWriter w (GoT m) where
  writer = lift . writer
  tell = lift . tell
  listen = GoT . listen . goState
  pass = GoT . pass . goState

-- | Executes a Go monad transformer on a cursor, returning in the underlying
-- monad a tuple that contains the resulting value and the final cursor.
runGoT :: Monad m => GoT m a -> Cursor -> m (a, Cursor)
runGoT go cursor = do
  (value, state) <- State.runStateT (goState go) (initialState cursor)
  return (value, stateCursor state)

-- | Executes a Go monad transformer on a cursor, returning in the underlying
-- monad the value in the transformer.
evalGoT :: Monad m => GoT m a -> Cursor -> m a
evalGoT go cursor = liftM fst $ runGoT go cursor

-- | Executes a Go monad transformer on a cursor, returning in the underlying
-- monad the final cursor.
execGoT :: Monad m => GoT m a -> Cursor -> m Cursor
execGoT go cursor = liftM snd $ runGoT go cursor

-- | Runs a Go monad on a cursor.  See 'runGoT'.
runGo :: GoM a -> Cursor -> (a, Cursor)
runGo go = runIdentity . runGoT go

-- | Runs a Go monad on a cursor and returns the value in the monad.
evalGo :: GoM a -> Cursor -> a
evalGo m cursor = fst $ runGo m cursor

-- | Runs a Go monad on a cursor and returns the final cursor.
execGo :: GoM a -> Cursor -> Cursor
execGo m cursor = snd $ runGo m cursor

getState :: Monad m => GoT m (GoState (GoT m))
getState = GoT State.get

putState :: Monad m => GoState (GoT m) -> GoT m ()
putState = GoT . State.put

modifyState :: Monad m => (GoState (GoT m) -> GoState (GoT m)) -> GoT m ()
modifyState = GoT . State.modify

instance Monad m => MonadGo (GoT m) where
  getCursor = liftM stateCursor getState

  goUp = do
    index <- liftM cursorChildIndex getCursor
    goUp' $ \pathStack -> case pathStack of
      [] -> pathStack
      path:paths -> (GoDown index:path):paths

  goDown index = goDown' index $ \pathStack -> case pathStack of
    [] -> pathStack
    path:paths -> (GoUp index:path):paths

  goToRoot = whileM (liftM (isJust . cursorParent) getCursor) goUp

  goToGameInfoNode goToRootIfNotFound = pushPosition >> findGameInfoNode
    where findGameInfoNode = do
            cursor <- getCursor
            if hasGameInfo cursor
              then dropPosition >> return True
              else if isNothing $ cursorParent cursor
                   then do if goToRootIfNotFound then dropPosition else popPosition
                           return False
                   else goUp >> findGameInfoNode
          hasGameInfo cursor = internalIsGameInfoNode $ cursorNode cursor

  pushPosition = modifyState $ \state ->
    state { statePathStack = []:statePathStack state }

  popPosition = do
    getPathStack >>= \stack -> when (null stack) $
      fail "popPosition: No position to pop from the stack."

    -- Drop each step in the top list of the path stack one at a time, until the
    -- top list is empty.
    whileM' (do path:_ <- getPathStack
                return $ if null path then Nothing else Just $ head path) $
      flip takeStepM $ \((_:steps):paths) -> steps:paths

    -- Finally, drop the empty top of the path stack.
    modifyState $ \state -> case statePathStack state of
      []:rest -> state { statePathStack = rest }
      _ -> error "popPosition: Internal failure, top of path stack is not empty."

  dropPosition = do
    state <- getState
    -- If there are >=2 positions on the path stack, then we can't simply drop
    -- the moves that will return us to the top-of-stack position, because they
    -- may still be needed to return to the second-on-stack position by a
    -- following popPosition.
    case statePathStack state of
      x:y:xs -> putState $ state { statePathStack = (x ++ y):xs }
      _:[] -> putState $ state { statePathStack = [] }
      [] -> fail "dropPosition: No position to drop from the stack."

  modifyProperties fn = do
    oldCursor <- getCursor
    let oldProperties = cursorProperties oldCursor
    newProperties <- fn oldProperties
    modifyState $ \state ->
      state { stateCursor = cursorModifyNode
                            (\node -> node { nodeProperties = newProperties })
                            oldCursor
            }
    fire propertiesChangedEvent (\f -> f oldProperties newProperties)

    -- The current game info changes when modifying game info properties on the
    -- current node.  I think comparing game info properties should be faster
    -- than comparing 'GameInfo's.
    let filterToGameInfo = nub . filter ((GameInfoProperty ==) . propertyType)
        oldGameInfo = filterToGameInfo oldProperties
        newGameInfo = filterToGameInfo newProperties
    when (newGameInfo /= oldGameInfo) $ do
      newCursor <- getCursor
      fire gameInfoChangedEvent (\f -> f (boardGameInfo $ cursorBoard oldCursor)
                                         (boardGameInfo $ cursorBoard newCursor))

  deleteProperties pred = modifyProperties $ return . filter (not . pred)

  modifyGameInfo fn = do
    cursor <- getCursor
    let info = boardGameInfo $ cursorBoard cursor
        info' = fn info
    when (gameInfoRootInfo info /= gameInfoRootInfo info') $
      fail "Illegal modification of root info in modifyGameInfo."
    pushPosition
    goToGameInfoNode True
    modifyProperties $ \props ->
      return $ gameInfoToProperties info' ++ filter ((GameInfoProperty /=) . propertyType) props
    popPosition
    return info'

  modifyComment fn = do
    node <- cursorNode <$> getCursor
    let maybeOldComment = fromText <$> getProperty propertyC node
        oldComment = fromMaybe "" maybeOldComment
        newComment = fn oldComment
        hasOld = isJust maybeOldComment
        hasNew = not $ null newComment
    case (hasOld, hasNew) of
      (True, False) -> modifyProperties $ return . removeComment
      (False, True) -> modifyProperties $ return . addComment newComment
      (True, True) -> when (newComment /= oldComment) $
                      modifyProperties $ return . addComment newComment . removeComment
      _ -> return ()
    where removeComment = filter (not . propertyPredicate propertyC)
          addComment comment = (C (toText comment):)

  addChild index node = do
    cursor <- getCursor
    let childCount = cursorChildCount cursor
    when (index < 0 || index > childCount) $ fail $
      "Monad.addChild: Index " ++ show index ++ " is not in [0, " ++ show childCount ++ "]."
    let cursor' = cursorModifyNode (addChildAt index node) cursor
    modifyState $ \state -> state { stateCursor = cursor'
                                  , statePathStack = updatePathStackCurrentNode
                                                     (\step -> case step of
                                                         GoUp n -> GoUp $ if n < index then n else n + 1
                                                         down@(GoDown _) -> down)
                                                     (\step -> case step of
                                                         up@(GoUp _) -> up
                                                         GoDown n -> GoDown $ if n < index then n else n + 1)
                                                     cursor'
                                                     (statePathStack state)
                                  }
    fire childAddedEvent (\f -> f index (cursorChild cursor' index))

  on event handler = modifyState $ addHandler event handler

-- | Takes a step up the game tree, updates the path stack according to the
-- given function, then fires navigation and game info changed events as
-- appropriate.
goUp' :: Monad m => (PathStack -> PathStack) -> GoT m ()
goUp' pathStackFn = do
  state@(GoState { stateCursor = cursor
                 , statePathStack = pathStack
                 }) <- getState
  case cursorParent cursor of
    Nothing -> fail $ "goUp': Can't go up from a root cursor: " ++ show cursor
    Just parent -> do
      let index = cursorChildIndex cursor
      putState state { stateCursor = parent
                     , statePathStack = pathStackFn pathStack
                     }
      fire navigationEvent ($ GoUp index)

      -- The current game info changes when navigating up from a node that has
      -- game info properties.
      when (any ((GameInfoProperty ==) . propertyType) $ cursorProperties cursor) $
        fire gameInfoChangedEvent (\f -> f (boardGameInfo $ cursorBoard cursor)
                                           (boardGameInfo $ cursorBoard parent))

-- | Takes a step down the game tree, updates the path stack according to the
-- given function, then fires navigation and game info changed events as
-- appropriate.
goDown' :: Monad m => Int -> (PathStack -> PathStack) -> GoT m ()
goDown' index pathStackFn = do
  state@(GoState { stateCursor = cursor
                 , statePathStack = pathStack
                 }) <- getState
  case drop index $ cursorChildren cursor of
    [] -> fail $ "goDown': Cursor does not have a child #" ++ show index ++ ": " ++ show cursor
    child:_ -> do
      putState state { stateCursor = child
                     , statePathStack = pathStackFn pathStack
                     }
      fire navigationEvent ($ GoDown index)

      -- The current game info changes when navigating down to a node that has
      -- game info properties.
      when (any ((GameInfoProperty ==) . propertyType) $ cursorProperties child) $
        fire gameInfoChangedEvent (\f -> f (boardGameInfo $ cursorBoard cursor)
                                           (boardGameInfo $ cursorBoard child))

-- | Returns the current path stack.
getPathStack :: Monad m => GoT m PathStack
getPathStack = liftM statePathStack getState

-- | Maps over a path stack, updating with the given functions all steps that
-- enter and leave the cursor's current node.
updatePathStackCurrentNode :: (Step -> Step)
                           -> (Step -> Step)
                           -> Cursor
                           -> PathStack
                           -> PathStack
updatePathStackCurrentNode _ _ _ [] = []
updatePathStackCurrentNode onEnter onExit cursor0 paths =
  snd $ mapAccumL updatePath (cursor0, []) paths
  where updatePath :: (Cursor, [Step]) -> [Step] -> ((Cursor, [Step]), [Step])
        updatePath = mapAccumL updateStep
        updateStep :: (Cursor, [Step]) -> Step -> ((Cursor, [Step]), Step)
        updateStep (cursor, []) step = ((takeStep step cursor, [reverseStep step]), onExit step)
        updateStep (cursor, pathToInitial@(stepToInitial:restToInitial)) step =
          let pathToInitial' = if stepToInitial == step
                               then restToInitial
                               else reverseStep step:pathToInitial
          in ((takeStep step cursor, pathToInitial'),
              if null pathToInitial' then onEnter step else step)

-- | Fires all of the handlers for the given event, using the given function to
-- create a Go action from each of the handlers (normally themselves functions
-- that create Go actions, if they're not just Go actions directly, depending on
-- the event).
fire :: Monad m => Event (GoT m) h -> (h -> GoT m ()) -> GoT m ()
fire event handlerGenerator = do
  state <- getState
  mapM_ handlerGenerator $ eventStateGetter event state

-- | A type of event in the Go monad transformer that can be handled by
-- executing an action.  @go@ is the type of the type of the Go
-- monad/transformer.  @h@ is the type of monad or monadic function which will
-- be used by Go actions that can trigger the event.  For example, a navigation
-- event is characterized by a 'Step' that cannot easily be recovered from the
-- regular monad state, and comparing before-and-after states would be a pain.
-- So @h@ for navigation events is @'Step' -> go ()@; a handler takes a 'Step'
-- and returns a Go action to run as a result.
data Event go h = Event { eventName :: String
                        , eventStateGetter :: GoState go -> [h]
                        , eventStateSetter :: [h] -> GoState go -> GoState go
                        }

instance Show (Event go h) where
  show = eventName

addHandler :: Event go h -> h -> GoState go -> GoState go
addHandler event handler state =
  eventStateSetter event (eventStateGetter event state ++ [handler]) state

-- | An event corresponding to a child node being added to the current node.
childAddedEvent :: Event go (ChildAddedHandler go)
childAddedEvent = Event { eventName = "childAddedEvent"
                        , eventStateGetter = stateChildAddedHandlers
                        , eventStateSetter = \handlers state -> state { stateChildAddedHandlers = handlers }
                        }

-- | A handler for a 'childAddedEvent'.
type ChildAddedHandler go = Int -> Cursor -> go ()

gameInfoChangedEvent :: Event go (GameInfoChangedHandler go)
gameInfoChangedEvent = Event { eventName = "gameInfoChangedEvent"
                             , eventStateGetter = stateGameInfoChangedHandlers
                             , eventStateSetter = \handlers state -> state { stateGameInfoChangedHandlers = handlers }
                             }

-- | A handler for a 'gameInfoChangedEvent'.  It is called with the old game
-- info then the new game info.
type GameInfoChangedHandler go = GameInfo -> GameInfo -> go ()

-- | An event that is fired when a single step up or down in a game tree is
-- made.
navigationEvent :: Event go (NavigationHandler go)
navigationEvent = Event { eventName = "navigationEvent"
                        , eventStateGetter = stateNavigationHandlers
                        , eventStateSetter = \handlers state -> state { stateNavigationHandlers = handlers }
                        }

-- | A handler for a 'navigationEvent'.
--
-- A navigation handler may navigate further, but beware infinite recursion.  A
-- navigation handler must end on the same node on which it started.
type NavigationHandler go = Step -> go ()

-- | An event corresponding to a change to the properties list of the current
-- node.
propertiesChangedEvent :: Event go (PropertiesChangedHandler go)
propertiesChangedEvent = Event { eventName = "propertiesChangedEvent"
                               , eventStateGetter = statePropertiesChangedHandlers
                               , eventStateSetter = \handlers state -> state { statePropertiesChangedHandlers = handlers }
                               }

-- | A handler for a 'propertiesChangedEvent'.  It is called with the old
-- property list then the new property list.
type PropertiesChangedHandler go = [Property] -> [Property] -> go ()