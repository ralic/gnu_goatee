-- | Common utilities used throughout the project.
module Khumba.Goatee.Common (
  listReplace
  , listUpdate
  , fromLeft
  , fromRight
  , onLeft
  , onRight
  , andEithers
  , mapTuple
  , whenMaybe
  , cond
  , whileM
  , whileM'
  , Seq(..)
  ) where

import Control.Arrow ((***))
import Control.Monad (join, when)
import Data.Either (partitionEithers)
import Data.Monoid (Monoid, mempty, mappend)

-- | @listReplace old new list@ replaces all occurrences of @old@ with @new@ in
-- @list@.
listReplace :: Eq a => a -> a -> [a] -> [a]
listReplace from to = map $ replace from to
  where replace from to x = if x == from then to else x

-- | Modifies the element at a specific index in a list.
listUpdate :: Show a => (a -> a) -> Int -> [a] -> [a]
listUpdate fn ix xs = listSet' ix xs
  where listSet' 0 (x':xs') = fn x':xs'
        listSet' ix' (x':xs') = x':listSet' (ix' - 1) xs'
        listSet' _ _ = error ("Cannot update index " ++ show ix ++
                              " of list " ++ show xs ++ ".")

-- | Extracts a left value from an 'Either'.
fromLeft :: Either a b -> a
fromLeft (Left a) = a
fromLeft _ = error "fromLeft given a Right."

-- | Extracts a right value from an 'Either'.
fromRight :: Either a b -> b
fromRight (Right b) = b
fromRight _ = error "fromRight given a Left."

-- | Transforms the left value of an 'Either', leaving a right value alone.
onLeft :: (a -> c) -> Either a b -> Either c b
f `onLeft` e = case e of
  Left x -> Left $ f x
  Right y -> Right y

-- | Transforms the right value of an 'Either', leaving a left value alone.
-- This is just 'fmap', but looks nicer when used beside 'onLeft'.
onRight :: (b -> c) -> Either a b -> Either a c
onRight = fmap

-- | If any item is a 'Left', then the list of 'Left's is returned, otherwise
-- the list of 'Right's is returned.
andEithers :: [Either a b] -> Either [a] [b]
andEithers xs = let (as, bs) = partitionEithers xs
                in if not $ null as then Left as else Right bs

-- | Transforms both values in a homogeneous tuple.
mapTuple :: (a -> b) -> (a, a) -> (b, b)
mapTuple = join (***)

-- | Executes the monadic function if a 'Maybe' contains a value.
whenMaybe :: Monad m => Maybe a -> (a -> m ()) -> m ()
whenMaybe = flip $ maybe (return ())

-- | Finds the first tuple whose first element is true, and returns its second
-- element.  If all of the first values are false, then the first argument to
-- @cond@ is returned instead.
cond :: a -> [(Bool, a)] -> a
cond fallback ((test, body):rest) = if test then body else cond fallback rest
cond fallback _ = fallback

-- | @whileM test body@ repeatedly evaluates @test@ until it returns false.
-- Every time @test@ returns true, @body@ is executed once.
whileM :: Monad m => m Bool -> m () -> m ()
whileM test body = do x <- test
                      when x $ body >> whileM test body

-- | @whileM' test body@ repeatedly evaluates @test@ until it returns 'Nothing'.
-- Every time it returns a 'Just', that value is passed to @body@ and the result
-- is executed.
whileM' :: Monad m => m (Maybe a) -> (a -> m ()) -> m ()
whileM' test body = do x <- test
                       case x of
                         Nothing -> return ()
                         Just y -> body y >> whileM' test body

-- | This sequences @()@-valued monadic actions as a monoid.  If @m@ is some
-- monad, then @Seq m@ is a monoid where 'mempty' does nothing and 'mappend'
-- sequences actions via '>>'.
newtype Seq m = Seq (m ())

instance Monad m => Monoid (Seq m) where
  mempty = Seq $ return ()

  (Seq x) `mappend` (Seq y) = Seq (x >> y)