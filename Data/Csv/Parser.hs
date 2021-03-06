{-# LANGUAGE BangPatterns, CPP #-}

-- | A CSV parser. The parser defined here is RFC 4180 compliant, with
-- the following extensions:
--
--  * Empty lines are ignored.
--
--  * Non-escaped fields may contain any characters except
--    double-quotes, commas, carriage returns, and newlines.
--
--  * Escaped fields may contain any characters (but double-quotes
--    need to be escaped).
--
-- The functions in this module can be used to implement e.g. a
-- resumable parser that is fed input incrementally.
module Data.Csv.Parser
    ( DecodeOptions(..)
    , defaultDecodeOptions
    , csv
    , csvWithHeader
    , header
    , record
    , name
    , field
    ) where

import Blaze.ByteString.Builder (fromByteString, toByteString)
import Blaze.ByteString.Builder.Char.Utf8 (fromChar)
import Control.Applicative (Alternative, (*>), (<$>), (<*), (<|>), optional,
                            pure)
import Data.Attoparsec.Char8 (char, endOfInput, endOfLine)
import qualified Data.Attoparsec as A
import qualified Data.Attoparsec.Lazy as AL
import Data.Attoparsec.Types (Parser)
import qualified Data.Attoparsec.Zepto as Z
import qualified Data.ByteString as S
import qualified Data.ByteString.Unsafe as S
import Data.Monoid (mappend, mempty)
import qualified Data.Vector as V
import Data.Word (Word8)

import Data.Csv.Types
import Data.Csv.Util ((<$!>), blankLine)

-- | Options that controls how data is decoded. These options can be
-- used to e.g. decode tab-separated data instead of comma-separated
-- data.
--
-- To avoid having your program stop compiling when new fields are
-- added to 'DecodeOptions', create option records by overriding
-- values in 'defaultDecodeOptions'. Example:
--
-- > myOptions = defaultDecodeOptions {
-- >       decDelimiter = fromIntegral (ord '\t')
-- >     }
data DecodeOptions = DecodeOptions
    { -- | Field delimiter.
      decDelimiter  :: {-# UNPACK #-} !Word8
    } deriving (Eq, Show)

-- | Decoding options for parsing CSV files.
defaultDecodeOptions :: DecodeOptions
defaultDecodeOptions = DecodeOptions
    { decDelimiter = 44  -- comma
    }

-- | Parse a CSV file that does not include a header.
csv :: DecodeOptions -> AL.Parser Csv
csv !opts = do
    vals <- record (decDelimiter opts) `sepBy1'` endOfLine
    _ <- optional endOfLine
    endOfInput
    let nonEmpty = removeBlankLines vals
    return $! V.fromList nonEmpty
{-# INLINE csv #-}

-- | @sepBy1' p sep@ applies /one/ or more occurrences of @p@,
-- separated by @sep@. Returns a list of the values returned by @p@.
-- The value returned by @p@ is forced to WHNF.
--
-- > commaSep p  = p `sepBy1'` (symbol ",")
sepBy1' :: (Alternative f, Monad f) => f a -> f s -> f [a]
sepBy1' p s = go
  where
    go = do
        !a <- p
        as <- (s *> go) <|> pure []
        return (a : as)
#if __GLASGOW_HASKELL__ >= 700
{-# SPECIALIZE sepBy1' :: Parser S.ByteString a -> Parser S.ByteString s
                       -> Parser S.ByteString [a] #-}
#endif

-- | Parse a CSV file that includes a header.
csvWithHeader :: DecodeOptions -> AL.Parser (Header, V.Vector NamedRecord)
csvWithHeader !opts = do
    !hdr <- header (decDelimiter opts)
    vals <- map (toNamedRecord hdr) . removeBlankLines <$>
            (record (decDelimiter opts)) `sepBy1'` endOfLine
    _ <- optional endOfLine
    endOfInput
    let !v = V.fromList vals
    return (hdr, v)

-- | Parse a header, including the terminating line separator.
header :: Word8  -- ^ Field delimiter
       -> AL.Parser Header
header !delim = V.fromList <$!> name delim `sepBy1'` (A.word8 delim) <* endOfLine

-- | Parse a header name. Header names have the same format as regular
-- 'field's.
name :: Word8 -> AL.Parser Name
name !delim = field delim

removeBlankLines :: [Record] -> [Record]
removeBlankLines = filter (not . blankLine)

-- | Parse a record, not including the terminating line separator. The
-- terminating line separate is not included as the last record in a
-- CSV file is allowed to not have a terminating line separator. You
-- most likely want to use the 'endOfLine' parser in combination with
-- this parser.
record :: Word8  -- ^ Field delimiter
       -> AL.Parser Record
record !delim = do
    fs <- field delim `sepBy1'` (A.word8 delim)
    return $! V.fromList fs
{-# INLINE record #-}

-- | Parse a field. The field may be in either the escaped or
-- non-escaped format. The return value is unescaped.
field :: Word8 -> AL.Parser Field
field !delim = do
    mb <- A.peekWord8
    -- We purposely don't use <|> as we want to commit to the first
    -- choice if we see a double quote.
    case mb of
        Just b | b == doubleQuote -> escapedField
        _                         -> unescapedField delim
{-# INLINE field #-}

escapedField :: AL.Parser S.ByteString
escapedField = do
    _ <- dquote
    -- The scan state is 'True' if the previous character was a double
    -- quote.  We need to drop a trailing double quote left by scan.
    s <- S.init <$> (A.scan False $ \s c -> if c == doubleQuote
                                            then Just (not s)
                                            else if s then Nothing
                                                 else Just False)
    if doubleQuote `S.elem` s
        then case Z.parse unescape s of
            Right r  -> return r
            Left err -> fail err
        else return s

unescapedField :: Word8 -> AL.Parser S.ByteString
unescapedField !delim = A.takeWhile (\ c -> c /= doubleQuote &&
                                            c /= newline &&
                                            c /= delim &&
                                            c /= cr)

dquote :: AL.Parser Char
dquote = char '"'

unescape :: Z.Parser S.ByteString
unescape = toByteString <$!> go mempty where
  go acc = do
    h <- Z.takeWhile (/= doubleQuote)
    let rest = do
          start <- Z.take 2
          if (S.unsafeHead start == doubleQuote &&
              S.unsafeIndex start 1 == doubleQuote)
              then go (acc `mappend` fromByteString h `mappend` fromChar '"')
              else fail "invalid CSV escape sequence"
    done <- Z.atEnd
    if done
      then return (acc `mappend` fromByteString h)
      else rest

doubleQuote, newline, cr :: Word8
doubleQuote = 34
newline = 10
cr = 13
