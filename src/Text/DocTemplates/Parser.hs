{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{- |
   Module      : Text.DocTemplates.Parser
   Copyright   : Copyright (C) 2009-2019 John MacFarlane
   License     : BSD3

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable
-}

module Text.DocTemplates.Parser
    ( compileTemplate ) where

import Data.Char (isAlphaNum)
import Control.Monad (guard, when)
import Control.Monad.Trans (lift)
import qualified Text.Parsec as P
import qualified Text.Parsec.Pos as P
import Control.Applicative
import Data.String (IsString(..))
import Data.Text (Text)
import Data.List (isPrefixOf)
import System.FilePath
import Text.DocTemplates.Internal
#if MIN_VERSION_base(4,11,0)
#else
import Data.Semigroup ((<>))
#endif

-- | Compile a template.  The FilePath parameter is used
-- to determine a default path and extension for partials
-- and may be left empty if partials are not used.
compileTemplate :: TemplateMonad m
                => FilePath -> Text -> m (Either String Template)
compileTemplate templPath template = do
  res <- P.runParserT (pTemplate <* P.eof)
           PState{ templatePath   = templPath
                 , partialNesting = 1
                 , beginsLine = True
                 , breakingSpaces = False } templPath template
  case res of
       Left e   -> return $ Left $ show e
       Right x  -> return $ Right x


data PState =
  PState { templatePath   :: FilePath
         , partialNesting :: Int
         , beginsLine     :: Bool
         , breakingSpaces :: Bool }

type Parser = P.ParsecT Text PState

pTemplate :: TemplateMonad m => Parser m Template
pTemplate = do
  P.skipMany pComment
  mconcat <$> many
    ((pLit <|> pDirective <|> pEscape) <* P.skipMany pComment)

pLit :: Monad m => Parser m Template
pLit = do
  cs <- P.many1 (P.satisfy (/= '$'))
  P.updateState $ \st ->
    st{ beginsLine =
          case dropWhile (\c -> c == ' ' || c == '\t') $ reverse cs of
            ('\n':_) -> True
            []       -> beginsLine st
            _        -> False }
  breakspaces <- breakingSpaces <$> P.getState
  if breakspaces
     then return $ toBreakable cs
     else return $ Literal $ fromString cs

toBreakable :: String -> Template
toBreakable [] = Empty
toBreakable xs =
  case break (==' ') xs of
    ([], []) -> Empty
    ([], zs) -> BreakingSpace <> toBreakable (dropWhile (==' ') zs)
    (ys, []) -> Literal (fromString ys)
    (ys, zs) -> Literal (fromString ys) <> toBreakable zs

backupSourcePos :: Monad m => Int -> Parser m ()
backupSourcePos n = do
  pos <- P.getPosition
  P.setPosition $ P.incSourceColumn pos (- n)

pEscape :: Monad m => Parser m Template
pEscape = Literal "$" <$ P.try (P.string "$$" <* backupSourcePos 1)

pDirective :: TemplateMonad m
           => Parser m Template
pDirective = do
  res <- pConditional <|> pForLoop <|> pBreakable <|>
         pInterpolate <|> pBarePartial
  col <- P.sourceColumn <$> P.getPosition
  P.updateState $ \st -> st{ beginsLine = col == 1 }
  return res

pEnclosed :: Monad m => Parser m a -> Parser m a
pEnclosed parser = P.try $ do
  closer <- pOpen
  P.skipMany pSpaceOrTab
  result <- parser
  P.skipMany pSpaceOrTab
  closer
  return result

pParens :: Monad m => Parser m a -> Parser m a
pParens parser = do
  P.char '('
  result <- parser
  P.char ')'
  return result

pConditional :: TemplateMonad m
             => Parser m Template
pConditional = do
  v <- pEnclosed $ P.try $ P.string "if" *> pParens pVar
  -- if newline after the "if", then a newline after "endif" will be swallowed
  multiline <- P.option False (True <$ skipEndline)
  ifContents <- pTemplate
  elseContents <- P.option mempty (pElse multiline <|> pElseIf)
  pEnclosed (P.string "endif")
  when multiline $ P.option () skipEndline
  return $ Conditional v ifContents elseContents

pElse :: TemplateMonad m => Bool -> Parser m Template
pElse multiline = do
  pEnclosed (P.string "else")
  when multiline $ P.option () skipEndline
  pTemplate

pElseIf :: TemplateMonad m => Parser m Template
pElseIf = do
  v <- pEnclosed $ P.try $ P.string "elseif" *> pParens pVar
  multiline <- P.option False (True <$ skipEndline)
  ifContents <- pTemplate
  elseContents <- P.option mempty (pElse multiline <|> pElseIf)
  return $ Conditional v ifContents elseContents

skipEndline :: Monad m => Parser m ()
skipEndline = P.try $
      (P.skipMany pSpaceOrTab <* P.char '\n')
  <|> (P.skipMany1 pSpaceOrTab <* P.eof)

pBreakable :: TemplateMonad m => Parser m Template
pBreakable = do
  pEnclosed $ P.string "breakable"
  oldBreakingSpaces <- breakingSpaces <$> P.getState
  P.modifyState $ \st -> st{ breakingSpaces = True }
  res <- pTemplate
  P.modifyState $ \st -> st{ breakingSpaces = oldBreakingSpaces }
  pEnclosed $ P.string "endbreakable"
  return res

pForLoop :: TemplateMonad m => Parser m Template
pForLoop = do
  v <- pEnclosed $ P.try $ P.string "for" *> pParens pVar
  -- if newline after the "for", then a newline after "endfor" will be swallowed
  multiline <- P.option False $ skipEndline >> return True
  contents <- changeToIt v <$> pTemplate
  sep <- P.option mempty $
           do pEnclosed (P.string "sep")
              when multiline $ P.option () skipEndline
              changeToIt v <$> pTemplate
  pEnclosed (P.string "endfor")
  when multiline $ P.option () skipEndline
  return $ Iterate v contents sep

changeToIt :: Variable -> Template -> Template
changeToIt v = go
 where
  go (Interpolate i w) = Interpolate i (reletter v w)
  go (Conditional w t1 t2) = Conditional (reletter v w)
        (changeToIt v t1) (changeToIt v t2)
  go (Iterate w t1 t2) = Iterate (reletter v w)
        (changeToIt v t1) (changeToIt v t2)
  go (Concat t1 t2) = changeToIt v t1 <> changeToIt v t2
  go (Partial t) = Partial t  -- don't reletter inside partial
  go x = x
  reletter (Variable vs) (Variable ws) =
    if vs `isPrefixOf` ws
       then Variable ("it" : drop (length vs) ws)
       else Variable ws

pInterpolate :: TemplateMonad m
             => Parser m Template
pInterpolate = do
  begins <- beginsLine <$> P.getState
  pos <- P.getPosition
  -- we don't used pEnclosed here, to get better error messages:
  (closer, var) <- P.try $ do
    cl <- pOpen
    P.skipMany pSpaceOrTab
    v <- pVar
    P.notFollowedBy (P.char '(') -- bare partial
    return (cl, v)
  res <- (P.char ':' *> (pPartialName >>= pPartial (Just var)))
      <|> Iterate var (Interpolate Unindented (Variable ["it"])) <$> pSep
      <|> return (Interpolate Unindented var)
  P.skipMany pSpaceOrTab
  closer
  ends <- P.lookAhead $ P.option False $
             True <$ P.try (P.skipMany pSpaceOrTab *> pNewlineOrEof)
  case (begins && ends, res) of
    (True, Interpolate _ v)
               -> return $ Interpolate (Indented (P.sourceColumn pos - 1)) v
    (True, Iterate v (Interpolate _ v') s)
               -> return $ Iterate v
                    (Interpolate (Indented (P.sourceColumn pos - 1)) v') s
    _ -> return res

pNewlineOrEof :: Monad m => Parser m ()
pNewlineOrEof = () <$ P.newline <|> P.eof

pBarePartial :: TemplateMonad m
             => Parser m Template
pBarePartial = do
  (closer, fp) <- P.try $ do
    closer <- pOpen
    P.skipMany pSpaceOrTab
    fp <- pPartialName
    return (closer, fp)
  res <- pPartial Nothing fp
  P.skipMany pSpaceOrTab
  closer
  return res

pPartialName :: TemplateMonad m
             => Parser m FilePath
pPartialName = P.try $ do
  fp <- P.many1 (P.alphaNum <|> P.oneOf ['_','-','.','/','\\'])
  P.string "()"
  return fp

pPartial :: TemplateMonad m
         => Maybe Variable -> FilePath -> Parser m Template
pPartial mbvar fp = do
  separ <- P.option mempty pSep
  tp <- templatePath <$> P.getState
  let fp' = case takeExtension fp of
               "" -> replaceBaseName tp fp
               _  -> replaceFileName tp fp
  partial <- lift $ removeFinalNewline <$> getPartial fp'
  nesting <- partialNesting <$> P.getState
  t <- if nesting > 50
          then return $ Literal "(loop)"
          else do
            oldInput <- P.getInput
            oldPos <- P.getPosition
            P.setPosition $ P.initialPos fp'
            P.setInput partial
            P.updateState $ \st -> st{ partialNesting = nesting + 1 }
            res' <- pTemplate <* P.eof
            P.updateState $ \st -> st{ partialNesting = nesting }
            P.setInput oldInput
            P.setPosition oldPos
            return res'
  case mbvar of
    Just var -> return $ Iterate var t separ
    Nothing  -> return $ Partial t

pSep :: Monad m => Parser m Template
pSep = do
    P.char '['
    xs <- P.many (P.satisfy (/= ']'))
    P.char ']'
    return $ Literal (fromString xs)

pSpaceOrTab :: Monad m => Parser m Char
pSpaceOrTab = P.satisfy (\c -> c == ' ' || c == '\t')

pComment :: Monad m => Parser m ()
pComment = do
  pos <- P.getPosition
  P.try (P.string "$--")
  P.skipMany (P.satisfy (/='\n'))
  -- If the comment begins in the first column, the line ending
  -- will be consumed; otherwise not.
  when (P.sourceColumn pos == 1) $ () <$ do
    pNewlineOrEof
    P.updateState $ \st -> st{ beginsLine = True }

pOpenDollar :: Monad m => Parser m (Parser m ())
pOpenDollar =
  pCloseDollar <$ P.try (P.char '$' <*
                   P.notFollowedBy (P.char '$' <|> P.char '{'))
  where
   pCloseDollar = () <$ P.char '$'

pOpenBraces :: Monad m => Parser m (Parser m ())
pOpenBraces =
  pCloseBraces <$ P.try (P.string "${" <* P.notFollowedBy (P.char '}'))
  where
   pCloseBraces = () <$ P.try (P.char '}')

pOpen :: Monad m => Parser m (Parser m ())
pOpen = pOpenDollar <|> pOpenBraces

pVar :: Monad m => Parser m Variable
pVar = do
  first <- pIdentPart <|> "it" <$ P.try (P.string "it")
  rest <- P.many $ P.char '.' *> pIdentPart
  return $ Variable (first:rest)

pIdentPart :: Monad m => Parser m Text
pIdentPart = P.try $ do
  first <- P.letter
  rest <- P.many (P.satisfy (\c -> isAlphaNum c || c == '_' || c == '-'))
  let part = first : rest
  guard $ part `notElem` reservedWords
  return $ fromString part

reservedWords :: [String]
reservedWords = ["if","else","endif","elseif","for","endfor","sep","it",
                "breakable","endbreakable"]
