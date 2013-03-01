{-# OPTIONS -Wall #-}
{-# LANGUAGE OverloadedStrings, RecordWildCards, FlexibleInstances #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS -fno-warn-name-shadowing -fno-warn-orphans #-}

-- | Mini formlets library.

module Text.Formlet
       (Formlet(..)
       ,formlet
       ,req
       ,opt
       ,wrap
       ,integer
       ,textInput
       ,dropInput
       ,areaInput
       ,submitInput
       ,parse
       ,options
       ,findOption) where

import           Control.Applicative
import           Control.Monad.Error
import           Control.Monad.Reader
import           Control.Monad.Trans.Error   (ErrorList(..))
import           Control.Monad.Writer
import           Data.ByteString             (ByteString)
import           Data.List                   (find)
import           Data.Map                    (Map)
import qualified Data.Map                    as M
import           Data.Maybe
import           Data.Monoid.Operator
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import           Data.Text.Encoding
import           Prelude                     hiding ((++))
import           Text.Blaze.Html5            as H hiding (map)
import qualified Text.Blaze.Html5.Attributes as A

type Params = Map ByteString [ByteString]

-- | A simple formlet data type, collects errors.
data Formlet a = Formlet {
   formletValue  :: Params -> Either [Text] a
 , formletName   :: Maybe Text
 , formletHtml   :: Params -> Html
}

instance Applicative Formlet where
  pure a = Formlet { formletValue = const (return a)
                   , formletHtml  = const mempty
                   , formletName  = Nothing
                   }
  Formlet f n fhtml <*> Formlet v n' vhtml =
    Formlet { formletValue = \params ->
                case v params of
                  Right x -> f params <*> Right x
                  Left e  -> case f params <*> Left [] of
                               Right x -> return x
                               Left e' -> Left $ e' ++ e
            , formletHtml  = \params -> fhtml params ++ vhtml params
            , formletName  = case (n,n') of
                               (Just{},Just{}) -> Nothing
                               _               -> n `mplus` n'
            }

-- | Normal instance.
instance Functor Formlet where
  fmap f formlet@Formlet{..} = formlet { formletValue = value }
    where value = \params ->
                    case formletValue params of
                      Left e -> Left e
                      Right a -> Right (f a)

-- | The error message for the formlets is a text value.
instance Error Text where noMsg = ""; strMsg = T.pack
instance ErrorList Text where listMsg = return . T.pack

-- | Make a simple formlet.
formlet :: Text -> (Maybe Text -> Html) -> Formlet Text
formlet name html = 
  Formlet { formletValue = \inputs ->
              case (M.lookup (encodeUtf8 name) inputs) of
                Just (value:_) -> return $ decodeUtf8 value
                _ -> throwError $ ["missing input: " ++ name]
          , formletHtml = \inputs ->
              case M.lookup (encodeUtf8 name) inputs of
                Just (value:_) -> html (Just $ decodeUtf8 value)
                _ -> html Nothing
          , formletName = Just name
          }

-- | Make an input required (non-empty text).
req :: Formlet Text -> Formlet Text
req formlet@Formlet{..} =
  formlet { formletValue = \inputs ->
              case formletValue inputs of
                Right v | T.null v ->
                  throwError $ ["required input" ++ maybe "" (": "++) formletName]
                meh -> meh
          }

-- | Make an input optional (empty text is nothing).
opt :: Formlet Text -> Formlet (Maybe Text)
opt formlet@Formlet{..} =
  formlet { formletValue = \inputs ->
              case formletValue inputs of
                Right v | T.null v -> Right Nothing
                meh -> Just <$> meh
          }



-- | Parse a form value.
parse :: (a -> Either Text b) -> Formlet a -> Formlet b
parse parser formlet@Formlet{..} =
  formlet { formletValue = \inputs ->
              case formletValue inputs of
                Left e -> Left e
                Right x -> case parser x of
                             Right y -> Right y
                             Left e -> Left [e ++ maybe "" (": "++) formletName]
          }

-- | Integer parser.
integer :: Text -> Either Text Integer
integer (readMay . T.unpack -> Just v) = Right v
integer _ = Left "expected integer"

readMay :: Read a => String -> Maybe a
readMay x = case reads x of
              [(x,"")] -> return x
              _        -> Nothing

-- | Wrap/transform formlet's HTML.
wrap :: (Html -> Html) -> Formlet Text -> Formlet Text
wrap f formlet@Formlet{..} = formlet { formletHtml = f . formletHtml }

-- | Make a text input formlet with a label.
textInput :: Text -> Text -> Maybe Text -> Formlet Text
textInput name caption def =
  formlet name $ \value -> do
    p $ H.label $ do
      H.span $ toHtml $ caption ++ ": "
      input ! A.name (toValue name)
            ! A.value (toValue $ fromMaybe "" (value <|> def))
            ! A.class_ "text"

-- | Make a textarea input with a label.
areaInput :: Text -> Text -> Maybe Text -> Formlet Text
areaInput name caption def =
  formlet name $ \value -> do
    p $ H.label $ do
      H.span $ toHtml $ caption ++ ": "
      textarea ! A.name (toValue name) $
        toHtml $ fromMaybe "" (value <|> def)

-- | Make a drop down input with a label.
dropInput :: [(Text,Text)] -> Text -> Text -> Text -> Formlet Text
dropInput values name caption def =
  formlet name $ \value -> do
    p $ H.label $ do
      H.span $ toHtml $ caption ++ ": "
      select ! A.name (toValue name) $
        forM_ values $ \(key,title) -> do
          let nonSelected = all ((/=value) . Just . fst) values
              defaulting = nonSelected && def == key
              selected
                | Just key == value = (! A.selected "selected")
                | defaulting        = (! A.selected "selected")
                | otherwise         = id
          selected $ option ! A.value (toValue key) $ toHtml title

-- | Make a submit (captioned) button.
submitInput :: Text -> Text -> Html
submitInput name caption = p $ do
  p $ H.input ! A.type_ "submit"
              ! A.name (toValue name)
              ! A.value (toValue caption)

-- | Make a list of options for use with the option formlet.
options :: (o -> Text) -> (o -> Text) -> [o] -> [(Text,Text)]
options slug caption os = ("","") : map (\o -> (slug o,caption o)) os

-- | Lookup a real internal id from a slug.
findOption :: (o -> Bool) -> [o] -> (o -> internalid) -> Either Text internalid
findOption pred os field =
  case find pred os of
    Nothing -> Left ""
    Just x -> Right (field x)
