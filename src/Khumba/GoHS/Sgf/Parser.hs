module Khumba.GoHS.Sgf.Parser ( ParseError
                              , parseString
                              , parseFile
                              ) where

import Control.Applicative ((<$), (<$>), (<*), (*>), (<*>))
import Control.Monad
import Data.Char
import Data.Monoid
import Khumba.GoHS.Sgf
import Khumba.GoHS.Common
import Text.ParserCombinators.Parsec

parseString :: String -> Either String Collection
parseString str = case parse collection "<collection>" str of
  Left err -> Left $ show err
  Right (Collection roots) -> onLeft concatErrors $
                              onRight Collection $
                              andEithers $
                              map ttToPass roots
  where -- SGF allows B[tt] and W[tt] to represent passes on boards <=19x19.
        -- Convert any passes from this format to B[] and W[] in a root node and
        -- its descendents.
        ttToPass root = case findProperty root isSZ of
          Nothing ->
            Left $ "Missing size property (SZ) in root node: " ++ show root
          Just (SZ width height) ->
            Right $ if width <= 19 && height <= 19
                    then ttToPass' width height root
                    else root
        -- Convert a node and its descendents.
        ttToPass' width height node =
          node { nodeProperties = map ttToPass'' $ nodeProperties node
               , nodeChildren = map (ttToPass' width height) $ nodeChildren node
               }
        -- Convert a property.
        ttToPass'' prop = case prop of
          B (Just (19, 19)) -> B Nothing
          W (Just (19, 19)) -> W Nothing
          _ -> prop
        isSZ prop = case prop of
          SZ _ _ -> True
          _ -> False
        concatErrors errs = "The following errors occurred while parsing:" ++
                            concatMap ("\n-> " ++) errs

parseFile :: String -> IO (Either String Collection)
parseFile = fmap parseString . readFile

collection :: CharParser () Collection
collection = fmap Collection (spaces *> many (gameTree <* spaces) <* eof)
             <?> "collection"

gameTree :: CharParser () Node
gameTree = do
  char '('
  nodes <- spaces *> many1 (node <* spaces) <?> "sequence"
  subtrees <- many (gameTree <* spaces) <?> "subtrees"
  char ')'
  let (sequence, [final]) = splitAt (length nodes - 1) nodes
  return $ foldr (\seqNode childNode -> seqNode { nodeChildren = [childNode] })
                 (final { nodeChildren = subtrees })
                 sequence

node :: CharParser () Node
node = fmap (\props -> emptyNode { nodeProperties = props })
       (char ';' *> spaces *> many (property <* spaces)
        <?> "node")

property :: CharParser () Property
-- TODO Some order on these.
property = choice [try $ propertyParser "B" $ single $ B <$> move,
                   -- TODO Parse KO.  How to parse word boundaries?
                   try $ propertyParser "MN" $ single $ MN <$> number,
                   try $ propertyParser "W" $ single $ W <$> move,

                   try $ propertyParser "AB" $ AB <$> listOfPoint,
                   try $ propertyParser "AE" $ AE <$> listOfPoint,
                   try $ propertyParser "AW" $ AW <$> listOfPoint,
                   try $ propertyParser "PL" $ single $ PL <$> color,

                   try $ propertyParser "SZ" $ single $ (\x -> SZ x x) <$> number,

                   try $ propertyParser "BR" $ single $ BR <$> simpleText,
                   try $ propertyParser "PB" $ single $ PB <$> simpleText,
                   try $ propertyParser "PW" $ single $ PW <$> simpleText,
                   try $ propertyParser "WR" $ single $ WR <$> simpleText,
                   unknownProperty]

unknownProperty :: CharParser () Property
unknownProperty = do
  name <- many1 upper
  value <- fmap (concatMap $ \x -> "[" ++ x ++ "]") $
           many (char '[' *> many (try escapedChar <|> noneOf "]") <* char ']')
  return $ UnknownProperty name value

escapedChar :: CharParser () Char
escapedChar = char '\\' *> anyChar

propertyParser :: String -> CharParser a Property -> CharParser a Property
propertyParser name valueParser = string name *> spaces *> valueParser

single :: CharParser a b -> CharParser a b
single valueParser = char '[' *> valueParser <* char ']'

listOf :: CharParser a b -> CharParser a [b]
listOf valueParser = many1 (single valueParser <* spaces)
                     <?> "list"

elistOf :: CharParser a b -> CharParser a [b]
elistOf valueParser = try (listOf valueParser)
                      <|> ([] <$ string "[]")
                      <?> "elist"

listOfPoint :: CharParser () CoordList
listOfPoint = mconcat <$> listOf pointListEntry
  where pointListEntry = list1 <$> try point
                         <|> listR <$> compose point point
                         <?> "point list entry"
        list1 point = CoordList { coordListSingles = [point]
                                , coordListRects = []
                                }
        listR (from, to) = CoordList { coordListSingles = []
                                     , coordListRects = [(from, to)]
                                     }

number :: (Num a, Read a) => CharParser () a
number = read <$> number' <?> "integer"

number' :: CharParser () String
number' = do
  sign <- option "" $ choice ["" <$ char '+',
                              "-" <$ char '-']
  digits <- many1 digit
  return $ sign ++ digits

real :: CharParser () RealValue
real = fmap read real' <?> "real"

real' :: CharParser () String
real' = do
  wholePart <- number'
  -- Try to read a fractional part of the number.
  -- If we fail, just return the whole part.
  option wholePart $ do
    char '.'
    fractionalPart <- many1 digit
    return $ wholePart ++ "." ++ fractionalPart

double :: CharParser () DoubleValue
double = choice [Double1 <$ char '1',
                 Double2 <$ char '2']
         <?> "double"

color :: CharParser () Color
color = choice [Black <$ char 'B',
                White <$ char 'W']
        <?> "color"

simpleText :: CharParser () SimpleText
simpleText = fmap toSimpleText (many (try escapedChar <|> noneOf "]")
                                <?> "SimpleText")

-- TODO text

line :: CharParser () Int
line = do
  c <- line'
  return $ if isUpper c
           then ord c - ord 'A' + 26
           else ord c - ord 'a'

line' :: CharParser () Char
line' = oneOf $ ['a'..'z'] ++ ['A'..'Z']

point :: CharParser () Coord
point = liftM2 (,) line line <?> "point"

stone :: CharParser () Coord
stone = liftM2 (,) line line <?> "stone"

move :: CharParser () (Maybe Coord)
move = try (liftM Just $ liftM2 (,) line line) <|> return Nothing

compose :: CharParser u a -> CharParser u b -> CharParser u (a, b)
compose first second = do
  x <- first
  char ':'
  y <- second
  return (x, y)
