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

{-# LANGUAGE CPP #-}

-- | Parsers of property values.
module Game.Goatee.Lib.Property.Parser (
  colorParser,
  coordElistParser,
  coordListParser,
  coordPairListParser,
  doubleParser,
  gameResultParser,
  labelListParser,
  lineListParser,
  moveParser,
  noneParser,
  integralParser,
  realParser,
  rulesetParser,
  simpleTextPairParser,
  simpleTextParser,
  sizeParser,
  textParser,
  unknownPropertyParser,
  variationModeParser,
  -- * Exposed for testing
  compose,
  line,
  simpleText,
  text,
  ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$), (<$>), (<*), (<*>), (*>))
#endif
import Control.Monad (when)
import Data.Char (isUpper, ord)
import Data.Maybe (catMaybes)
#if !MIN_VERSION_base(4,8,0)
import Data.Monoid (Monoid, mappend, mconcat, mempty)
#endif
import qualified Game.Goatee.Common.Bigfloat as BF
import Game.Goatee.Lib.Types
import Text.ParserCombinators.Parsec (
  (<?>), (<|>), Parser,
  anyChar, char, choice, digit, many, many1,
  noneOf, oneOf, option, space, spaces, string,
  try, unexpected,
  )

{-# ANN module "HLint: ignore Reduce duplication" #-}

-- Internal parser builders not corresponding to any particular value type.

-- | A wrapper around 'CoordList' with a 'Monoid' instance used for parsing.
-- The monoid does simple concatenation of the single and rectangle lists, so it
-- is not appropriate for @CoordList@ proper, as it doesn't do duplicate removal
-- between two @CoordList@s.
newtype CoordListMonoid = CoordListMonoid { runCoordListMonoid :: CoordList }

instance Monoid CoordListMonoid where
  mempty = CoordListMonoid emptyCoordList

  mappend (CoordListMonoid x) (CoordListMonoid y) =
    CoordListMonoid $ coords' (coordListSingles x ++ coordListSingles y)
                              (coordListRects x ++ coordListRects y)

single :: Parser a -> Parser a
single valueParser = char '[' *> valueParser <* char ']'

compose :: Parser a -> Parser b -> Parser (a, b)
compose first second = do
  x <- first
  _ <- char ':'
  y <- second
  return (x, y)

line :: Parser Int
line = toLine <$> line' <?> "line"
  where line' = oneOf $ ['a'..'z'] ++ ['A'..'Z']
        toLine c = if isUpper c
                   then ord c - ord 'A' + 26
                   else ord c - ord 'a'

listOf :: Parser a -> Parser [a]
listOf valueParser = many1 (single valueParser <* spaces)

number :: Parser String
number = do
  addSign <- ('-':) <$ char '-' <|>
             id <$ char '+' <|>
             return id
  addSign <$> many1 digit

-- Public parsers.

colorParser :: Parser Color
colorParser = single color <?> "color"

color :: Parser Color
color = choice [Black <$ char 'B',
                White <$ char 'W']

coord :: Parser Coord
coord = (,) <$> line <*> line

coordElistParser :: Parser CoordList
coordElistParser =
  try (emptyCoordList <$ string "[]") <|>
  coordListParser <?>
  "list of points or empty"

coordListParser :: Parser CoordList
coordListParser =
  runCoordListMonoid . mconcat . map CoordListMonoid <$> listOf coordListEntry <?>
  "list of points"
  where coordListEntry = do x0 <- line
                            y0 <- line
                            choice [do _ <- char ':'
                                       x1 <- line
                                       y1 <- line
                                       return $ coordR ((x0, y0), (x1, y1)),
                                    return $ coord1 (x0, y0)]
        coordR rect = coords' [] [rect]

coordPairListParser :: Parser [(Coord, Coord)]
coordPairListParser = listOf coordPair <?> "list of point pairs"
  where coordPair = do
          x0 <- line
          y0 <- line
          _ <- char ':'
          x1 <- line
          y1 <- line
          return ((x0, y0), (x1, y1))

doubleParser :: Parser DoubleValue
doubleParser =
  single (Double1 <$ char '1' <|>
          Double2 <$ char '2') <?>
  "double"

gameResultParser :: Parser GameResult
gameResultParser = single (convertStringlike <$> simpleText False) <?> "game result"

labelListParser :: Parser [(Coord, SimpleText)]
labelListParser =
  listOf (compose coord $ simpleText True) <?> "list of points and labels"

lineListParser :: Parser [Line]
lineListParser = map (uncurry Line) <$> coordPairListParser <?> "list of lines"

moveParser :: Parser (Maybe Coord)
moveParser =
  char '[' *> (Nothing <$ char ']' <|> Just <$> coord <* char ']') <?>
  "move (point or pass)"

noneParser :: Parser ()
noneParser = () <$ string "[]" <?> "none"

-- This is what the SGF spec calls the Number type, i.e. a signed integer.
integralParser :: (Integral a, Read a) => Parser a
integralParser = single integral <?> "integer"

integral :: (Integral a, Read a) => Parser a
integral = read <$> number

realParser :: Parser RealValue
realParser = single real <?> "real"

real :: Parser RealValue
real = do
  whole <- number
  -- Try to read a fractional part of the number.
  -- If we fail, just return the whole part.
  option (fromInteger $ read whole) $ try $ do
    fractional <- char '.' *> many1 digit
    return $ BF.encode (read $ whole ++ fractional) (-length fractional)

rulesetParser :: Parser Ruleset
rulesetParser =
  single (toRuleset . fromSimpleText <$> simpleText False) <?> "ruleset"

simpleTextPairParser :: Parser (SimpleText, SimpleText)
simpleTextPairParser = single (compose composedText composedText) <?> "pair of simple texts"
  where composedText = simpleText True

-- | A parser for SGF SimpleText property values.
simpleTextParser :: Parser SimpleText
simpleTextParser = single (simpleText False) <?> "simple text"

simpleText :: Bool -> Parser SimpleText
simpleText isComposed = toSimpleText <$> text isComposed

sizeParser :: Parser (Int, Int)
sizeParser =
  (do _ <- char '['
      width <- integral
      height <- choice [width <$ char ']',
                        do _ <- char ':'
                           height <- integral
                           _ <- char ']'
                           -- TODO We should warn here rather than aborting.
                           when (width == height) $
                             fail $ show width ++ "x" ++ show height ++ " square board " ++
                             " dimensions should be specified with a single number."
                           return height]
      when (width < 1 || width > boardSizeMax ||
            height < 1 || height > boardSizeMax) $
        fail $ show width ++ "x" ++ show height ++ " board dimensions are invalid.  " ++
        "Each dimension must be between 1 and 52 inclusive."
      return (width, height)) <?>
  "board size (width or width:height)"

textParser :: Parser Text
textParser = single (toText <$> text False) <?> "text"

-- | A parser for SGF text property values.  Its argument should be true if the
-- text is inside of a composed property value, so @\':\'@ should terminate the
-- value in addition to @']'@.
text :: Bool -> Parser String
text isComposed = catMaybes <$> many textChar'
  where textChar' = textChar (if isComposed then ":]\\" else "]\\")

textChar :: String -> Parser (Maybe Char)
textChar specialChars =
  choice [Just <$> char '\n',
          Just ' ' <$ space,
          try (char '\\' *> (Nothing <$ char '\n' <|>
                             Just <$> anyChar)),
          Just <$> noneOf specialChars]

unknownPropertyParser :: Parser UnknownPropertyValue
unknownPropertyParser =
  single (toUnknownPropertyValue <$> text False) <?>
  "unknown property value"

variationModeParser :: Parser VariationMode
variationModeParser = single variationMode <?> "variation mode"

variationMode :: Parser VariationMode
variationMode = do
  value <- integral
  case toVariationMode value of
    Just mode -> return mode
    Nothing -> unexpected $ "variation mode " ++ show value
