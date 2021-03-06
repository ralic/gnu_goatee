-- This file is part of Goatee.
--
-- Copyright 2014-2015 Bryan Gardiner
--
-- Goatee is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- Goatee is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU Affero General Public License for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with Goatee.  If not, see <http://www.gnu.org/licenses/>.

{-# LANGUAGE FlexibleContexts #-}

module Game.Goatee.CommonTest (tests) where

import qualified Control.Monad.State as State
import Control.Monad.Identity (runIdentity)
import Control.Monad.State (get, put, runStateT)
import Control.Monad.Writer (execWriter, tell)
import Data.IORef (modifyIORef, newIORef, readIORef)
import Data.List (sort)
import qualified Data.Map as Map
import Data.Map (Map)
import Game.Goatee.Common
import Test.HUnit ((~:), (@=?), Test (TestList), assertFailure)

{-# ANN module "HLint: ignore Use camelCase" #-}

tests = "Game.Goatee.Common" ~: TestList
  [ listDeleteAtTests
  , listInsertAtTests
  , listReplaceTests
  , andEithersTests
  , forTests
  , mapTupleTests
  , mapInvertTests
  , whenMaybeTests
  , condTests
  , if'Tests
  , andMTests
  , forIndexM_Tests
  , whileMTests
  , whileM'Tests
  , doWhileMTests
  ]

listDeleteAtTests = "listDeleteAt" ~: TestList
  [ "deletes nothing from an empty list" ~: do
    [] @=? listDeleteAt (-1) ([] :: [()])
    [] @=? listDeleteAt 0 ([] :: [()])
    [] @=? listDeleteAt 1 ([] :: [()])

  , "deletes the only item from a singleton list" ~:
    [] @=? listDeleteAt 0 [()]

  , "deletes the head of a list" ~:
    [False] @=? listDeleteAt 0 [True, False]

  , "deletes the tail of a list" ~:
    [Just 0, Nothing] @=? listDeleteAt 2 [Just 0, Nothing, Just 1]

  , "deletes an inner item from a list" ~:
    [Just 0, Just 1] @=? listDeleteAt 1 [Just 0, Nothing, Just 1]

  , "ignores a negative index" ~: do
    [1, 2, 3] @=? listDeleteAt (-1) [1, 2, 3]
    [1, 2, 3] @=? listDeleteAt (-2) [1, 2, 3]

  , "ignores an index too large" ~: do
    [1, 2, 3] @=? listDeleteAt 3 [1, 2, 3]
    [1, 2, 3] @=? listDeleteAt 4 [1, 2, 3]
  ]

listInsertAtTests = "listInsertAt" ~: TestList
  [ "adds at the beginning of a list" ~: do
    let expected = [10, 3, 1, 5, 2]
    expected @=? listInsertAt 0 elt base
    expected @=? listInsertAt (-1) elt base
    expected @=? listInsertAt (-2) elt base

  , "adds in the middle of a list" ~: do
    [3, 10, 1, 5, 2] @=? listInsertAt 1 elt base
    [3, 1, 10, 5, 2] @=? listInsertAt 2 elt base
    [3, 1, 5, 10, 2] @=? listInsertAt 3 elt base

  , "adds at the end of a list" ~: do
    let expected = [3, 1, 5, 2, 10]
    expected @=? listInsertAt (length base) elt base
    expected @=? listInsertAt (length base + 1) elt base
    expected @=? listInsertAt (length base + 2) elt base
  ]
  where base = [3, 1, 5, 2]
        elt = 10

listReplaceTests = "listReplace" ~: TestList
  [ "accepts an empty list" ~:
    [] @=? listReplace False True []

  , "replaces the first element" ~:
    [100, 2, 3] @=? listReplace 1 100 [1, 2, 3]

  , "replaces the last element" ~:
    [1, 2, 300] @=? listReplace 3 300 [1, 2, 3]

  , "replaces an interior element" ~:
    [1, 200, 3] @=? listReplace 2 200 [1, 2, 3]

  , "replaces multiple elements" ~: do
    [1, 0, 3, 4, 0, 0, 3] @=? listReplace 2 0 [1, 2, 3, 4, 2, 2, 3]
    replicate 10 True @=? listReplace False True (replicate 10 False)
  ]

andEithersTests = "andEithers" ~: TestList
  [ "returns Right for an empty list" ~:
    Right [] @=? andEithers ([] :: [Either () ()])

  , "returns Right when given all Rights" ~: do
    Right [1] @=? andEithers [Right 1 :: Either () Int]
    Right [1, 2] @=? andEithers [Right 1, Right 2 :: Either () Int]
    Right [1, 2, 3] @=? andEithers [Right 1, Right 2, Right 3 :: Either () Int]

  , "returns Left when there is a single Left" ~: do
    Left [1] @=? andEithers [Left 1 :: Either Int ()]
    Left [1] @=? andEithers [Left 1, Right 2]
    Left [2] @=? andEithers [Right 1, Left 2]
    Left [2] @=? andEithers [Right 1, Left 2, Right 3]
    Left [3] @=? andEithers [Right 1, Right 2, Left 3]

  , "returns Left when there are many Lefts" ~: do
    Left [1, 2] @=? andEithers [Left 1, Left 2, Right 3]
    Left [1, 3] @=? andEithers [Left 1, Right 2, Left 3]
    Left [2, 3] @=? andEithers [Right 1, Left 2, Left 3]
    Left [1, 2, 3] @=? andEithers [Left 1, Left 2, Left 3 :: Either Int ()]
  ]

forTests = "for" ~: TestList
  [ "passes an empty list through" ~:
    ([] @=?) =<< sequence (for [] $ const $ assertFailure "Nope.")

  , "operates on each element of a list" ~:
    [2, 2, 4, 6, 10] @=? for [1, 1, 2, 3, 5] (* 2)
  ]

mapTupleTests = "mapTuple" ~: TestList
  [ "updates both values" ~:
    (9, 16) @=? mapTuple (^ 2) (3, 4)
  ]

mapInvertTests = "mapInvert" ~: TestList
  [ "accepts an empty map" ~:
    Map.empty @=? mapInvert (Map.empty :: Map () ())

  , "inverts a map with no duplicates" ~:
    Map.map sort (Map.fromList [(1, ["one"]), (2, ["two"]), (3, ["three"])]) @=?
    Map.map sort (mapInvert (Map.fromList [("one", 1), ("two", 2), ("three", 3)]))

  , "inverts a map with duplicates" ~:
    Map.map sort (Map.fromList [('a', [1, 3]), ('b', [2]), ('c', [4, 5])]) @=?
    Map.map sort (mapInvert (Map.fromList [(1, 'a'), (2, 'b'), (3, 'a'), (4, 'c'), (5, 'c')]))
  ]

whenMaybeTests = "whenMaybeTests" ~: TestList
  [ "doesn't invoke its function when given Nothing" ~:
    0 @=? State.execState (whenMaybe Nothing $ \x -> State.put (x * 2)) 0

  , "invokes its function when given a Just" ~:
    6 @=? State.execState (whenMaybe (Just 3) $ \x -> State.put (x * 2)) 0
  ]

condTests = "cond" ~: TestList
  [ "accepts an empty list of cases" ~:
    True @=? cond True []

  , "returns the default when all cases are false" ~: do
    0 @=? cond 0 [(False, 1)]
    0 @=? cond 0 [(False, 1), (False, 2)]
    0 @=? cond 0 [(False, 1), (False, 2), (False, 3)]

  , "returns a single true case" ~: do
    3 @=? cond 0 [(False, 1), (False, 2), (True, 3)]
    2 @=? cond 0 [(False, 1), (True, 2), (False, 3)]
    1 @=? cond 0 [(True, 1), (False, 2), (False, 3)]

  , "returns the first true case" ~: do
    3 @=? cond 0 [(False, 1), (False, 2), (True, 3)]
    2 @=? cond 0 [(False, 1), (True, 2), (True, 3)]
    1 @=? cond 0 [(True, 1), (True, 2), (True, 3)]
  ]

if'Tests = "if'" ~: TestList
  [ "detects true" ~: "yes" @=? if' "yes" "no" True
  , "detects false" ~: "no" @=? if' "yes" "no" False
  ]

andMTests = "andM" ~: TestList
  [ "empty list returns true" ~: True @=? runIdentity (andM [])

  , "aborts after an immediate true" ~: do
    ref <- newIORef 0
    result <- andM [addToRef ref 1 >> return False,
                    addToRef ref 2 >> return True]
    False @=? result
    (1 @=?) =<< readIORef ref

  , "aborts on a false after trues" ~: do
    ref <- newIORef 0
    result <- andM [addToRef ref 1 >> return True,
                    addToRef ref 2 >> return True,
                    addToRef ref 4 >> return False,
                    addToRef ref 8 >> return False,
                    addToRef ref 16 >> return False]
    False @=? result
    (7 @=?) =<< readIORef ref

  , "executes all trues" ~: do
    ref <- newIORef 0
    result <- andM [addToRef ref 1 >> return True,
                    addToRef ref 2 >> return True,
                    addToRef ref 4 >> return True,
                    addToRef ref 8 >> return True]
    True @=? result
    (15 @=?) =<< readIORef ref
  ]
  where addToRef ref num = modifyIORef ref (+ num)

forIndexM_Tests = "forIndexM_" ~: TestList
  [ "does nothing with an empty list" ~:
    "" @=? execWriter (forIndexM_ [] $ \_ _ -> tell "x")

  , "iterates over all elements in order" ~:
    "(0,'a')(1,'b')(2,'c')" @=?
    execWriter (forIndexM_ "abc" $ \index value -> tell $ show (index, value))
  ]

whileMTests = "whileM" ~: TestList
  [ "never executes the body if the first test returns false" ~:
    "" @=? execWriter (whileM (return False) (tell "x"))

  , "executes repeatedly as expected" ~:
    let test = do n <- get
                  tell $ show n
                  if n > 0
                    then put (n - 1) >> return True
                    else return False
        body = tell "x"
    in "3x2x1x0" @=? execWriter (runStateT (whileM test body) 3)
  ]

whileM'Tests = "whileM'" ~: TestList
  [ "never executes the body if the first test returns Nothing" ~:
    "" @=? execWriter (whileM' (return Nothing) (const $ tell "x"))

  , "executes repeatedly as expected" ~:
    let test = get >>= \n -> return $ if n > 0 then Just n else Nothing
        body n = do tell $ show n
                    put (n - 1)
    in "321" @=? execWriter (runStateT (whileM' test body) 3)
  ]

doWhileMTests = "doWhileM" ~: TestList
  [ "executes a constantly-Left body once" ~: do
    countVar <- newIORef 0
    result <- doWhileM () (const $ do modifyIORef countVar (+ 1)
                                      return $ Left "done")
    count <- readIORef countVar
    (1, "done") @=? (count, result)

  , "executes until a Left is returned" ~:
    execWriter (doWhileM 9 $ \n -> do
                   tell $ show n
                   return $ if n == 0 then Left () else Right $ n - 1) @=?
    "9876543210"
  ]
